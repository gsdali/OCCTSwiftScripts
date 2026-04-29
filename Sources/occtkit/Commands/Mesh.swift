// Mesh — generate a triangle mesh from a BREP via BRepMesh_IncrementalMesh.
//
// Part of the OCCTMCP-driver mesh batch (OCCTSwiftScripts#22). Pure read.
// Returns triangle data inline up to a 100K-triangle threshold; above that
// (or when --output is supplied) writes the mesh to disk as STL or OBJ
// (per --output's extension) and sets `geometry` to null.
//
// Quality metrics computed:
//   - minAspectRatio / meanAspectRatio: longest-edge / shortest-edge per
//     triangle; >=1 by definition; lower is better quality.
//   - degenerateTriangles: triangles with a near-zero shortest edge
//     (collinear or repeated vertices).
//   - nonManifoldEdges: undirected edges shared by != 2 triangles.
//
// `simplify-mesh` (the second half of #22) is deferred — mesh decimation /
// QEM was filed against OCCTSwift core as OCCTSwift#92 but closed as
// out-of-scope; mesh-domain algorithms (decimation, smoothing, repair,
// remeshing) now live in a sibling repo `OCCTSwiftMesh` that vendors
// meshoptimizer (BSD-2-Clause). The v0.1.0 implementation is tracked at
// gsdali/OCCTSwiftMesh#1 — once it ships, this verb's sibling
// `simplify-mesh` adds OCCTSwiftMesh as a SPM dep and wraps
// Mesh.simplified(_:) per the API spec preserved in
// OCCTSwiftMesh's docs/INITIAL_IMPLEMENTATION.md.
//
// Two input modes:
//   1. Flag form:
//      occtkit mesh <input.brep>
//          [--linear-deflection d] [--angular-deflection d]
//          [--parallel] [--output <path>]
//          [--no-return-geometry]
//
//   2. JSON form:
//      { "inputBrep": "...", "linearDeflection": d, "angularDeflection": d,
//        "parallel": <bool>, "outputPath": "...", "returnGeometry": <bool> }

import Foundation
import simd
import OCCTSwift
import ScriptHarness

enum MeshCommand: Subcommand {
    static let name = "mesh"
    static let summary = "Generate a triangle mesh from a BREP; report counts + quality metrics"
    static let usage = """
        Usage:
          mesh <input.brep>
              [--linear-deflection d] [--angular-deflection d]
              [--parallel] [--output <path.stl|.obj>]
              [--no-return-geometry]
          mesh <request.json>
          mesh                              (JSON request from stdin)
        """

    private struct Request {
        var inputBrep: String
        var linearDeflection: Double
        var angularDeflection: Double
        var parallel: Bool
        var outputPath: String?
        var returnGeometry: Bool
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let linearDeflection: Double?
        let angularDeflection: Double?
        let parallel: Bool?
        let outputPath: String?
        let returnGeometry: Bool?
    }

    struct Response: Encodable {
        let triangleCount: Int
        let vertexCount: Int
        let quality: Quality
        let geometry: Geometry?
        let outputPath: String?

        struct Quality: Encodable {
            let minAspectRatio: Double
            let meanAspectRatio: Double
            let degenerateTriangles: Int
            let nonManifoldEdges: Int
        }
        struct Geometry: Encodable {
            let vertices: [Float]   // [x0,y0,z0, x1,y1,z1, ...]
            let indices: [UInt32]   // [i0,i1,i2, ...]
        }
    }

    private static let inlineTriangleThreshold = 100_000

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let shape = try GraphIO.loadBREP(at: req.inputBrep)

        var params = MeshParameters.default
        params.deflection = req.linearDeflection
        params.angle = req.angularDeflection
        params.inParallel = req.parallel
        guard let mesh = shape.mesh(parameters: params) else {
            throw ScriptError.message("Mesh generation failed (BRepMesh_IncrementalMesh returned nil)")
        }

        let triangleCount = mesh.triangleCount
        let vertexCount = mesh.vertexCount
        let quality = computeQuality(mesh: mesh)

        // Geometry: inline by default unless above threshold or --output supplied.
        let writeToFile = req.outputPath != nil || triangleCount > Self.inlineTriangleThreshold
        var outputPathOut: String? = nil
        var geometry: Response.Geometry? = nil

