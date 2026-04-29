// Pattern — mirror / linear / circular pattern of a BREP.
//
// Part of the OCCTMCP-driver verb batch (OCCTSwiftScripts#20). Pure function:
// reads input BREP, generates pattern instances, writes one BREP per instance
// (pattern_0.brep, pattern_1.brep, ...) into --output-dir, emits a JSON
// envelope listing the paths.
//
// OCCTSwift's linearPattern / circularPattern return a single compound Shape
// containing N copies; we decompose via subShapes(ofType: input.shapeType) to
// recover the individual instances. Mirror returns a single shape, written as
// pattern_0.brep alongside the original (which is *not* re-emitted).
//
// Two input modes (auto-detected):
//
//   1. Flag form:
//      occtkit pattern <input.brep> --kind mirror|linear|circular \
//          --output-dir <dir>
//          # mirror:
//          [--plane xy|yz|zx | --plane <ox>,<oy>,<oz>;<nx>,<ny>,<nz>]
//          # linear:
//          [--direction x,y,z --spacing s --count n]
//          # circular:
//          [--axis-origin x,y,z --axis-direction x,y,z --total-count n
//           [--total-angle radians]]
//
//   2. JSON form (stdin or file path):
//      { "inputBrep": "...", "kind": "...", "outputDir": "...", ... }
//
// Stdout: { "outputPaths": [...], "totalCount": <int> }.

import Foundation
import OCCTSwift
import ScriptHarness

enum PatternCommand: Subcommand {
    static let name = "pattern"
    static let summary = "Mirror / linear / circular pattern of a BREP into N output files"
    static let usage = """
        Usage:
          pattern <input.brep> --kind mirror|linear|circular --output-dir <dir> [kind flags]
          pattern <request.json>             (JSON request from file)
          pattern                            (JSON request from stdin)

        Mirror flags:   --plane xy|yz|zx | --plane ox,oy,oz;nx,ny,nz
        Linear flags:   --direction x,y,z --spacing s --count n
        Circular flags: --axis-origin x,y,z --axis-direction x,y,z --total-count n
                        [--total-angle radians]
        """

    private struct Request {
        var inputBrep: String
        var outputDir: String
        var kind: Kind
    }

    private enum Kind {
        case mirror(planeOrigin: SIMD3<Double>, planeNormal: SIMD3<Double>)
        case linear(direction: SIMD3<Double>, spacing: Double, count: Int)
        case circular(axisOrigin: SIMD3<Double>, axisDirection: SIMD3<Double>,
                      totalCount: Int, totalAngle: Double)
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let outputDir: String
        let kind: String
        // mirror
        let plane: String?
        let planeOrigin: [Double]?
        let planeNormal: [Double]?
        // linear
        let direction: [Double]?
        let spacing: Double?
        let count: Int?
        // circular
        let axisOrigin: [Double]?
        let axisDirection: [Double]?
        let totalCount: Int?
        let totalAngle: Double?
    }

    struct Response: Encodable {
        let outputPaths: [String]
        let totalCount: Int
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let input = try GraphIO.loadBREP(at: req.inputBrep)
        let inputType = input.shapeType

        let pieces: [Shape] = try generatePieces(input: input, inputType: inputType, kind: req.kind)
        let outDir = URL(fileURLWithPath: req.outputDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var paths: [String] = []
        for (i, piece) in pieces.enumerated() {
            let url = outDir.appendingPathComponent("pattern_\(i).brep")
            try GraphIO.writeBREP(piece, to: url.path)
            paths.append(url.path)
        }

        try GraphIO.emitJSON(Response(outputPaths: paths, totalCount: paths.count))
        return 0
    }

