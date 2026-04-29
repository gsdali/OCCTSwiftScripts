// AnalyzeClearance — pairwise interference / minimum-clearance check between
// two or more BREPs.
//
// Part of the OCCTMCP-driver engineering-analysis batch (OCCTSwiftScripts#21).
// Pure read: input BREPs -> JSON envelope on stdout. No file output.
//
// For each pair, runs Shape.allDistanceSolutions(to:) to get min distance +
// optional contacts. When the min distance is 0 (the bodies touch or
// overlap), additionally runs Shape.intersection(with:) and reports the
// interference volume (only meaningful for solid×solid; non-solid pairs
// emit `null`).
//
// Two input modes:
//   1. Flag form:
//      occtkit analyze-clearance <brep>... [--min-clearance d]
//          [--max-contacts N] [--no-contacts]
//
//   2. JSON form:
//      { "inputs": ["a.brep", "b.brep", ...],
//        "minClearance": <double|null>,
//        "maxContacts": <int|null>,
//        "computeContacts": <bool> }

import Foundation
import OCCTSwift
import ScriptHarness

enum AnalyzeClearanceCommand: Subcommand {
    static let name = "analyze-clearance"
    static let summary = "Pairwise interference / minimum-clearance between two or more BREPs"
    static let usage = """
        Usage:
          analyze-clearance <a.brep> <b.brep> [<c.brep>...]
              [--min-clearance d] [--max-contacts N] [--no-contacts]
          analyze-clearance <request.json>     (JSON request from file)
          analyze-clearance                    (JSON request from stdin)
        """

    private struct Request {
        var inputs: [String]
        var minClearance: Double?
        var maxContacts: Int
        var computeContacts: Bool
    }

    private struct JSONRequest: Decodable {
        let inputs: [String]
        let minClearance: Double?
        let maxContacts: Int?
        let computeContacts: Bool?
    }

    struct Response: Encodable {
        let pairs: [Pair]

        struct Pair: Encodable {
            let a: String
            let b: String
            let minDistance: Double
            let intersects: Bool
            let belowMinClearance: Bool?
            let contacts: [Contact]
            let interferenceVolume: Double?
        }
        struct Contact: Encodable {
            let fromPoint: [Double]
            let toPoint: [Double]
            let distance: Double
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        guard req.inputs.count >= 2 else {
            throw ScriptError.message("analyze-clearance needs at least 2 BREPs")
        }
        let shapes = try req.inputs.map { try GraphIO.loadBREP(at: $0) }

        var pairs: [Response.Pair] = []
        for i in 0..<shapes.count {
            for j in (i + 1)..<shapes.count {
                let a = shapes[i], b = shapes[j]
                guard let solutions = a.allDistanceSolutions(to: b, maxSolutions: req.maxContacts) else {
                    throw ScriptError.message(
                        "Distance computation failed for pair (\(req.inputs[i]), \(req.inputs[j]))")
                }
                let minDist = solutions.map { $0.distance }.min() ?? 0
                let intersects = minDist <= 0
                var interferenceVolume: Double? = nil
                if intersects, let intersection = a.intersection(b), let v = intersection.volume {
                    interferenceVolume = v
                }
                let contacts = req.computeContacts ? solutions.map { sol in
                    Response.Contact(
                        fromPoint: [sol.point1.x, sol.point1.y, sol.point1.z],
                        toPoint: [sol.point2.x, sol.point2.y, sol.point2.z],
                        distance: sol.distance
                    )
                } : []

                pairs.append(Response.Pair(
                    a: req.inputs[i], b: req.inputs[j],
                    minDistance: minDist,
                    intersects: intersects,
                    belowMinClearance: req.minClearance.map { minDist < $0 },
                    contacts: contacts,
                    interferenceVolume: interferenceVolume
                ))
            }
        }

        try GraphIO.emitJSON(Response(pairs: pairs))
        return 0
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           args.count == 1 {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        var inputs: [String] = []
        var minClearance: Double?
        var maxContacts = 32
        var computeContacts = true
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--min-clearance":
                i += 1
                guard i < args.count, let d = Double(args[i]) else {
                    throw ScriptError.message("--min-clearance expects a number")
                }
                minClearance = d
            case "--max-contacts":
                i += 1
                guard i < args.count, let n = Int(args[i]) else {
                    throw ScriptError.message("--max-contacts expects an integer")
                }
                maxContacts = n
            case "--no-contacts":
                computeContacts = false
            default:
                if a.hasPrefix("-") { throw ScriptError.message("Unknown flag: \(a)") }
                inputs.append(a)
            }
            i += 1
        }
        return Request(inputs: inputs, minClearance: minClearance,
                       maxContacts: maxContacts, computeContacts: computeContacts)
    }

    private static func readFile(_ path: String) throws -> Data {
        guard let bytes = FileManager.default.contents(atPath: path) else {
            throw ScriptError.message("Failed to read request at \(path)")
        }
        return bytes
    }

    private static func decodeJSON(data: Data) throws -> Request {
        let raw: JSONRequest
        do {
            raw = try JSONDecoder().decode(JSONRequest.self, from: data)
        } catch {
            throw ScriptError.message("Invalid JSON: \(error.localizedDescription)")
        }
        return Request(
            inputs: raw.inputs,
            minClearance: raw.minClearance,
            maxContacts: raw.maxContacts ?? 32,
            computeContacts: raw.computeContacts ?? true
        )
    }
}
