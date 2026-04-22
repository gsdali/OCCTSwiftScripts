import Foundation
import OCCTSwift
import ScriptHarness

enum GraphDedupCommand: Subcommand {
    static let name = "graph-dedup"
    static let summary = "Deduplicate shared surface/curve geometry, write rebuilt BREP"
    static let usage = "Usage: graph-dedup <in.brep> <out.brep>"

    static func run(args: [String]) throws -> Int32 {
        let inPath = try GraphIO.argument(at: 0, in: args, usage: usage)
        let outPath = try GraphIO.argument(at: 1, in: args, usage: usage)

        let shape = try GraphIO.loadBREP(at: inPath)
        let graph = try GraphIO.buildGraph(from: shape)
        let result = graph.deduplicate()

        guard let rebuilt = GraphIO.rebuildShape(from: graph) else {
            throw ScriptError.message("Deduplicate succeeded but graph has no root nodes to rebuild")
        }
        try GraphIO.writeBREP(rebuilt, to: outPath)

        try GraphIO.emitJSON(GraphIO.DedupReport(result, output: outPath))
        return 0
    }
}
