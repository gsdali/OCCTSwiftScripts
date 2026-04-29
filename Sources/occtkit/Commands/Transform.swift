// Transform — apply translation / rotation / uniform scale to a BREP.
//
// Part of the OCCTMCP-driver verb batch (OCCTSwiftScripts#20). Pure function:
// reads input BREP, applies the requested ops in declared order
// (translate -> rotate -> scale), writes a new BREP, emits a JSON envelope.
//
// Two input modes (auto-detected):
//
//   1. Flag form (matches the issue spec):
//      occtkit transform <input.brep> --output <out.brep>
//          [--translate x,y,z]
//          [--rotate-axis-angle x,y,z,radians | --rotate-euler-xyz x,y,z]
//          [--scale s | --scale x,y,z]   # only uniform supported (OCCTSwift)
//
//   2. JSON form (stdin or file path), useful for `--serve`:
//      { "inputBrep": "...", "outputPath": "...",
//        "translate": [x,y,z],
//        "rotateAxisAngle": [x,y,z,radians] | "rotateEulerXyz": [x,y,z],
//        "scale": s | [x,y,z] }
//
// Stdout: { "outputPath": "...", "trsf": [16 floats — column-major 4x4] }.
//
// Notes:
//   - OCCTSwift's `scaled(by: Double)` is uniform-only. A non-uniform `--scale x,y,z`
//     vector fails with a clear ScriptError pointing at the upstream limitation.
//   - `--rotate-euler-xyz` decomposes to three sequential axis-angle rotations
//     (Rx then Ry then Rz, extrinsic).

import Foundation
import simd
import OCCTSwift
import ScriptHarness

enum TransformCommand: Subcommand {
    static let name = "transform"
    static let summary = "Apply translate / rotate / uniform-scale to a BREP"
    static let usage = """
        Usage:
          transform <input.brep> --output <out.brep> [transform flags]
          transform <request.json>           (JSON request from file)
          transform                          (JSON request from stdin)

        Flags (flag form):
          --translate x,y,z
          --rotate-axis-angle x,y,z,radians
          --rotate-euler-xyz x,y,z           (extrinsic XYZ; converted to axis-angle)
          --scale s                          (uniform only; non-uniform rejected)
          --output <path>
        """

