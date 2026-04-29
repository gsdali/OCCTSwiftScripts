// LoadBrep — load a .brep, write a single-body ScriptManifest, return body stats.
//
// Part of the OCCTMCP-driver I/O batch (OCCTSwiftScripts#19). Equivalent to a
// one-line script that does ctx.add(loadBREP(path), id: ...) + ctx.emit(...),
// but without compiling Swift. Output side effect: writes <emit-manifest>/
// <bodyId>.brep + <emit-manifest>/manifest.json so OCCTSwiftViewport's
// ScriptWatcher picks it up.
//
// Two input modes:
//   1. Flag form:
//      occtkit load-brep <input.brep> --emit-manifest <dir>
//          [--id <bodyId>] [--color <hex>]
//
//   2. JSON form:
//      { "inputBrep": "...", "emitManifest": "...",
//        "id": "...", "color": "#rrggbb" | "#rrggbbaa" }
//
// Stdout:
//   { "bodyId": "...", "isValid": <bool>, "shapeType": "<string>",
//     "faceCount": <int>, "edgeCount": <int>, "vertexCount": <int>,
//     "boundingBox": { "min": [...], "max": [...] } }

import Foundation
import OCCTSwift
import ScriptHarness

enum LoadBrepCommand: Subcommand {
    static let name = "load-brep"
    static let summary = "Load a BREP and emit a manifest entry for OCCTSwiftViewport"
    static let usage = """
        Usage:
          load-brep <input.brep> --emit-manifest <dir> [--id <bodyId>] [--color <hex>]
          load-brep <request.json>           (JSON request from file)
          load-brep                          (JSON request from stdin)
        """

    private struct Request {
        var inputBrep: String
        var emitManifest: String
        var id: String?
        var color: String?
    }

    private struct JSONRequest: Decodable {
        let inputBrep: String
        let emitManifest: String
        let id: String?
        let color: String?
    }

    struct Response: Encodable {
        let bodyId: String
        let isValid: Bool
        let shapeType: String
        let faceCount: Int
        let edgeCount: Int
        let vertexCount: Int
        let boundingBox: BoundingBox

        struct BoundingBox: Encodable {
            let min: [Double]
            let max: [Double]
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let shape = try GraphIO.loadBREP(at: req.inputBrep)
        let bodyId = req.id ?? defaultBodyId(from: req.inputBrep)

        let emitDir = URL(fileURLWithPath: req.emitManifest)
        try? FileManager.default.createDirectory(at: emitDir, withIntermediateDirectories: true)
        let bodyURL = emitDir.appendingPathComponent("\(bodyId).brep")
        try GraphIO.writeBREP(shape, to: bodyURL.path)

        let manifest = ScriptManifest(
            description: "Imported via load-brep",
            bodies: [BodyDescriptor(
                id: bodyId,
                file: "\(bodyId).brep",
                format: "brep",
                name: nil,
                color: req.color.flatMap { parseHexColor($0) }
            )]
        )
        let manifestURL = emitDir.appendingPathComponent("manifest.json")
        try writeManifest(manifest, to: manifestURL)

        try GraphIO.emitJSON(buildResponse(bodyId: bodyId, shape: shape))
        return 0
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--emit-manifest") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputBrep = args.first, !inputBrep.hasPrefix("-") else {
            throw ScriptError.message("Missing input BREP positional argument")
        }
        var emitManifest: String?
        var id: String?
        var color: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--emit-manifest":
                i += 1
                guard i < args.count else { throw ScriptError.message("--emit-manifest expects a value") }
                emitManifest = args[i]
            case "--id":
                i += 1
                guard i < args.count else { throw ScriptError.message("--id expects a value") }
                id = args[i]
            case "--color":
                i += 1
                guard i < args.count else { throw ScriptError.message("--color expects a value") }
                color = args[i]
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        guard let emitManifest else { throw ScriptError.message("--emit-manifest is required") }
        return Request(inputBrep: inputBrep, emitManifest: emitManifest, id: id, color: color)
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
        return Request(inputBrep: raw.inputBrep, emitManifest: raw.emitManifest,
                       id: raw.id, color: raw.color)
    }

    // MARK: - Helpers (shared with Import)

    static func defaultBodyId(from path: String) -> String {
        let stem = (path as NSString).lastPathComponent
        let dot = stem.firstIndex(of: ".") ?? stem.endIndex
        return String(stem[..<dot])
    }

    static func parseHexColor(_ s: String) -> [Float]? {
        let raw = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard raw.count == 6 || raw.count == 8 else { return nil }
        var bytes: [Float] = []
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let next = raw.index(idx, offsetBy: 2)
            guard let v = UInt8(raw[idx..<next], radix: 16) else { return nil }
            bytes.append(Float(v) / 255.0)
            idx = next
        }
        if bytes.count == 3 { bytes.append(1.0) }
        return bytes
    }

    static func writeManifest(_ manifest: ScriptManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: url)
        } catch {
            throw ScriptError.message("Failed to write manifest: \(error.localizedDescription)")
        }
    }

    static func buildResponse(bodyId: String, shape: Shape) -> Response {
        let bb = shape.bounds
        return Response(
            bodyId: bodyId,
            isValid: shape.isValid,
            shapeType: shape.shapeType.toLowercaseString(),
            faceCount: shape.faces().count,
            edgeCount: shape.edges().count,
            vertexCount: shape.vertices().count,
            boundingBox: .init(
                min: [bb.min.x, bb.min.y, bb.min.z],
                max: [bb.max.x, bb.max.y, bb.max.z]
            )
        )
    }
}

extension ShapeType {
    func toLowercaseString() -> String {
        switch self {
        case .compound: return "compound"
        case .compSolid: return "compSolid"
        case .solid: return "solid"
        case .shell: return "shell"
        case .face: return "face"
        case .wire: return "wire"
        case .edge: return "edge"
        case .vertex: return "vertex"
        case .unknown: return "unknown"
        }
    }
}
