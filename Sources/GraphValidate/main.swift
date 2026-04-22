// GraphValidate — validate a BREP shape's topology graph.
//
// Usage: GraphValidate <shape.brep>
// Stdout: JSON { isValid, errorCount, warningCount }

import Foundation
import OCCTSwift
import ScriptHarness

let args = Array(CommandLine.arguments.dropFirst())
do {
    let path = try GraphIO.argument(at: 0, in: args, usage: "Usage: GraphValidate <shape.brep>")
    let shape = try GraphIO.loadBREP(at: path)
    let graph = try GraphIO.buildGraph(from: shape)
    try GraphIO.emitJSON(GraphIO.ValidationReport(graph.validate()))
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
