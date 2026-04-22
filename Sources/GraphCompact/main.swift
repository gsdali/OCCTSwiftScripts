// GraphCompact — compact a BREP shape's topology graph (drop unreferenced nodes)
// and write the rebuilt shape to a new BREP file.
//
// Usage: GraphCompact <in.brep> <out.brep>
// Stdout: JSON { nodesBefore, nodesAfter, removed: { vertices, edges, faces }, output }

import Foundation
import OCCTSwift
import ScriptHarness

FileHandle.standardError.write(Data("DEPRECATED: 'GraphCompact' standalone target will be removed in a future release. Use 'occtkit graph-compact' instead.\n".utf8))

let args = Array(CommandLine.arguments.dropFirst())
do {
    let usage = "Usage: GraphCompact <in.brep> <out.brep>"
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
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