    private struct Request {
        var inputBrep: String
        var outputPath: String
        var translate: SIMD3<Double>?
        var rotateAxisAngle: (axis: SIMD3<Double>, radians: Double)?
        var rotateEulerXyz: SIMD3<Double>?
        var scale: Double?
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let outputPath: String
        let translate: [Double]?
        let rotateAxisAngle: [Double]?
        let rotateEulerXyz: [Double]?
        let scale: ScaleSpec?
        enum ScaleSpec: Decodable {
            case uniform(Double)
            case vector([Double])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .uniform(d); return }
                if let v = try? c.decode([Double].self) { self = .vector(v); return }
                throw DecodingError.typeMismatch(ScaleSpec.self,
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "scale must be Number or [x,y,z]"))
            }
        }
    }

    struct Response: Encodable {
        let outputPath: String
        let trsf: [Double]
    }

    static func run(args: [String]) throws -> Int32 {
        let request = try parseRequest(args: args)
        let input = try GraphIO.loadBREP(at: request.inputBrep)

        var current = input
        var trsf = simd_double4x4(1.0)

        if let t = request.translate {
            guard let next = current.translated(by: t) else {
                throw ScriptError.message("translate failed")
            }
            current = next
            trsf = makeTranslation(t) * trsf
        }

        if let raa = request.rotateAxisAngle {
            guard let next = current.rotated(axis: raa.axis, angle: raa.radians) else {
                throw ScriptError.message("rotate-axis-angle failed")
            }
            current = next
            trsf = makeRotation(axis: raa.axis, angle: raa.radians) * trsf
        } else if let euler = request.rotateEulerXyz {
            // Extrinsic XYZ: Rz * Ry * Rx applied to the point. Apply in that order
            // by rotating around X first, then Y, then Z (each call composes left).
            let stages: [(SIMD3<Double>, Double)] = [
                (SIMD3(1, 0, 0), euler.x),
                (SIMD3(0, 1, 0), euler.y),
                (SIMD3(0, 0, 1), euler.z),
            ]
            for (axis, angle) in stages where angle != 0 {
                guard let next = current.rotated(axis: axis, angle: angle) else {
                    throw ScriptError.message("rotate-euler-xyz failed at axis \(axis)")
                }
                current = next
                trsf = makeRotation(axis: axis, angle: angle) * trsf
            }
        }

        if let s = request.scale {
            guard let next = current.scaled(by: s) else {
                throw ScriptError.message("scale failed")
            }
            current = next
            trsf = makeUniformScale(s) * trsf
        }

        let outURL = URL(fileURLWithPath: request.outputPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GraphIO.writeBREP(current, to: outURL.path)

        try GraphIO.emitJSON(Response(outputPath: outURL.path, trsf: flatten(trsf)))
        return 0
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        // JSON path: first arg is a file ending .json, OR no positional arg at all (stdin).
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-") {
            return try decodeJSONRequest(data: try readFile(first))
        }
        if args.isEmpty || (args.first?.hasPrefix("-") == true && !args.contains("--output")) {
            return try decodeJSONRequest(data: FileHandle.standardInput.readDataToEndOfFile())
        }
        return try parseFlagRequest(args: args)
    }

    private static func readFile(_ path: String) throws -> Data {
        guard let bytes = FileManager.default.contents(atPath: path) else {
            throw ScriptError.message("Failed to read request at \(path)")
        }
        return bytes
    }

    private static func decodeJSONRequest(data: Data) throws -> Request {
        let raw: JSONRequest
        do {
            raw = try JSONDecoder().decode(JSONRequest.self, from: data)
        } catch {
            throw ScriptError.message("Invalid JSON: \(error.localizedDescription)")
        }
        var req = Request(inputBrep: raw.inputBrep, outputPath: raw.outputPath,
                          translate: nil, rotateAxisAngle: nil,
                          rotateEulerXyz: nil, scale: nil)
        if let t = raw.translate { req.translate = try vec3(t, name: "translate") }
        if let r = raw.rotateAxisAngle {
            guard r.count == 4 else {
                throw ScriptError.message("rotateAxisAngle must be [x,y,z,radians]")
            }
            req.rotateAxisAngle = (SIMD3(r[0], r[1], r[2]), r[3])
        }
        if let e = raw.rotateEulerXyz { req.rotateEulerXyz = try vec3(e, name: "rotateEulerXyz") }
        if let s = raw.scale {
            switch s {
            case .uniform(let d): req.scale = d
            case .vector(let v):
                guard v.count == 3 else { throw ScriptError.message("scale vector must be [x,y,z]") }
                guard v[0] == v[1] && v[1] == v[2] else {
                    throw ScriptError.message(
                        "non-uniform scale not supported (OCCTSwift scaled(by:) is uniform); got \(v)")
                }
                req.scale = v[0]
            }
        }
        try validateRotationExclusivity(req)
        return req
    }

    private static func parseFlagRequest(args: [String]) throws -> Request {
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var output: String? = nil
        var translate: SIMD3<Double>? = nil
        var rotateAxisAngle: (SIMD3<Double>, Double)? = nil
        var rotateEulerXyz: SIMD3<Double>? = nil
        var scale: Double? = nil

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--output":
                output = try valueAfter(a, at: &i, args: args)
            case "--translate":
                translate = try parseVec3(try valueAfter(a, at: &i, args: args), name: a)
            case "--rotate-axis-angle":
                let s = try valueAfter(a, at: &i, args: args)
                let v = s.split(separator: ",").compactMap { Double($0) }
                guard v.count == 4 else { throw ScriptError.message("\(a) expects x,y,z,radians") }
                rotateAxisAngle = (SIMD3(v[0], v[1], v[2]), v[3])
            case "--rotate-euler-xyz":
                rotateEulerXyz = try parseVec3(try valueAfter(a, at: &i, args: args), name: a)
            case "--scale":
                let s = try valueAfter(a, at: &i, args: args)
                let v = s.split(separator: ",").compactMap { Double($0) }
                if v.count == 1 {
                    scale = v[0]
                } else if v.count == 3 {
                    guard v[0] == v[1] && v[1] == v[2] else {
                        throw ScriptError.message(
                            "non-uniform --scale not supported (OCCTSwift scaled(by:) is uniform); got \(v)")
                    }
                    scale = v[0]
                } else {
                    throw ScriptError.message("--scale expects s or x,y,z")
                }
            default:
                throw ScriptError.message("Unknown flag: \(a)")
            }
            i += 1
        }
        guard let outputPath = output else {
            throw ScriptError.message("--output is required")
        }
        let req = Request(inputBrep: inputBrep, outputPath: outputPath,
                          translate: translate, rotateAxisAngle: rotateAxisAngle,
                          rotateEulerXyz: rotateEulerXyz, scale: scale)
        try validateRotationExclusivity(req)
        return req
    }

    private static func valueAfter(_ flag: String, at i: inout Int, args: [String]) throws -> String {
        i += 1
        guard i < args.count else { throw ScriptError.message("\(flag) expects a value") }
        return args[i]
    }

    private static func parseVec3(_ s: String, name: String) throws -> SIMD3<Double> {
        let v = s.split(separator: ",").compactMap { Double($0) }
        guard v.count == 3 else { throw ScriptError.message("\(name) expects x,y,z") }
        return SIMD3(v[0], v[1], v[2])
    }

    private static func vec3(_ a: [Double], name: String) throws -> SIMD3<Double> {
        guard a.count == 3 else { throw ScriptError.message("\(name) must be [x,y,z]") }
        return SIMD3(a[0], a[1], a[2])
    }

    private static func validateRotationExclusivity(_ r: Request) throws {
        if r.rotateAxisAngle != nil && r.rotateEulerXyz != nil {
            throw ScriptError.message(
                "rotateAxisAngle and rotateEulerXyz are mutually exclusive")
        }
    }

    // MARK: - Trsf accumulation (column-major 4x4)

    private static func makeTranslation(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = simd_double4x4(1.0)
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1.0)
        return m
    }

    private static func makeUniformScale(_ s: Double) -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4(s, s, s, 1.0))
    }

    private static func makeRotation(axis: SIMD3<Double>, angle: Double) -> simd_double4x4 {
        let n = simd_normalize(axis)
        let c = cos(angle), s = sin(angle), one = 1 - c
        let x = n.x, y = n.y, z = n.z
        return simd_double4x4(
            SIMD4(c + x*x*one,      y*x*one + z*s,  z*x*one - y*s,  0),
            SIMD4(x*y*one - z*s,    c + y*y*one,    z*y*one + x*s,  0),
            SIMD4(x*z*one + y*s,    y*z*one - x*s,  c + z*z*one,    0),
            SIMD4(0, 0, 0, 1)
        )
    }

    private static func flatten(_ m: simd_double4x4) -> [Double] {
        let cols = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        return cols.flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
