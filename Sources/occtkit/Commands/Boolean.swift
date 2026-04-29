// Boolean — union / subtract / intersect / split between two BREPs.
//
// Part of the OCCTMCP-driver verb batch (OCCTSwiftScripts#20). Pure function:
// reads two input BREPs, applies the requested boolean op, writes a single
// output BREP, emits a JSON envelope.
//
// Two input modes (auto-detected):
//
//   1. Flag form:
//      occtkit boolean --op union|subtract|intersect|split \
//          --a <a.brep> --b <b.brep> --output <out.brep>
//
//   2. JSON form (stdin or file path):
//      { "op": "...", "a": "...", "b": "...", "outputPath": "..." }
//
// Stdout: { "outputPath": "...", "volume": <double|null>, "isValid": <bool>,
//           "warnings": [<string>...] }.
//
// Notes:
//   - `split` returns a list of shapes; this verb wraps them in a Shape.compound
//     and writes a single BREP, per the issue spec. Downstream consumers
//     decompose the compound via Shape.subShapes if they need separate pieces.
//   - `volume` is null for non-solid results (compounds, shells without enclosed
//     volume, etc.); the optional Shape.volume is used.

import Foundation
import OCCTSwift
import ScriptHarness

enum BooleanCommand: Subcommand {
    static let name = "boolean"
    static let summary = "Boolean op (union/subtract/intersect/split) between two BREPs"
    static let usage = """
        Usage:
          boolean --op <op> --a <a.brep> --b <b.brep> --output <out.brep>
          boolean <request.json>             (JSON request from file)
          boolean                            (JSON request from stdin)

        Ops: union | subtract | intersect | split
        """

    private struct Request: Decodable {
        let op: String
        let a: String
        let b: String
        let outputPath: String
    }

    struct Response: Encodable {
        let outputPath: String
        let volume: Double?
        let isValid: Bool
        let warnings: [String]
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let aShape = try GraphIO.loadBREP(at: req.a)
        let bShape = try GraphIO.loadBREP(at: req.b)

        var warnings: [String] = []
        let result: Shape

        switch req.op {
        case "union":
            guard let r = aShape.union(bShape) else {
                throw ScriptError.message("union failed")
            }
            result = r
        case "subtract":
            guard let r = aShape.subtracting(bShape) else {
                throw ScriptError.message("subtract failed")
            }
            result = r
        case "intersect":
            guard let r = aShape.intersection(bShape) else {
                throw ScriptError.message("intersect failed")
            }
            result = r
        case "split":
            guard let pieces = aShape.split(by: bShape), !pieces.isEmpty else {
                throw ScriptError.message("split failed")
            }
            if pieces.count == 1 {
                warnings.append("split produced a single piece; tool did not divide a")
                result = pieces[0]
            } else {
                guard let compound = Shape.compound(pieces) else {
                    throw ScriptError.message("failed to wrap split pieces in a compound")
                }
                result = compound
            }
        default:
            throw ScriptError.message(
                "Unknown op '\(req.op)' (expected union | subtract | intersect | split)")
        }

        let outURL = URL(fileURLWithPath: req.outputPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GraphIO.writeBREP(result, to: outURL.path)

        try GraphIO.emitJSON(Response(
            outputPath: outURL.path,
            volume: result.volume,
            isValid: result.isValid,
            warnings: warnings
        ))
        return 0
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty || (args.first?.hasPrefix("-") != true && !args.contains("--op")) {
            // bare `boolean` with no args, or a positional that isn't a .json — treat as stdin JSON
            // unless flags are present
            if !args.contains("--op") {
                return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile())
            }
        }
        return try parseFlags(args: args)
    }

    private static func readFile(_ path: String) throws -> Data {
        guard let bytes = FileManager.default.contents(atPath: path) else {
            throw ScriptError.message("Failed to read request at \(path)")
        }
        return bytes
    }

    private static func decodeJSON(data: Data) throws -> Request {
        do {
            return try JSONDecoder().decode(Request.self, from: data)
        } catch {
            throw ScriptError.message("Invalid JSON: \(error.localizedDescription)")
        }
    }

    private static func parseFlags(args: [String]) throws -> Request {
        var op: String?, a: String?, b: String?, output: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--op":     op = try valueAfter(arg, at: &i, args: args)
            case "--a":      a = try valueAfter(arg, at: &i, args: args)
            case "--b":      b = try valueAfter(arg, at: &i, args: args)
            case "--output": output = try valueAfter(arg, at: &i, args: args)
            default:
                throw ScriptError.message("Unknown flag: \(arg)")
            }
            i += 1
        }
        guard let op, let a, let b, let output else {
            throw ScriptError.message("--op, --a, --b, and --output are all required")
        }
        return Request(op: op, a: a, b: b, outputPath: output)
    }

    private static func valueAfter(_ flag: String, at i: inout Int, args: [String]) throws -> String {
        i += 1
        guard i < args.count else { throw ScriptError.message("\(flag) expects a value") }
        return args[i]
    }
}
