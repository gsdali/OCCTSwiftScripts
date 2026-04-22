// Subcommand protocol for occtkit verbs.

import Foundation

protocol Subcommand {
    static var name: String { get }
    static var summary: String { get }
    static var usage: String { get }
    /// Run the subcommand with `args` (post-verb arguments). Throws on failure.
    /// Return value is the desired process exit code in one-shot mode.
    static func run(args: [String]) throws -> Int32
}

enum Registry {
    nonisolated(unsafe) static let all: [any Subcommand.Type] = [
        RunCommand.self,
        GraphValidateCommand.self,
        GraphCompactCommand.self,
        GraphDedupCommand.self,
        GraphQueryCommand.self,
        GraphMLCommand.self,
        FeatureRecognizeCommand.self,
        SolveSketchCommand.self,
        DXFExportCommand.self,
        DrawingExportCommand.self,
        ReconstructCommand.self,
    ]

    /// Verb names registered in `all`, in order, for the install Makefile.
    static var verbNames: [String] { all.map { $0.name } }

    static func find(_ name: String) -> (any Subcommand.Type)? {
        all.first { $0.name == name }
    }
}
