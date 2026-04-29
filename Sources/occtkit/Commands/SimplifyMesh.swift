// SimplifyMesh — QEM mesh decimation via OCCTSwiftMesh.
//
// Closes the second half of #22. OCCTSwift#92 was closed as out-of-scope
// (mesh-domain algorithms ruled out of OCCT-core wrapper); the work moved
// to a sibling repo `OCCTSwiftMesh` that vendors meshoptimizer
// (BSD-2-Clause / MIT-equivalent) inside an LGPL-2.1 wrapper.
// OCCTSwiftMesh v0.1.0 ships `Mesh.simplified(_:)`, which this verb wraps.
//
// Pipeline:
//   1. Load input BREP and generate a fine mesh via Shape.mesh(parameters:).
//   2. Compute before-mesh aspect-ratio stats (reused from Mesh.swift's
//      computeQuality logic, kept inline here to avoid cross-file
//      coupling).
//   3. Hand the mesh to OCCTSwiftMesh.Mesh.simplified(_:) with the parsed
//      SimplifyOptions.
//   4. Compute after-mesh stats.
//   5. Write the decimated mesh to --output (.stl or .obj) via a small
//      Mesh-direct ASCII writer (OCCTSwift's writeSTL/writeOBJ both
//      take Shape, not Mesh).
//   6. Emit JSON envelope with before/after counts + qualityDelta
//      (meanAspectRatioDelta + hausdorffDistance from the upstream result).
//
// Two input modes:
//   1. Flag form:
//      occtkit simplify-mesh <input.brep>
//          (--target-triangle-count N | --target-reduction R)
//          [--preserve-boundary] [--preserve-topology]
//          [--max-hausdorff-distance d]
//          [--linear-deflection d] [--angular-deflection d]
//          --output <path.stl|.obj>
//
//   2. JSON form:
//      { "inputBrep": "...",
//        "targetTriangleCount": N | "targetReduction": R,
//        "preserveBoundary": <bool>, "preserveTopology": <bool>,
//        "maxHausdorffDistance": d,
//        "linearDeflection": d, "angularDeflection": d,
//        "outputPath": "..." }

import Foundation
import simd
import OCCTSwift
import OCCTSwiftMesh
import ScriptHarness

enum SimplifyMeshCommand: Subcommand {
    static let name = "simplify-mesh"
    static let summary = "Decimate a mesh to a target triangle count via QEM (OCCTSwiftMesh)"
    static let usage = """
        Usage:
          simplify-mesh <input.brep>
              (--target-triangle-count N | --target-reduction R)
              [--preserve-boundary] [--preserve-topology]
              [--max-hausdorff-distance d]
              [--linear-deflection d] [--angular-deflection d]
              --output <path.stl|.obj>
          simplify-mesh <request.json>
          simplify-mesh                     (JSON request from stdin)
        """

    private struct Request {
        var inputBrep: String
        var outputPath: String
        var targetTriangleCount: Int?
        var targetReduction: Double?
        var preserveBoundary: Bool
        var preserveTopology: Bool
        var maxHausdorffDistance: Double?
        var linearDeflection: Double
        var angularDeflection: Double
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let outputPath: String
        let targetTriangleCount: Int?
        let targetReduction: Double?
        let preserveBoundary: Bool?
        let preserveTopology: Bool?
        let maxHausdorffDistance: Double?
        let linearDeflection: Double?
        let angularDeflection: Double?
    }

    struct Response: Encodable {
        let beforeTriangleCount: Int
        let afterTriangleCount: Int
        let qualityDelta: QualityDelta
        let outputPath: String

        struct QualityDelta: Encodable {
            let meanAspectRatioDelta: Double
            let hausdorffDistance: Double
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let shape = try GraphIO.loadBREP(at: req.inputBrep)

        var params = MeshParameters.default
        params.deflection = req.linearDeflection
        params.angle = req.angularDeflection
        guard let inputMesh = shape.mesh(parameters: params) else {
            throw ScriptError.message("Mesh generation failed (BRepMesh_IncrementalMesh returned nil)")
        }
        let beforeMeanAR = meanAspectRatio(of: inputMesh)

        let options = Mesh.SimplifyOptions(
            targetTriangleCount: req.targetTriangleCount,
            targetReduction: req.targetReduction,
            preserveBoundary: req.preserveBoundary,
            preserveTopology: req.preserveTopology,
            maxHausdorffDistance: req.maxHausdorffDistance
        )
        guard let result = inputMesh.simplified(options) else {
            throw ScriptError.message(
                "Simplification failed — check options (need exactly one of --target-triangle-count / --target-reduction; values must be in valid ranges)")
        }
        let afterMeanAR = meanAspectRatio(of: result.mesh)

        try writeMesh(mesh: result.mesh, path: req.outputPath)

        try GraphIO.emitJSON(Response(
            beforeTriangleCount: result.beforeTriangleCount,
            afterTriangleCount: result.afterTriangleCount,
            qualityDelta: .init(
                meanAspectRatioDelta: afterMeanAR - beforeMeanAR,
                hausdorffDistance: result.hausdorffDistance
            ),
            outputPath: req.outputPath
        ))
        return 0
    }

    // MARK: - Mesh quality (reused-by-shape)

