// RenderPreview — render a PNG of one or more BREPs at a named camera angle.
//
// Part of the OCCTMCP-driver verb batch (OCCTSwiftScripts#24). Wraps
// OCCTSwiftViewport's OffscreenRenderer (closing OCCTSwiftViewport#18).
//
// Pipeline:
//   1. Load each input BREP.
//   2. Convert each Shape to a ViewportBody via
//      CADFileLoader.shapeToBodyAndMetadata. This handles the
//      BRepMesh_IncrementalMesh -> interleaved-vertex transformation that
//      the renderer expects.
//   3. Compute the union bounding box of all bodies.
//   4. Build a CameraState from --camera (iso/front/back/top/bottom/left/right)
//      or explicit --camera-position/--camera-target/--camera-up.
//   5. Hand off to OffscreenRenderer.renderToPNG(bodies:url:options:).
//
// Two input modes:
//   1. Flag form:
//      occtkit render-preview <brep>... --output <png-path>
//          [--camera iso|front|back|top|bottom|left|right]
//          [--camera-position x,y,z --camera-target x,y,z [--camera-up x,y,z]]
//          [--width N] [--height N]
//          [--display-mode shaded|wireframe|shaded-with-edges|flat|xray|rendered]
//          [--background light|dark|transparent|#hex]
//
//   2. JSON form:
//      { "inputs": ["a.brep", ...] | "manifest": "...",
//        "outputPath": "...", "camera": "iso", ..., "width": ..., ... }
//
// Stdout: { "outputPath": "...", "width": N, "height": N, "mimeType": "image/png" }
//
// OCCTSwiftViewport pin: `from: "0.50.0"` (the first release containing
// OffscreenRenderer, cut after OCCTSwiftViewport#20).

import Foundation
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools
import ScriptHarness

enum RenderPreviewCommand: Subcommand {
    static let name = "render-preview"
    static let summary = "Render a PNG preview of one or more BREPs (headless)"
    static let usage = """
        Usage:
          render-preview <brep>... --output <png>
              [--camera iso|front|back|top|bottom|left|right]
              [--camera-position x,y,z --camera-target x,y,z [--camera-up x,y,z]]
              [--width N] [--height N]
              [--display-mode shaded|wireframe|shaded-with-edges|flat|xray|rendered]
              [--background light|dark|transparent|#hex]
          render-preview <request.json>
          render-preview                    (JSON request from stdin)
        """

    private struct Request {
        var inputs: [String]
        var outputPath: String
        var camera: CameraSpec
        var width: Int
        var height: Int
        var displayMode: DisplayMode
        var background: SIMD4<Float>
    }

    private enum CameraSpec {
        case preset(Preset)
        case explicit(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>)

        enum Preset: String { case iso, front, back, top, bottom, left, right }
    }

    private struct JSONRequest: Decodable {
        let inputs: [String]
        let outputPath: String
        let camera: String?
        let cameraPosition: [Float]?
        let cameraTarget: [Float]?
        let cameraUp: [Float]?
        let width: Int?
        let height: Int?
        let displayMode: String?
        let background: String?
    }

    struct Response: Encodable {
        let outputPath: String
        let width: Int
        let height: Int
        let mimeType: String
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)

        // Load + convert.
        var bodies: [ViewportBody] = []
        var unionMin = SIMD3<Float>(repeating: .infinity)
        var unionMax = SIMD3<Float>(repeating: -.infinity)
        for (i, path) in req.inputs.enumerated() {
            let shape = try GraphIO.loadBREP(at: path)
            let id = (path as NSString).deletingPathExtension.split(separator: "/").last.map(String.init) ?? "body_\(i)"
            let (body, _) = OCCTSwiftTools.CADFileLoader.shapeToBodyAndMetadata(
                shape, id: id, color: SIMD4(0.7, 0.7, 0.75, 1.0)  // steel
            )
            guard let body else {
                throw ScriptError.message("Failed to convert '\(path)' to a renderable body")
            }
            bodies.append(body)
            let bb = shape.bounds
            unionMin = simd_min(unionMin, SIMD3(Float(bb.min.x), Float(bb.min.y), Float(bb.min.z)))
            unionMax = simd_max(unionMax, SIMD3(Float(bb.max.x), Float(bb.max.y), Float(bb.max.z)))
        }

