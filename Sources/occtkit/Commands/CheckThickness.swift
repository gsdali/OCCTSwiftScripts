// CheckThickness — wall-thickness analysis. Reports min / max / mean
// thickness across UV-grid-sampled faces and flags thin regions.
//
// Part of the OCCTMCP-driver engineering-analysis batch (OCCTSwiftScripts#21).
// Pure read; no file output.
//
// Algorithm (downstream):
//   1. For each face in the shape, get UV bounds and sample on a grid.
//   2. For each sample (u,v), evaluate point + normal on the face.
//   3. Cast a ray from (point + eps*inward) in the inward direction.
//      Inward = -normal; the eps offset (~1e-4) lets the ray escape the
//      starting face before checking for the nearest hit on the opposite
//      side. The smallest CSIntersection.parameter is the wall thickness.
//   4. Aggregate min / max / mean / sample count; flag samples whose
//      thickness falls below --min-acceptable as `thinRegions`.
//
// OCCTSwift v0.156 exposes:
//   Face.uvBounds, Face.point(atU:v:), Face.normal(atU:v:),
//   Shape.intersectLine(origin:direction:) -> [CSIntersection]
//
// All primitives in the issue spec are present upstream — no upstream
// dependency for this verb.
//
// Two input modes:
//   1. Flag form:
//      occtkit check-thickness <input.brep>
//          [--min-acceptable d]
//          [--sampling-density coarse|medium|fine]
//
//   2. JSON form:
//      { "inputBrep": "...", "minAcceptable": d,
//        "samplingDensity": "..." }

import Foundation
import simd
import OCCTSwift
import ScriptHarness

enum CheckThicknessCommand: Subcommand {
    static let name = "check-thickness"
    static let summary = "Wall-thickness analysis (UV-grid sample + inward ray cast)"
    static let usage = """
        Usage:
          check-thickness <input.brep>
              [--min-acceptable d] [--sampling-density coarse|medium|fine]
          check-thickness <request.json>
          check-thickness                   (JSON request from stdin)
        """

    private struct Request {
        var inputBrep: String
        var minAcceptable: Double?
        var samplingDensity: SamplingDensity
    }

    private enum SamplingDensity: String, Decodable {
        case coarse, medium, fine
        var grid: Int {
            switch self {
            case .coarse: return 4
            case .medium: return 8
            case .fine:   return 16
            }
        }
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let minAcceptable: Double?
        let samplingDensity: SamplingDensity?
    }

    struct Response: Encodable {
        let minThickness: Double?
        let maxThickness: Double?
        let meanThickness: Double?
        let thinRegions: [ThinRegion]
        let samples: Int

        struct ThinRegion: Encodable {
            let centerPoint: [Double]
            let thickness: Double
            let faceRefs: [String]
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let shape = try GraphIO.loadBREP(at: req.inputBrep)
        let faces = shape.faces()

        let resolution = req.samplingDensity.grid
        let eps = 1e-4
        var minT: Double = .infinity
        var maxT: Double = 0
        var sum: Double = 0
        var sampled = 0
        var thinRegions: [Response.ThinRegion] = []

        for (faceIndex, face) in faces.enumerated() {
            guard let uv = face.uvBounds else { continue }
            for i in 0..<resolution {
                for j in 0..<resolution {
                    let u = uv.uMin + (uv.uMax - uv.uMin) * Double(i) / Double(max(1, resolution - 1))
                    let v = uv.vMin + (uv.vMax - uv.vMin) * Double(j) / Double(max(1, resolution - 1))
                    guard let point = face.point(atU: u, v: v),
                          let normal = face.normal(atU: u, v: v) else { continue }
                    let n = simd_normalize(normal)
                    let inward = -n
                    let rayOrigin = point + eps * inward
                    let hits = shape.intersectLine(origin: rayOrigin, direction: inward)
                    // Find the smallest positive parameter; this is the thickness.
                    guard let nearest = hits
                        .map(\.parameter)
                        .filter({ $0 > 0 })
                        .min() else { continue }
                    let thickness = nearest
                    sampled += 1
                    sum += thickness
                    if thickness < minT { minT = thickness }
                    if thickness > maxT { maxT = thickness }
                    if let limit = req.minAcceptable, thickness < limit {
                        thinRegions.append(Response.ThinRegion(
                            centerPoint: [point.x, point.y, point.z],
                            thickness: thickness,
                            faceRefs: ["face[\(faceIndex)]"]
                        ))
                    }
                }
            }
        }

        let response = Response(
            minThickness: sampled > 0 ? minT : nil,
            maxThickness: sampled > 0 ? maxT : nil,
            meanThickness: sampled > 0 ? sum / Double(sampled) : nil,
            thinRegions: thinRegions,
            samples: sampled
        )
        try GraphIO.emitJSON(response)
        return 0
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--min-acceptable"), !args.contains("--sampling-density") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var minAcceptable: Double?
        var samplingDensity: SamplingDensity = .medium
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--min-acceptable":
                i += 1
                guard i < args.count, let d = Double(args[i]) else {
                    throw ScriptError.message("--min-acceptable expects a number")
                }
                minAcceptable = d
            case "--sampling-density":
                i += 1
                guard i < args.count, let s = SamplingDensity(rawValue: args[i]) else {
                    throw ScriptError.message("--sampling-density must be coarse|medium|fine")
                }
                samplingDensity = s
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        return Request(inputBrep: inputBrep, minAcceptable: minAcceptable,
                       samplingDensity: samplingDensity)
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
            inputBrep: raw.inputBrep,
            minAcceptable: raw.minAcceptable,
            samplingDensity: raw.samplingDensity ?? .medium
        )
    }
}
