import Foundation
import OCCTSwift
import ScriptHarness

enum GraphCompactCommand: Subcommand {
    static let name = "graph-compact"
    static let summary = "Compact a graph (drop unreferenced nodes), write rebuilt BREP"
    static let usage = "Usage: graph-compact <in.brep> <out.brep>"

    static func run(args: [String]) throws -> Int32 {
        let inPath = try GraphIO.argument(at: 0, in: args, usage: usage)
        let outPath = try GraphIO.argument(at: 1, in: args, usage: usage)

        let shape = try GraphIO.loadBREP(at: inPath)
        let graph = try GraphIO.buildGraph(from: shape)
        let nodesBefore = graph.stats.totalNodes
        let result = graph.compact()

        guard let rebuilt = GraphIO.rebuildShape(from: graph) else {
            throw ScriptError.message("Compact succeeded but graph has no root nodes to rebuild")
        }
        try GraphIO.writeBREP(rebuilt, to: outPath)

        try GraphIO.emitJSON(GraphIO.CompactReport(nodesBefore: nodesBefore, result: result, output: outPath))
        return 0
    }
}
