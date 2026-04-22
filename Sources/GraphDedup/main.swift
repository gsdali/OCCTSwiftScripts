// GraphDedup — deduplicate shared surface/curve geometry in a BREP shape's
// topology graph, then write the rebuilt shape to a new BREP file.
//
// Usage: GraphDedup <in.brep> <out.brep>
// Stdout: JSON { canonicalSurfaces, canonicalCurves, surfaceRewrites, curveRewrites, output }

import Foundation
import OCCTSwift
import ScriptHarness

FileHandle.standardError.write(Data("DEPRECATED: 'GraphDedup' standalone target will be removed in a future release. Use 'occtkit graph-dedup' instead.\n".utf8))

let args = Array(CommandLine.arguments.dropFirst())
do {
    let usage = "Usage: GraphDedup <in.brep> <out.brep>"
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
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
