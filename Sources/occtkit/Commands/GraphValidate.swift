import Foundation
import OCCTSwift
import ScriptHarness

enum GraphValidateCommand: Subcommand {
    static let name = "graph-validate"
    static let summary = "Validate a BREP shape's topology graph"
    static let usage = "Usage: graph-validate <shape.brep>"

    static func run(args: [String]) throws -> Int32 {
        let path = try GraphIO.argument(at: 0, in: args, usage: usage)
        let shape = try GraphIO.loadBREP(at: path)
        let graph = try GraphIO.buildGraph(from: shape)
        try GraphIO.emitJSON(GraphIO.ValidationReport(graph.validate()))
        return 0
    }
}