        if writeToFile {
            let path: String = {
                if let p = req.outputPath { return p }
                // Caller didn't supply --output but triangle count is too large for
                // inline transport; default to a sibling .obj next to the input.
                let base = (req.inputBrep as NSString).deletingPathExtension
                return base + ".mesh.obj"
            }()
            try writeMesh(shape: shape, deflection: req.linearDeflection, path: path)
            outputPathOut = path
        } else if req.returnGeometry {
            geometry = Response.Geometry(
                vertices: mesh.vertexData,
                indices: mesh.indices
            )
        }

        try GraphIO.emitJSON(Response(
            triangleCount: triangleCount,
            vertexCount: vertexCount,
            quality: quality,
            geometry: geometry,
            outputPath: outputPathOut
        ))
        return 0
    }

    private static func writeMesh(shape: Shape, deflection: Double, path: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "stl": try Exporter.writeSTL(shape: shape, to: url, deflection: deflection)
            case "obj": try Exporter.writeOBJ(shape: shape, to: url, deflection: deflection)
            default:
                throw ScriptError.message(
                    "Unsupported --output extension '\(ext)'; use .stl or .obj")
            }
        } catch {
            throw ScriptError.message("Failed to write mesh to \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - Quality metrics

    private static func computeQuality(mesh: Mesh) -> Response.Quality {
        let verts = mesh.vertices
        let idxs = mesh.indices
        var minAspect: Double = .infinity
        var sumAspect: Double = 0
        var validTris = 0
        var degenerate = 0

        // Count edges shared by triangles for non-manifold detection.
        var edgeCounts: [UInt64: Int] = [:]

        let triCount = idxs.count / 3
        for t in 0..<triCount {
            let i0 = idxs[t * 3 + 0]
            let i1 = idxs[t * 3 + 1]
            let i2 = idxs[t * 3 + 2]
            guard Int(i0) < verts.count, Int(i1) < verts.count, Int(i2) < verts.count else { continue }
            let a = verts[Int(i0)], b = verts[Int(i1)], c = verts[Int(i2)]
            let e0 = simd_length(b - a)
            let e1 = simd_length(c - b)
            let e2 = simd_length(a - c)
            let edges = [e0, e1, e2]
            let mn = edges.min() ?? 0
            let mx = edges.max() ?? 0
            if mn < 1e-9 {
                degenerate += 1
            } else {
                let aspect = Double(mx / mn)
                minAspect = min(minAspect, aspect)
                sumAspect += aspect
                validTris += 1
            }
            // Count manifold edges via canonical vertex-pair keys (low<<32 | high).
            for (a, b) in [(i0, i1), (i1, i2), (i2, i0)] {
                let lo = UInt64(min(a, b))
                let hi = UInt64(max(a, b))
                let key = (lo << 32) | hi
                edgeCounts[key, default: 0] += 1
            }
        }

        let nonManifold = edgeCounts.values.filter { $0 != 2 }.count
        return Response.Quality(
            minAspectRatio: validTris > 0 ? minAspect : 1.0,
            meanAspectRatio: validTris > 0 ? sumAspect / Double(validTris) : 1.0,
            degenerateTriangles: degenerate,
            nonManifoldEdges: nonManifold
        )
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--linear-deflection") && !args.contains("--angular-deflection") &&
            !args.contains("--output") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var linear = 0.1
        var angular = 0.5
        var parallel = false
        var output: String?
        var returnGeometry = true
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--linear-deflection":
                i += 1
                guard let d = Double(try v(args, i, "--linear-deflection")) else {
                    throw ScriptError.message("--linear-deflection expects a number")
                }
                linear = d
            case "--angular-deflection":
                i += 1
                guard let d = Double(try v(args, i, "--angular-deflection")) else {
                    throw ScriptError.message("--angular-deflection expects a number")
                }
                angular = d
            case "--parallel":               parallel = true
            case "--output":                 i += 1; output = try v(args, i, "--output")
            case "--no-return-geometry":     returnGeometry = false
            case "--return-geometry":        returnGeometry = true
            default: throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        return Request(
            inputBrep: inputBrep, linearDeflection: linear, angularDeflection: angular,
            parallel: parallel, outputPath: output, returnGeometry: returnGeometry
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
            inputBrep: raw.inputBrep,
            linearDeflection: raw.linearDeflection ?? 0.1,
            angularDeflection: raw.angularDeflection ?? 0.5,
            parallel: raw.parallel ?? false,
            outputPath: raw.outputPath,
            returnGeometry: raw.returnGeometry ?? true
        )
    }
}
