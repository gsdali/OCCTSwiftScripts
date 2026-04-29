// Metrics — volume / surface area / center of mass / bounding box / principal axes.
//
// Part of the OCCTMCP-driver introspection batch (OCCTSwiftScripts#18).
// Pure read: input BREP -> JSON envelope on stdout. No file output.
//
// Wraps:
//   Shape.volumeInertia    -> volume, centerOfMass, principalMoments + axes
//   Shape.surfaceArea      -> total area
//   Shape.bounds           -> axis-aligned bounding box
//
// `volumeInertia` is solid-only; for non-solids, volume / centerOfMass /
// principalAxes fall back to nil. surfaceArea is computed off the
// optional-returning getter, also nil for shapes without surface area.
//
// Two input modes:
//   1. Flag form:  occtkit metrics <brep> [--metrics m1,m2,...]
//   2. JSON form:  { "inputBrep": "...", "metrics": ["volume", ...] }

import Foundation
import OCCTSwift
import ScriptHarness

enum MetricsCommand: Subcommand {
    static let name = "metrics"
    static let summary = "Volume / area / center of mass / bbox / principal axes for a BREP"
    static let usage = """
        Usage:
          metrics <input.brep> [--metrics volume,surfaceArea,centerOfMass,boundingBox,principalAxes]
          metrics <request.json>             (JSON request from file)
          metrics                            (JSON request from stdin)
        """

    private struct Request {
        var inputBrep: String
        var metrics: Set<String>?  // nil = all
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let metrics: [String]?
    }

    struct Response: Encodable {
        let volume: Double?
        let surfaceArea: Double?
        let centerOfMass: [Double]?
        let boundingBox: BoundingBox?
        let principalAxes: PrincipalAxes?

        struct BoundingBox: Encodable {
            let min: [Double]
            let max: [Double]
        }
        struct PrincipalAxes: Encodable {
            let axes: [[Double]]
            let moments: [Double]
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let shape = try GraphIO.loadBREP(at: req.inputBrep)
        let want = req.metrics
        func wants(_ name: String) -> Bool { want == nil || want!.contains(name) }

        let inertia = wants("volume") || wants("centerOfMass") || wants("principalAxes")
            ? shape.volumeInertia : nil

        let bb: Response.BoundingBox? = {
            guard wants("boundingBox") else { return nil }
            let b = shape.bounds
            return .init(
                min: [b.min.x, b.min.y, b.min.z],
                max: [b.max.x, b.max.y, b.max.z]
            )
        }()

        let pa: Response.PrincipalAxes? = {
            guard wants("principalAxes"), let v = inertia else { return nil }
            return .init(
                axes: [
                    [v.principalAxes.0.x, v.principalAxes.0.y, v.principalAxes.0.z],
                    [v.principalAxes.1.x, v.principalAxes.1.y, v.principalAxes.1.z],
                    [v.principalAxes.2.x, v.principalAxes.2.y, v.principalAxes.2.z],
                ],
                moments: [v.principalMoments.x, v.principalMoments.y, v.principalMoments.z]
            )
        }()

        try GraphIO.emitJSON(Response(
            volume: wants("volume") ? inertia?.volume : nil,
            surfaceArea: wants("surfaceArea") ? shape.surfaceArea : nil,
            centerOfMass: wants("centerOfMass") ? inertia.map { v in
                [v.centerOfMass.x, v.centerOfMass.y, v.centerOfMass.z]
            } : nil,
            boundingBox: bb,
            principalAxes: pa
        ))
        return 0
    }

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        // Flag form
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var metrics: Set<String>? = nil
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--metrics":
                i += 1
                guard i < args.count else { throw ScriptError.message("--metrics expects a value") }
                metrics = Set(args[i].split(separator: ",").map(String.init))
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        return Request(inputBrep: inputBrep, metrics: metrics)
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
        return Request(inputBrep: raw.inputBrep,
                       metrics: raw.metrics.map(Set.init))
    }
}