        let center = (unionMin + unionMax) * 0.5
        let diagonal = simd_length(unionMax - unionMin)
        let cameraState = makeCameraState(spec: req.camera, center: center, diagonal: diagonal)

        // OffscreenRenderer is @MainActor-isolated. main.swift's dispatch() is
        // already @MainActor, so when this verb runs we're on the main actor —
        // but the Subcommand protocol's `run(args:)` requirement is
        // nonisolated, so we hop in via assumeIsolated to call the renderer.
        let outURL = URL(fileURLWithPath: req.outputPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MainActor.assumeIsolated {
            guard let renderer = OffscreenRenderer() else {
                throw ScriptError.message("Headless OffscreenRenderer unavailable (Metal device missing?)")
            }
            let options = OffscreenRenderOptions(
                width: req.width,
                height: req.height,
                cameraState: cameraState,
                displayMode: req.displayMode,
                backgroundColor: req.background
            )
            do {
                _ = try renderer.renderToPNG(bodies: bodies, url: outURL, options: options)
            } catch {
                throw ScriptError.message("Render failed: \(error.localizedDescription)")
            }
        }

        try GraphIO.emitJSON(Response(
            outputPath: outURL.path,
            width: req.width, height: req.height,
            mimeType: "image/png"
        ))
        return 0
    }

    // MARK: - Camera presets

    private static func makeCameraState(
        spec: CameraSpec,
        center: SIMD3<Float>,
        diagonal: Float
    ) -> CameraState {
        let safeDiag = max(diagonal, 1e-3)
        let distance = max(safeDiag * 1.5, 1.0)

        switch spec {
        case .preset(let preset):
            // Direction in world space the camera looks FROM (relative to target).
            let dir: SIMD3<Float>
            let up: SIMD3<Float>
            switch preset {
            case .iso:    dir = simd_normalize(SIMD3<Float>(1, -1, 1));  up = SIMD3(0, 0, 1)
            case .front:  dir = SIMD3<Float>(0, -1, 0);                  up = SIMD3(0, 0, 1)
            case .back:   dir = SIMD3<Float>(0, 1, 0);                   up = SIMD3(0, 0, 1)
            case .top:    dir = SIMD3<Float>(0, 0, 1);                   up = SIMD3(0, 1, 0)
            case .bottom: dir = SIMD3<Float>(0, 0, -1);                  up = SIMD3(0, 1, 0)
            case .left:   dir = SIMD3<Float>(-1, 0, 0);                  up = SIMD3(0, 0, 1)
            case .right:  dir = SIMD3<Float>(1, 0, 0);                   up = SIMD3(0, 0, 1)
            }
            let position = center + dir * distance
            return CameraState.lookAt(target: center, from: position, up: up)
        case .explicit(let position, let target, let up):
            return CameraState.lookAt(target: target, from: position, up: up)
        }
    }

    // MARK: - Background parse

    private static func parseBackground(_ s: String) -> SIMD4<Float> {
        switch s {
        case "light":       return SIMD4(0.92, 0.94, 0.97, 1.0)
        case "dark":        return SIMD4(0.10, 0.11, 0.13, 1.0)
        case "transparent": return SIMD4(0.0, 0.0, 0.0, 0.0)
        default:
            // Hex form
            let raw = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard raw.count == 6 || raw.count == 8 else { return SIMD4(0.92, 0.94, 0.97, 1.0) }
            var bytes: [Float] = []
            var idx = raw.startIndex
            while idx < raw.endIndex {
                let next = raw.index(idx, offsetBy: 2)
                guard let v = UInt8(raw[idx..<next], radix: 16) else { return SIMD4(0.92, 0.94, 0.97, 1.0) }
                bytes.append(Float(v) / 255.0)
                idx = next
            }
            if bytes.count == 3 { bytes.append(1.0) }
            return SIMD4(bytes[0], bytes[1], bytes[2], bytes[3])
        }
    }

    // MARK: - Display mode

