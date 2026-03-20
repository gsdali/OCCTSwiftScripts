// ScriptContext.swift
// ScriptHarness
//
// Accumulates geometry (shapes, wires, edges, curves), writes BREP + STEP files,
// and emits a manifest for the viewport app to load.

import Foundation
import OCCTSwift

/// Accumulates geometry and writes output for viewport visualization and external tools.
///
/// Supports the full OCCTSwift API surface — solids, wires, edges, curves, surfaces.
/// Wire/edge/curve geometry is preserved through BREP format and visualized as wireframe.
///
/// Usage:
/// ```swift
/// let ctx = ScriptContext()
///
/// // Sketch a profile
/// let profile = Wire.rectangle(width: 20, height: 10)!
/// try ctx.add(profile, id: "sketch", color: .yellow)
///
/// // Extrude to solid
/// let solid = Shape.extrude(profile: profile, direction: SIMD3(0, 0, 1), length: 5)!
/// let filleted = solid.filleted(radius: 1.0)!
/// try ctx.add(filleted, id: "body", color: .blue)
///
/// // Boolean cut
/// let hole = Shape.cylinder(radius: 3, height: 10)!.translated(by: SIMD3(5, 0, -1))!
/// let result = filleted.subtracting(hole)!
/// try ctx.add(result, id: "final", color: .steel)
///
/// try ctx.emit(description: "Filleted plate with hole")
/// ```
public final class ScriptContext: Sendable {
    private let outputDir: URL
    private let descriptors: LockedArray<BodyDescriptor>
    private let shapes: LockedArray<(Shape, String)>

    /// Whether to also write a combined STEP file on emit (default: true).
    public let exportSTEP: Bool

    /// Part/project metadata written into the manifest.
    public let metadata: ManifestMetadata?

    public init(exportSTEP: Bool = true, metadata: ManifestMetadata? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Prefer iCloud Drive for cross-device sync (Mac → iPhone)
        let iCloudDir = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .appendingPathComponent("OCCTSwiftScripts/output")
        let localDir = home.appendingPathComponent(".occtswift-scripts/output")

        let dir: URL
        if FileManager.default.fileExists(atPath: iCloudDir.deletingLastPathComponent().deletingLastPathComponent().path) {
            dir = iCloudDir
        } else {
            dir = localDir
        }
        self.outputDir = dir
        self.exportSTEP = exportSTEP
        self.metadata = metadata
        self.descriptors = LockedArray()
        self.shapes = LockedArray()

        // Clean previous output
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Add Shape (solids, shells, compounds)

    /// Add a shape to the output. Writes BREP immediately.
    public func add(
        _ shape: Shape,
        id: String? = nil,
        color: [Float]? = nil,
        name: String? = nil,
        roughness: Float? = nil,
        metallic: Float? = nil
    ) throws {
        let index = descriptors.count
        let bodyID = id ?? "body-\(index)"
        let filename = "body-\(index).brep"
        let fileURL = outputDir.appendingPathComponent(filename)

        try Exporter.writeBREP(shape: shape, to: fileURL)

        let descriptor = BodyDescriptor(
            id: bodyID,
            file: filename,
            format: "brep",
            name: name,
            color: color,
            roughness: roughness,
            metallic: metallic
        )
        descriptors.append(descriptor)
        shapes.append((shape, bodyID))
    }

    // MARK: - Add Wire (profiles, sketches, paths)

    /// Add a wire to the output. Displayed as wireframe in the viewport.
    /// Useful for sketches, profiles, sweep paths, construction geometry.
    public func add(
        _ wire: Wire,
        id: String? = nil,
        color: [Float]? = nil,
        name: String? = nil
    ) throws {
        guard let shape = Shape.fromWire(wire) else {
            throw ScriptError.conversionFailed("Wire → Shape")
        }
        try add(shape, id: id, color: color, name: name)
    }

    // MARK: - Add Edge

    /// Add a single edge to the output. Displayed as wireframe.
    public func add(
        _ edge: Edge,
        id: String? = nil,
        color: [Float]? = nil,
        name: String? = nil
    ) throws {
        guard let shape = Shape.fromEdge(edge) else {
            throw ScriptError.conversionFailed("Edge → Shape")
        }
        try add(shape, id: id, color: color, name: name)
    }

    // MARK: - Add multiple shapes at once

    /// Add multiple shapes as a compound. Useful for assembly results.
    public func addCompound(
        _ shapes: [Shape],
        id: String? = nil,
        color: [Float]? = nil,
        name: String? = nil
    ) throws {
        guard let compound = Shape.compound(shapes) else {
            throw ScriptError.conversionFailed("Shapes → Compound")
        }
        try add(compound, id: id, color: color, name: name)
    }

    // MARK: - Emit

    /// Write manifest.json (trigger file) and optional STEP export.
    /// Call this LAST after all geometry is added.
    public func emit(description: String? = nil) throws {
        // Write combined STEP for external tool interop
        if exportSTEP {
            let allShapes = shapes.all.map { $0.0 }
            if !allShapes.isEmpty {
                let stepURL = outputDir.appendingPathComponent("output.step")
                if allShapes.count == 1 {
                    try Exporter.writeSTEP(shape: allShapes[0], to: stepURL, modelType: .asIs)
                } else if let compound = Shape.compound(allShapes) {
                    try Exporter.writeSTEP(shape: compound, to: stepURL, modelType: .asIs)
                }
            }
        }

        // Write manifest last (trigger file for watcher)
        let manifest = ScriptManifest(
            description: description,
            bodies: descriptors.all,
            metadata: metadata
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(manifest)
        let manifestURL = outputDir.appendingPathComponent("manifest.json")
        try data.write(to: manifestURL)

        let bodyCount = descriptors.count
        var msg = "Script output: \(bodyCount) bodies written to \(outputDir.path)"
        if exportSTEP {
            msg += "\n  STEP: output.step"
        }
        print(msg)
    }
}

// MARK: - Predefined Colors

extension ScriptContext {
    /// Common colors for quick use: `ctx.add(shape, color: .blue)`
    public enum Colors {
        public static let red:    [Float] = [0.9, 0.2, 0.2, 1.0]
        public static let green:  [Float] = [0.2, 0.8, 0.3, 1.0]
        public static let blue:   [Float] = [0.3, 0.5, 0.9, 1.0]
        public static let yellow: [Float] = [1.0, 0.9, 0.2, 1.0]
        public static let orange: [Float] = [0.9, 0.5, 0.2, 1.0]
        public static let purple: [Float] = [0.6, 0.3, 0.8, 1.0]
        public static let cyan:   [Float] = [0.2, 0.8, 0.9, 1.0]
        public static let white:  [Float] = [0.9, 0.9, 0.9, 1.0]
        public static let gray:   [Float] = [0.5, 0.5, 0.5, 1.0]
        public static let steel:  [Float] = [0.7, 0.7, 0.75, 1.0]
        public static let brass:  [Float] = [0.8, 0.7, 0.3, 1.0]
        public static let copper: [Float] = [0.8, 0.5, 0.3, 1.0]
    }
}

// MARK: - Errors

public enum ScriptError: Error, LocalizedError {
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conversionFailed(let detail):
            return "Conversion failed: \(detail)"
        }
    }
}

// MARK: - Thread-safe Array

private final class LockedArray<T>: @unchecked Sendable {
    private var storage: [T] = []
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }
}
