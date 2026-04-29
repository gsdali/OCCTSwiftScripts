// QueryTopology — find faces / edges / vertices matching criteria, return
// stable IDs for downstream calls.
//
// Part of the OCCTMCP-driver introspection batch (OCCTSwiftScripts#18).
// Pure read: input BREP -> JSON envelope on stdout.
//
// Stable entity IDs use the canonical "face[N]" / "edge[N]" / "vertex[N]"
// scheme based on the iteration order of Shape.faces() / .edges() /
// .vertices(). These indices are deterministic for a given BREP file.
//
// Filter keys supported (all optional, AND-combined):
//   surfaceType     (face only): plane | cylinder | cone | sphere | torus |
//                                bezierSurface | bsplineSurface |
//                                surfaceOfRevolution | surfaceOfExtrusion |
//                                offsetSurface | other
//   curveType       (edge only): line | circle | ellipse | hyperbola |
//                                parabola | bezierCurve | bsplineCurve |
//                                offsetCurve | other
//   minArea / maxArea           (face only)
//   minLength / maxLength       (edge only)
//   normalDirection + normalTolerance (face only) — match faces whose normal
//                                at the UV midpoint is within tolerance
//                                radians of the given vector
//
// `boundingBoxOverlap` from the issue is deferred to v2.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

enum QueryTopologyCommand: Subcommand {
    static let name = "query-topology"
    static let summary = "Find faces / edges / vertices matching criteria; return stable IDs"
    static let usage = """
        Usage:
          query-topology <input.brep> --entity face|edge|vertex
              [--filter '<json>'] [--limit N]
          query-topology <request.json>      (JSON request from file)
          query-topology                     (JSON request from stdin)
        """

    private struct Request {
        var inputBrep: String
        var entity: Entity
        var filter: Filter
        var limit: Int?
    }

    private enum Entity: String, Codable {
        case face, edge, vertex
    }

    private struct Filter: Decodable {
        var surfaceType: String?
        var curveType: String?
        var minArea: Double?
        var maxArea: Double?
        var minLength: Double?
        var maxLength: Double?
        var normalDirection: [Double]?
        var normalTolerance: Double?
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let entity: Entity
        let filter: Filter?
        let limit: Int?
    }

    struct Response: Encodable {
        let entity: String
        let results: [Result]
        let total: Int
        let truncated: Bool

        struct Result: Encodable {
            let id: String
            let surfaceType: String?
            let curveType: String?
            let area: Double?
            let length: Double?
            let centerOfMass: [Double]
            let normal: [Double]?
            let boundingBox: BoundingBox

            struct BoundingBox: Encodable {
                let min: [Double]
                let max: [Double]
            }
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let shape = try GraphIO.loadBREP(at: req.inputBrep)

        let allResults: [Response.Result]
        switch req.entity {
        case .face: allResults = try faceResults(shape: shape, filter: req.filter)
        case .edge: allResults = try edgeResults(shape: shape, filter: req.filter)
        case .vertex: allResults = try vertexResults(shape: shape, filter: req.filter)
        }

        let total = allResults.count
        let limited: [Response.Result]
        let truncated: Bool
        if let limit = req.limit, total > limit {
            limited = Array(allResults.prefix(limit))
            truncated = true
        } else {
            limited = allResults
            truncated = false
        }

        try GraphIO.emitJSON(Response(
            entity: req.entity.rawValue,
            results: limited,
            total: total,
            truncated: truncated
        ))
        return 0
    }

    // MARK: - Per-entity collection

    private static func faceResults(shape: Shape, filter: Filter) throws -> [Response.Result] {
        var out: [Response.Result] = []
        let faces = shape.faces()
        for (i, face) in faces.enumerated() {
            let kind = face.surfaceType.toString()
            if let want = filter.surfaceType, want != kind { continue }
            let area = face.area()
            if let m = filter.minArea, area < m { continue }
            if let m = filter.maxArea, area > m { continue }
            let bb = face.bounds
            let center = SIMD3<Double>((bb.min.x + bb.max.x) * 0.5,
                                       (bb.min.y + bb.max.y) * 0.5,
                                       (bb.min.z + bb.max.z) * 0.5)
            let normal: SIMD3<Double>? = {
                guard let uv = face.uvBounds else { return nil }
                let u = (uv.uMin + uv.uMax) * 0.5
                let v = (uv.vMin + uv.vMax) * 0.5
                guard let n = face.normal(atU: u, v: v) else { return nil }
                return simd_normalize(n)
            }()
            if let want = filter.normalDirection, let n = normal {
                let target = simd_normalize(SIMD3(want[0], want[1], want[2]))
                let tol = filter.normalTolerance ?? 0.05
                let cosAngle = simd_dot(n, target)
                if cosAngle < cos(tol) { continue }
            } else if filter.normalDirection != nil && normal == nil {
                continue
            }
            out.append(.init(
                id: "face[\(i)]",
                surfaceType: kind,
                curveType: nil,
                area: area,
                length: nil,
                centerOfMass: [center.x, center.y, center.z],
                normal: normal.map { [$0.x, $0.y, $0.z] },
                boundingBox: .init(min: [bb.min.x, bb.min.y, bb.min.z],
                                   max: [bb.max.x, bb.max.y, bb.max.z])
            ))
        }
        return out
    }