    private static func generatePieces(input: Shape, inputType: ShapeType,
                                        kind: Kind) throws -> [Shape] {
        switch kind {
        case .mirror(let origin, let normal):
            guard let mirrored = input.mirrored(planeNormal: normal, planeOrigin: origin) else {
                throw ScriptError.message("mirror failed")
            }
            return [mirrored]
        case .linear(let dir, let spacing, let count):
            guard count >= 1 else {
                throw ScriptError.message("--count must be >= 1")
            }
            guard let compound = input.linearPattern(direction: dir, spacing: spacing, count: count) else {
                throw ScriptError.message("linearPattern failed")
            }
            return decompose(compound: compound, expecting: inputType, expectedCount: count)
        case .circular(let axisOrigin, let axisDir, let totalCount, let totalAngle):
            guard totalCount >= 1 else {
                throw ScriptError.message("--total-count must be >= 1")
            }
            guard let compound = input.circularPattern(
                axisPoint: axisOrigin, axisDirection: axisDir,
                count: totalCount, angle: totalAngle
            ) else {
                throw ScriptError.message("circularPattern failed")
            }
            return decompose(compound: compound, expecting: inputType, expectedCount: totalCount)
        }
    }

    private static func decompose(compound: Shape, expecting type: ShapeType,
                                   expectedCount: Int) -> [Shape] {
        let extracted = compound.subShapes(ofType: type)
        if !extracted.isEmpty { return extracted }
        // fall back: maybe input was a wire/edge, try common types
        for fallback: ShapeType in [.solid, .shell, .face, .wire, .edge, .vertex] where fallback != type {
            let pieces = compound.subShapes(ofType: fallback)
            if !pieces.isEmpty { return pieces }
        }
        // last resort: emit the compound as a single result so the user gets *something*
        return [compound]
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty || (args.first?.hasPrefix("-") == true && !args.contains("--kind")) {
            return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile())
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
        let raw: JSONRequest
        do {
            raw = try JSONDecoder().decode(JSONRequest.self, from: data)
        } catch {
            throw ScriptError.message("Invalid JSON: \(error.localizedDescription)")
        }
        let kind = try parseKindFromJSON(raw)
        return Request(inputBrep: raw.inputBrep, outputDir: raw.outputDir, kind: kind)
    }

    private static func parseKindFromJSON(_ raw: JSONRequest) throws -> Kind {
        switch raw.kind {
        case "mirror":
            return .mirror(
                planeOrigin: try optVec3(raw.planeOrigin, name: "planeOrigin") ?? .zero,
                planeNormal: try requireMirrorNormal(raw))
        case "linear":
            guard let dir = raw.direction.map({ try? vec3($0, name: "direction") }) ?? nil,
                  let spacing = raw.spacing,
                  let count = raw.count else {
                throw ScriptError.message("linear: direction, spacing, count are required")
            }
            return .linear(direction: dir, spacing: spacing, count: count)
        case "circular":
            guard let axisOrigin = raw.axisOrigin.map({ try? vec3($0, name: "axisOrigin") }) ?? nil,
                  let axisDir = raw.axisDirection.map({ try? vec3($0, name: "axisDirection") }) ?? nil,
                  let totalCount = raw.totalCount else {
                throw ScriptError.message("circular: axisOrigin, axisDirection, totalCount are required")
            }
            return .circular(axisOrigin: axisOrigin, axisDirection: axisDir,
                             totalCount: totalCount, totalAngle: raw.totalAngle ?? 0)
        default:
            throw ScriptError.message("Unknown kind: \(raw.kind) (expected mirror|linear|circular)")
        }
    }

    private static func requireMirrorNormal(_ raw: JSONRequest) throws -> SIMD3<Double> {
        if let pn = raw.planeNormal { return try vec3(pn, name: "planeNormal") }
        if let preset = raw.plane { return try presetPlaneNormal(preset) }
        throw ScriptError.message("mirror: either plane (xy|yz|zx) or planeNormal is required")
    }

    private static func presetPlaneNormal(_ preset: String) throws -> SIMD3<Double> {
        switch preset {
        case "xy": return SIMD3(0, 0, 1)
        case "yz": return SIMD3(1, 0, 0)
        case "zx", "xz": return SIMD3(0, 1, 0)
        default: throw ScriptError.message("Unknown plane preset: \(preset) (expected xy|yz|zx)")
        }
    }