    private static func meanAspectRatio(of mesh: Mesh) -> Double {
        let verts = mesh.vertices
        let idxs = mesh.indices
        var sum: Double = 0
        var n = 0
        let triCount = idxs.count / 3
        for t in 0..<triCount {
            let i0 = Int(idxs[t * 3])
            let i1 = Int(idxs[t * 3 + 1])
            let i2 = Int(idxs[t * 3 + 2])
            guard i0 < verts.count, i1 < verts.count, i2 < verts.count else { continue }
            let a = verts[i0], b = verts[i1], c = verts[i2]
            let e0 = simd_length(b - a)
            let e1 = simd_length(c - b)
            let e2 = simd_length(a - c)
            let mn = min(e0, min(e1, e2))
            let mx = max(e0, max(e1, e2))
            if mn > 1e-9 { sum += Double(mx / mn); n += 1 }
        }
        return n > 0 ? sum / Double(n) : 1.0
    }

    // MARK: - ASCII STL / OBJ writers (Mesh-direct; OCCTSwift's writers take Shape)

    private static func writeMesh(mesh: Mesh, path: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "stl": try writeASCIISTL(mesh: mesh, to: url)
        case "obj": try writeOBJ(mesh: mesh, to: url)
        default: throw ScriptError.message("Unsupported --output extension '\(ext)'; use .stl or .obj")
        }
    }

    private static func writeASCIISTL(mesh: Mesh, to url: URL) throws {
        let verts = mesh.vertices
        let idxs = mesh.indices
        var out = "solid simplified\n"
        let triCount = idxs.count / 3
        for t in 0..<triCount {
            let i0 = Int(idxs[t * 3])
            let i1 = Int(idxs[t * 3 + 1])
            let i2 = Int(idxs[t * 3 + 2])
            guard i0 < verts.count, i1 < verts.count, i2 < verts.count else { continue }
            let a = verts[i0], b = verts[i1], c = verts[i2]
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n"
            out += "  endfacet\n"
        }
        out += "endsolid simplified\n"
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ScriptError.message("Failed to write STL at \(url.path): \(error.localizedDescription)")
        }
    }

    private static func writeOBJ(mesh: Mesh, to url: URL) throws {
        let verts = mesh.vertices
        let idxs = mesh.indices
        var out = "# OCCTSwiftScripts simplify-mesh\n"
        for v in verts { out += "v \(v.x) \(v.y) \(v.z)\n" }
        let triCount = idxs.count / 3
        for t in 0..<triCount {
            let i0 = idxs[t * 3] + 1   // OBJ is 1-indexed
            let i1 = idxs[t * 3 + 1] + 1
            let i2 = idxs[t * 3 + 2] + 1
            out += "f \(i0) \(i1) \(i2)\n"
        }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ScriptError.message("Failed to write OBJ at \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--output") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var output: String?
        var targetTriangleCount: Int?
        var targetReduction: Double?
        var preserveBoundary = true
        var preserveTopology = true
        var maxHausdorff: Double?
        var linearDeflection = 0.1
        var angularDeflection = 0.5
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--output":          i += 1; output = try v(args, i, "--output")
            case "--target-triangle-count":
                i += 1
                guard let n = Int(try v(args, i, "--target-triangle-count")) else {
                    throw ScriptError.message("--target-triangle-count expects an integer")
                }
                targetTriangleCount = n
            case "--target-reduction":
                i += 1
                guard let d = Double(try v(args, i, "--target-reduction")) else {
                    throw ScriptError.message("--target-reduction expects a number")
                }
                targetReduction = d
            case "--preserve-boundary":             preserveBoundary = true
            case "--no-preserve-boundary":          preserveBoundary = false
            case "--preserve-topology":             preserveTopology = true
            case "--no-preserve-topology":          preserveTopology = false
            case "--max-hausdorff-distance":
                i += 1
                guard let d = Double(try v(args, i, "--max-hausdorff-distance")) else {
                    throw ScriptError.message("--max-hausdorff-distance expects a number")
                }
                maxHausdorff = d
            case "--linear-deflection":
                i += 1
                guard let d = Double(try v(args, i, "--linear-deflection")) else {
                    throw ScriptError.message("--linear-deflection expects a number")
                }
                linearDeflection = d
            case "--angular-deflection":
                i += 1
                guard let d = Double(try v(args, i, "--angular-deflection")) else {
                    throw ScriptError.message("--angular-deflection expects a number")
                }
                angularDeflection = d
            default: throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        guard let outputPath = output else { throw ScriptError.message("--output is required") }
        return Request(
            inputBrep: inputBrep, outputPath: outputPath,
            targetTriangleCount: targetTriangleCount, targetReduction: targetReduction,
            preserveBoundary: preserveBoundary, preserveTopology: preserveTopology,
            maxHausdorffDistance: maxHausdorff,
            linearDeflection: linearDeflection, angularDeflection: angularDeflection
        )
    }

    private static func v(_ args: [String], _ i: Int, _ flag: String) throws -> String {
        guard i < args.count else { throw ScriptError.message("\(flag) expects a value") }
        return args[i]
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
            inputBrep: raw.inputBrep, outputPath: raw.outputPath,
            targetTriangleCount: raw.targetTriangleCount,
            targetReduction: raw.targetReduction,
            preserveBoundary: raw.preserveBoundary ?? true,
            preserveTopology: raw.preserveTopology ?? true,
            maxHausdorffDistance: raw.maxHausdorffDistance,
            linearDeflection: raw.linearDeflection ?? 0.1,
            angularDeflection: raw.angularDeflection ?? 0.5
        )
    }
}