    private static func parseDisplayMode(_ s: String) throws -> DisplayMode {
        switch s {
        case "shaded": return .shaded
        case "wireframe": return .wireframe
        case "shaded-with-edges", "shadedWithEdges": return .shadedWithEdges
        case "flat": return .flat
        case "xray", "x-ray": return .xray
        case "rendered": return .rendered
        default: throw ScriptError.message("--display-mode must be shaded|wireframe|shaded-with-edges|flat|xray|rendered (got \(s))")
        }
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--output") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }

        var inputs: [String] = []
        var output: String?
        var cameraPreset: CameraSpec.Preset = .iso
        var cameraPosition: SIMD3<Float>?
        var cameraTarget: SIMD3<Float>?
        var cameraUp: SIMD3<Float> = SIMD3(0, 0, 1)
        var width = 800
        var height = 600
        var displayMode: DisplayMode = .shaded
        var background = SIMD4<Float>(0.92, 0.94, 0.97, 1.0)

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--output":
                i += 1; output = try v(args, i, "--output")
            case "--camera":
                i += 1
                let s = try v(args, i, "--camera")
                guard let p = CameraSpec.Preset(rawValue: s) else {
                    throw ScriptError.message("--camera must be iso|front|back|top|bottom|left|right (got \(s))")
                }
                cameraPreset = p
            case "--camera-position":
                i += 1; cameraPosition = try parseFloat3(try v(args, i, "--camera-position"), name: a)
            case "--camera-target":
                i += 1; cameraTarget = try parseFloat3(try v(args, i, "--camera-target"), name: a)
            case "--camera-up":
                i += 1; cameraUp = try parseFloat3(try v(args, i, "--camera-up"), name: a)
            case "--width":
                i += 1
                guard let n = Int(try v(args, i, "--width")) else { throw ScriptError.message("--width expects an integer") }
                width = n
            case "--height":
                i += 1
                guard let n = Int(try v(args, i, "--height")) else { throw ScriptError.message("--height expects an integer") }
                height = n
            case "--display-mode":
                i += 1
                displayMode = try parseDisplayMode(try v(args, i, "--display-mode"))
            case "--background":
                i += 1
                background = parseBackground(try v(args, i, "--background"))
            default:
                if a.hasPrefix("-") { throw ScriptError.message("Unknown flag: \(a)") }
                inputs.append(a)
            }
            i += 1
        }

        guard !inputs.isEmpty else {
            throw ScriptError.message("At least one input BREP path is required")
        }
        guard let outputPath = output else { throw ScriptError.message("--output is required") }

        let camera: CameraSpec
        if let p = cameraPosition, let t = cameraTarget {
            camera = .explicit(position: p, target: t, up: cameraUp)
        } else {
            camera = .preset(cameraPreset)
        }

        return Request(
            inputs: inputs, outputPath: outputPath, camera: camera,
            width: width, height: height,
            displayMode: displayMode, background: background
        )
    }

    private static func v(_ args: [String], _ i: Int, _ flag: String) throws -> String {
        guard i < args.count else { throw ScriptError.message("\(flag) expects a value") }
        return args[i]
    }

    private static func parseFloat3(_ s: String, name: String) throws -> SIMD3<Float> {
        let v = s.split(separator: ",").compactMap { Float($0) }
        guard v.count == 3 else { throw ScriptError.message("\(name) expects x,y,z") }
        return SIMD3(v[0], v[1], v[2])
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
        var camera: CameraSpec = .preset(.iso)
        if let p = raw.cameraPosition, let t = raw.cameraTarget, p.count == 3, t.count == 3 {
            let up = (raw.cameraUp?.count == 3) ?
                SIMD3<Float>(raw.cameraUp![0], raw.cameraUp![1], raw.cameraUp![2]) :
                SIMD3<Float>(0, 0, 1)
            camera = .explicit(
                position: SIMD3(p[0], p[1], p[2]),
                target: SIMD3(t[0], t[1], t[2]),
                up: up
            )
        } else if let preset = raw.camera, let p = CameraSpec.Preset(rawValue: preset) {
            camera = .preset(p)
        }
        let displayMode: DisplayMode = try {
            guard let s = raw.displayMode else { return .shaded }
            return try parseDisplayMode(s)
        }()
        let background = parseBackground(raw.background ?? "light")
        return Request(
            inputs: raw.inputs, outputPath: raw.outputPath, camera: camera,
            width: raw.width ?? 800, height: raw.height ?? 600,
            displayMode: displayMode, background: background
        )
    }
}
