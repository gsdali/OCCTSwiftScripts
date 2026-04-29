// MeasureDistance — minimum distance / contacts between two BREPs (or a
// BREP and a point).
//
// Part of the OCCTMCP-driver introspection batch (OCCTSwiftScripts#18).
// Pure read: input BREP(s) -> JSON envelope on stdout.
//
// Wraps Shape.allDistanceSolutions(to:maxSolutions:) for the multi-contact
// case and Shape.minDistance(to:) for the simple single-distance case.
//
// Two input modes:
//   1. Flag form:
//      occtkit measure-distance <a.brep> <b.brep>
//          [--from-ref <ref>] [--to-ref <ref>] [--compute-contacts]
//
//      Refs supported (v1):
//        - omitted               -> whole shape
//        - "point:x,y,z"         -> a point in space (synthesised as a vertex)
//      Sub-entity refs ("face[N]", "edge[N]", "vertex[N]") are deferred —
//      the shape-vs-shape distance over the parent BREPs already returns
//      contacts that include sub-entity provenance via the underlying
//      DistanceSolution. Callers can use query-topology to identify which
//      face/edge/vertex a contact lies on.
//
//   2. JSON form:
//      { "a": "...", "b": "...", "fromRef": "...", "toRef": "...",
//        "computeContacts": true }

import Foundation
import OCCTSwift
import ScriptHarness

enum MeasureDistanceCommand: Subcommand {
    static let name = "measure-distance"
    static let summary = "Minimum distance and contacts between two BREPs (or a BREP and a point)"
    static let usage = """
        Usage:
          measure-distance <a.brep> <b.brep>
              [--from-ref <ref>] [--to-ref <ref>] [--compute-contacts]
          measure-distance <request.json>     (JSON request from file)
          measure-distance                    (JSON request from stdin)

        Refs (v1): "point:x,y,z" or omit for whole shape.
        """

    private struct Request {
        var a: String
        var b: String
        var fromRef: String?
        var toRef: String?
        var computeContacts: Bool
    }

    private struct JSONRequest: Decodable {
        let a: String
        let b: String
        let fromRef: String?
        let toRef: String?
        let computeContacts: Bool?
    }

    struct Response: Encodable {
        let minDistance: Double
        let isParallel: Bool
        let contacts: [Contact]

        struct Contact: Encodable {
            let fromPoint: [Double]
            let toPoint: [Double]
            let distance: Double
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let aShape = try resolveShape(brepPath: req.a, ref: req.fromRef, label: "from")
        let bShape = try resolveShape(brepPath: req.b, ref: req.toRef, label: "to")

        guard let solutions = aShape.allDistanceSolutions(to: bShape, maxSolutions: 32) else {
            throw ScriptError.message("Distance computation failed")
        }
        let minDistance = solutions.map { $0.distance }.min() ?? 0

        let contacts = req.computeContacts ? solutions.map { sol in
            Response.Contact(
                fromPoint: [sol.point1.x, sol.point1.y, sol.point1.z],
                toPoint: [sol.point2.x, sol.point2.y, sol.point2.z],
                distance: sol.distance
            )
        } : []

        try GraphIO.emitJSON(Response(
            minDistance: minDistance,
            isParallel: false,  // shape-shape: not meaningful (edge-edge has its own API)
            contacts: contacts
        ))
        return 0
    }

    /// Resolve an optional sub-entity ref. v1: only "point:x,y,z" is supported;
    /// any other ref form falls through to the whole-BREP load.
    private static func resolveShape(brepPath: String, ref: String?, label: String) throws -> Shape {
        if let ref, ref.hasPrefix("point:") {
            let coords = ref.dropFirst("point:".count)
            let v = coords.split(separator: ",").compactMap { Double($0) }
            guard v.count == 3 else {
                throw ScriptError.message("\(label) ref 'point:' expects x,y,z")
            }
            guard let vertex = Shape.vertex(at: SIMD3(v[0], v[1], v[2])) else {
                throw ScriptError.message("Failed to construct \(label) vertex")
            }
            return vertex
        }
        return try GraphIO.loadBREP(at: brepPath)
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           args.count == 1 || args[1].hasPrefix("-") == false {
            // .json with no other positional likely means JSON file
            if args.count == 1 {
                return try decodeJSON(data: try readFile(first))
            }
        }
        if args.count == 1, args[0].hasSuffix(".json") {
            return try decodeJSON(data: try readFile(args[0]))
        }
        if args.isEmpty {
            return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile())
        }
        // Flag form: two positionals first, then flags
        guard args.count >= 2, !args[0].hasPrefix("-"), !args[1].hasPrefix("-") else {
            throw ScriptError.message("Expected: <a.brep> <b.brep> [flags]")
        }
        var fromRef: String?, toRef: String?
        var computeContacts = false
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--from-ref":
                i += 1
                guard i < args.count else { throw ScriptError.message("--from-ref expects a value") }
                fromRef = args[i]
            case "--to-ref":
                i += 1
                guard i < args.count else { throw ScriptError.message("--to-ref expects a value") }
                toRef = args[i]
            case "--compute-contacts":
                computeContacts = true
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        return Request(a: args[0], b: args[1], fromRef: fromRef, toRef: toRef,
                       computeContacts: computeContacts)
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
        return Request(a: raw.a, b: raw.b, fromRef: raw.fromRef, toRef: raw.toRef,
                       computeContacts: raw.computeContacts ?? false)
    }
}
