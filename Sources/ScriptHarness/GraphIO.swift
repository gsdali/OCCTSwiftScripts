// GraphIO.swift
// ScriptHarness
//
// Shared CLI helpers for the graph-* / feature-* subcommands:
// argv parsing, BREP load/write, JSON emission, graph→shape rebuild,
// and Codable result shapes returned on stdout.
//
// All failure paths throw `ScriptError` so callers (notably the occtkit
// --serve loop) can catch and continue rather than exiting the process.

import Foundation
import OCCTSwift

public enum GraphIO {

    // MARK: - argv

    /// Read the argument at `index` (0-based, after the subcommand name).
    public static func argument(at index: Int, in args: [String], usage: String) throws -> String {
        guard index < args.count else { throw ScriptError.message(usage) }
        return args[index]
    }

    // MARK: - BREP I/O

    public static func loadBREP(at path: String) throws -> Shape {
        let url = URL(fileURLWithPath: path)
        do {
            return try Shape.loadBREP(from: url)
        } catch {
            throw ScriptError.message("Failed to load BREP at \(path): \(error.localizedDescription)")
        }
    }

    public static func writeBREP(_ shape: Shape, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try Exporter.writeBREP(shape: shape, to: url)
        } catch {
            throw ScriptError.message("Failed to write BREP at \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - Graph

    public static func buildGraph(from shape: Shape) throws -> TopologyGraph {
        guard let g = TopologyGraph(shape: shape) else {
            throw ScriptError.message("Failed to build TopologyGraph from shape")
        }
        return g
    }

    /// Rebuild a Shape from the graph's roots.
    /// Single root → that shape; multiple → wrapped in a compound.
    public static func rebuildShape(from graph: TopologyGraph) -> Shape? {
        let roots = graph.rootNodes
        let pieces = roots.compactMap { graph.shape(nodeKind: $0.kind, nodeIndex: $0.index) }
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1 { return pieces[0] }
        return Shape.compound(pieces)
    }

    // MARK: - Output

    /// Encode `value` as pretty-printed JSON with sorted keys to stdout.
    public static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            throw ScriptError.message("Failed to encode JSON: \(error.localizedDescription)")
        }
    }
}

// MARK: - Result shapes

extension GraphIO {

    public struct ValidationReport: Codable, Sendable {
        public let isValid: Bool
        public let errorCount: Int
        public let warningCount: Int

        public init(_ r: TopologyGraph.ValidationResult) {
            self.isValid = r.isValid
            self.errorCount = r.errorCount
            self.warningCount = r.warningCount
        }
    }

    public struct CompactReport: Codable, Sendable {
        public let nodesBefore: Int
        public let nodesAfter: Int
        public let removed: Removed
        public let output: String

        public struct Removed: Codable, Sendable {
            public let vertices: Int
            public let edges: Int
            public let faces: Int
        }

        public init(nodesBefore: Int, result: TopologyGraph.CompactResult, output: String) {
            self.nodesBefore = nodesBefore
            self.nodesAfter = result.nodesAfter
            self.removed = Removed(
                vertices: result.removedVertices,
                edges: result.removedEdges,
                faces: result.removedFaces
            )
            self.output = output
        }
    }

    public struct DedupReport: Codable, Sendable {
        public let canonicalSurfaces: Int
        public let canonicalCurves: Int
        public let surfaceRewrites: Int
        public let curveRewrites: Int
        public let output: String

        public init(_ r: TopologyGraph.DeduplicateResult, output: String) {
            self.canonicalSurfaces = r.canonicalSurfaces
            self.canonicalCurves = r.canonicalCurves
            self.surfaceRewrites = r.surfaceRewrites
            self.curveRewrites = r.curveRewrites
            self.output = output
        }
    }
}