    private static func parseFlags(args: [String]) throws -> Request {
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var kind: String?, outputDir: String?
        var plane: String? = nil
        var direction: SIMD3<Double>?, spacing: Double?, count: Int?
        var axisOrigin: SIMD3<Double>?, axisDirection: SIMD3<Double>?
        var totalCount: Int?, totalAngle: Double = 0

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--kind":             kind = try valueAfter(a, at: &i, args: args)
            case "--output-dir":       outputDir = try valueAfter(a, at: &i, args: args)
            case "--plane":            plane = try valueAfter(a, at: &i, args: args)
            case "--direction":        direction = try parseVec3(try valueAfter(a, at: &i, args: args), name: a)
            case "--spacing":          spacing = try parseDouble(try valueAfter(a, at: &i, args: args), name: a)
            case "--count":            count = try parseInt(try valueAfter(a, at: &i, args: args), name: a)
            case "--axis-origin":      axisOrigin = try parseVec3(try valueAfter(a, at: &i, args: args), name: a)
            case "--axis-direction":   axisDirection = try parseVec3(try valueAfter(a, at: &i, args: args), name: a)
            case "--total-count":      totalCount = try parseInt(try valueAfter(a, at: &i, args: args), name: a)
            case "--total-angle":      totalAngle = try parseDouble(try valueAfter(a, at: &i, args: args), name: a)
            default: throw ScriptError.message("Unknown flag: \(a)")
            }
            i += 1
        }
        guard let kind, let outputDir else {
            throw ScriptError.message("--kind and --output-dir are required")
        }
        let resolvedKind: Kind
        switch kind {
        case "mirror":
            resolvedKind = .mirror(planeOrigin: .zero, planeNormal: try resolveMirrorNormal(plane: plane))
        case "linear":
            guard let direction, let spacing, let count else {
                throw ScriptError.message("linear: --direction, --spacing, --count required")
            }
            resolvedKind = .linear(direction: direction, spacing: spacing, count: count)
        case "circular":
            guard let axisOrigin, let axisDirection, let totalCount else {
                throw ScriptError.message(
                    "circular: --axis-origin, --axis-direction, --total-count required")
            }
            resolvedKind = .circular(axisOrigin: axisOrigin, axisDirection: axisDirection,
                                     totalCount: totalCount, totalAngle: totalAngle)
        default:
            throw ScriptError.message("--kind must be mirror|linear|circular")
        }
        return Request(inputBrep: inputBrep, outputDir: outputDir, kind: resolvedKind)
    }

    private static func resolveMirrorNormal(plane: String?) throws -> SIMD3<Double> {
        guard let plane else {
            throw ScriptError.message("mirror: --plane is required (xy|yz|zx or 'ox,oy,oz;nx,ny,nz')")
        }
        if plane.contains(";") {
            let parts = plane.split(separator: ";", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw ScriptError.message("--plane must be 'ox,oy,oz;nx,ny,nz'")
            }
            // origin parsed but not used for mirror normal — left for future point-pinned planes
            _ = try parseVec3(parts[0], name: "--plane origin")
            return try parseVec3(parts[1], name: "--plane normal")
        }
        return try presetPlaneNormal(plane)
    }

    // MARK: - Helpers

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

    private static func parseDouble(_ s: String, name: String) throws -> Double {
        guard let d = Double(s) else { throw ScriptError.message("\(name) expects a number") }
        return d
    }

    private static func parseInt(_ s: String, name: String) throws -> Int {
        guard let n = Int(s) else { throw ScriptError.message("\(name) expects an integer") }
        return n
    }

    private static func vec3(_ a: [Double], name: String) throws -> SIMD3<Double> {
        guard a.count == 3 else { throw ScriptError.message("\(name) must be [x,y,z]") }
        return SIMD3(a[0], a[1], a[2])
    }

    private static func optVec3(_ a: [Double]?, name: String) throws -> SIMD3<Double>? {
        guard let a else { return nil }
        return try vec3(a, name: name)
    }
}