    private static func edgeResults(shape: Shape, filter: Filter) throws -> [Response.Result] {
        var out: [Response.Result] = []
        let edges = shape.edges()
        for (i, edge) in edges.enumerated() {
            let kind = edge.curveType.toString()
            if let want = filter.curveType, want != kind { continue }
            let length = edge.length
            if let m = filter.minLength, length < m { continue }
            if let m = filter.maxLength, length > m { continue }
            let bb = edge.bounds
            let center = SIMD3<Double>((bb.min.x + bb.max.x) * 0.5,
                                       (bb.min.y + bb.max.y) * 0.5,
                                       (bb.min.z + bb.max.z) * 0.5)
            out.append(.init(
                id: "edge[\(i)]",
                surfaceType: nil,
                curveType: kind,
                area: nil,
                length: length,
                centerOfMass: [center.x, center.y, center.z],
                normal: nil,
                boundingBox: .init(min: [bb.min.x, bb.min.y, bb.min.z],
                                   max: [bb.max.x, bb.max.y, bb.max.z])
            ))
        }
        return out
    }

    private static func vertexResults(shape: Shape, filter: Filter) throws -> [Response.Result] {
        let pts = shape.vertices()
        var out: [Response.Result] = []
        for (i, p) in pts.enumerated() {
            let bb = (min: p, max: p)
            out.append(.init(
                id: "vertex[\(i)]",
                surfaceType: nil,
                curveType: nil,
                area: nil,
                length: nil,
                centerOfMass: [p.x, p.y, p.z],
                normal: nil,
                boundingBox: .init(min: [bb.min.x, bb.min.y, bb.min.z],
                                   max: [bb.max.x, bb.max.y, bb.max.z])
            ))
        }
        return out
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var entity: Entity?
        var filter = Filter()
        var limit: Int?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--entity":
                i += 1
                guard i < args.count else { throw ScriptError.message("--entity expects a value") }
                guard let e = Entity(rawValue: args[i]) else {
                    throw ScriptError.message("--entity must be face|edge|vertex")
                }
                entity = e
            case "--filter":
                i += 1
                guard i < args.count else { throw ScriptError.message("--filter expects a JSON value") }
                let data = Data(args[i].utf8)
                do {
                    filter = try JSONDecoder().decode(Filter.self, from: data)
                } catch {
                    throw ScriptError.message("Invalid --filter JSON: \(error.localizedDescription)")
                }
            case "--limit":
                i += 1
                guard i < args.count, let n = Int(args[i]) else {
                    throw ScriptError.message("--limit expects an integer")
                }
                limit = n
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        guard let entity else { throw ScriptError.message("--entity is required") }
        return Request(inputBrep: inputBrep, entity: entity, filter: filter, limit: limit)
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
        return Request(inputBrep: raw.inputBrep, entity: raw.entity,
                       filter: raw.filter ?? Filter(), limit: raw.limit)
    }
}

private extension Face.SurfaceType {
    func toString() -> String {
        switch self {
        case .plane: return "plane"
        case .cylinder: return "cylinder"
        case .cone: return "cone"
        case .sphere: return "sphere"
        case .torus: return "torus"
        case .bezierSurface: return "bezierSurface"
        case .bsplineSurface: return "bsplineSurface"
        case .surfaceOfRevolution: return "surfaceOfRevolution"
        case .surfaceOfExtrusion: return "surfaceOfExtrusion"
        case .offsetSurface: return "offsetSurface"
        case .other: return "other"
        }
    }
}

private extension Edge.CurveType {
    func toString() -> String {
        switch self {
        case .line: return "line"
        case .circle: return "circle"
        case .ellipse: return "ellipse"
        case .hyperbola: return "hyperbola"
        case .parabola: return "parabola"
        case .bezierCurve: return "bezierCurve"
        case .bsplineCurve: return "bsplineCurve"
        case .offsetCurve: return "offsetCurve"
        case .other: return "other"
        }
    }
}
