// Import — multi-format CAD import, write a manifest for OCCTSwiftViewport.
//
// Part of the OCCTMCP-driver I/O batch (OCCTSwiftScripts#19). Side effect:
// writes <emit-manifest>/<id>.brep per top-level body + <emit-manifest>/
// manifest.json so OCCTSwiftViewport's ScriptWatcher picks it up.
//
// V1 supports STEP / IGES / STL / OBJ — these are the OCCT-native formats.
// glTF / FBX / 3DS are intentionally deferred: they're not OCCT formats; if
// they end up wanted, the right place is an upstream OCCTSwift loader.
//
// `--preserve-assembly` (STEP only for v1) walks the XCAF document via
// Document.loadSTEP + AssemblyNode tree, writing one BREP per leaf node and
// populating the response's `assembly` tree with names / transforms / colors.
// Without it (or for non-STEP), the import is treated as a single body.
//
// `--heal-on-import` is accepted in v1 but currently a no-op with a warning;
// the actual heal verb arrives in OCCTSwiftScripts#21.
//
// Two input modes:
//   1. Flag form:
//      occtkit import <input> --emit-manifest <dir>
//          [--format auto|step|iges|stl|obj]
//          [--id-prefix <p>] [--preserve-assembly] [--heal-on-import]
//
//   2. JSON form:
//      { "inputPath": "...", "emitManifest": "...", "format": "...",
//        "idPrefix": "...", "preserveAssembly": <bool>, "healOnImport": <bool> }
//
// Stdout:
//   { "addedBodyIds": ["id_0", ...],
//     "assembly": { "rootId": "id_root", "components": [...] } | null,
//     "warnings": ["..."] }

import Foundation
import simd
import OCCTSwift
import ScriptHarness

enum ImportCommand: Subcommand {
    static let name = "import"
    static let summary = "Multi-format CAD import (STEP / IGES / STL / OBJ); writes a manifest"
    static let usage = """
        Usage:
          import <input> --emit-manifest <dir>
              [--format auto|step|iges|stl|obj]
              [--id-prefix <p>] [--preserve-assembly] [--heal-on-import]
          import <request.json>              (JSON request from file)
          import                             (JSON request from stdin)
        """

    private struct Request {
        var inputPath: String
        var emitManifest: String
        var format: Format
        var idPrefix: String
        var preserveAssembly: Bool
        var healOnImport: Bool
    }

    private enum Format: String, Decodable {
        case auto, step, iges, stl, obj
    }

    private struct JSONRequest: Decodable {
        let inputPath: String
        let emitManifest: String
        let format: Format?
        let idPrefix: String?
        let preserveAssembly: Bool?
        let healOnImport: Bool?
    }

    struct Response: Encodable {
        let addedBodyIds: [String]
        let assembly: Assembly?
        let warnings: [String]

        struct Assembly: Encodable {
            let rootId: String
            let components: [Component]
        }
        struct Component: Encodable {
            let id: String
            let name: String?
            let transform: [Float]      // 4x4 column-major
            let color: [Float]?
            let children: [Component]
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let format = try resolveFormat(format: req.format, path: req.inputPath)
        var warnings: [String] = []
        if req.healOnImport {
            warnings.append("--heal-on-import: accepted but not yet wired (waits on OCCTSwiftScripts#21)")
        }

        let emitDir = URL(fileURLWithPath: req.emitManifest)
        try? FileManager.default.createDirectory(at: emitDir, withIntermediateDirectories: true)

        var bodies: [BodyDescriptor] = []
        var addedIds: [String] = []
        var assembly: Response.Assembly? = nil

        if req.preserveAssembly && format == .step {
            let document = try loadDocumentSTEP(path: req.inputPath)
            assembly = try walkAssembly(
                document: document, emitDir: emitDir,
                idPrefix: req.idPrefix, bodies: &bodies, addedIds: &addedIds
            )
        } else {
            if req.preserveAssembly && format != .step {
                warnings.append("--preserve-assembly is STEP-only for v1; falling back to single-body import")
            }
            let shape = try loadSingleShape(format: format, path: req.inputPath)
            let id = "\(req.idPrefix)_0"
            let bodyURL = emitDir.appendingPathComponent("\(id).brep")
            try GraphIO.writeBREP(shape, to: bodyURL.path)
            bodies.append(BodyDescriptor(id: id, file: "\(id).brep"))
            addedIds.append(id)
        }

        let manifest = ScriptManifest(
            description: "Imported via `occtkit import` from \(req.inputPath)",
            bodies: bodies
        )
        let manifestURL = emitDir.appendingPathComponent("manifest.json")
        try LoadBrepCommand.writeManifest(manifest, to: manifestURL)

        try GraphIO.emitJSON(Response(
            addedBodyIds: addedIds,
            assembly: assembly,
            warnings: warnings
        ))
        return 0
    }

    // MARK: - Format dispatch

    private static func resolveFormat(format: Format, path: String) throws -> Format {
        if format != .auto { return format }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "step", "stp": return .step
        case "iges", "igs": return .iges
        case "stl":         return .stl
        case "obj":         return .obj
        default:
            throw ScriptError.message(
                "Cannot auto-detect format from extension '\(ext)'; pass --format explicitly")
        }
    }

    private static func loadSingleShape(format: Format, path: String) throws -> Shape {
        do {
            switch format {
            case .step:
                return try Shape.loadSTEP(fromPath: path, unitInMeters: 0.001)
            case .iges:
                return try Shape.loadIGES(fromPath: path)
            case .stl:
                return try Shape.loadSTL(fromPath: path)
            case .obj:
                return try Shape.loadOBJ(fromPath: path)
            case .auto:
                fatalError("auto should have been resolved to a concrete format")
            }
        } catch {
            throw ScriptError.message("Failed to load \(format.rawValue.uppercased()) at \(path): \(error.localizedDescription)")
        }
    }

    private static func loadDocumentSTEP(path: String) throws -> Document {
        let modes = STEPReaderModes()
        guard let doc = Document.loadSTEP(fromPath: path, modes: modes) else {
            throw ScriptError.message("Failed to load STEP document at \(path)")
        }
        return doc
    }

    // MARK: - Assembly walk

    private static func walkAssembly(
        document: Document,
        emitDir: URL,
        idPrefix: String,
        bodies: inout [BodyDescriptor],
        addedIds: inout [String]
    ) throws -> Response.Assembly {
        let roots = document.rootNodes
        var components: [Response.Component] = []
        var counter = 0

        for root in roots {
            let component = try walkNode(
                node: root, idPrefix: idPrefix, parentPathSegment: nil,
                emitDir: emitDir, bodies: &bodies, addedIds: &addedIds, counter: &counter
            )
            components.append(component)
        }

        let rootId = "\(idPrefix)_root"
        return Response.Assembly(rootId: rootId, components: components)
    }

    private static func walkNode(
        node: AssemblyNode,
        idPrefix: String,
        parentPathSegment: String?,
        emitDir: URL,
        bodies: inout [BodyDescriptor],
        addedIds: inout [String],
        counter: inout Int
    ) throws -> Response.Component {
        let id = "\(idPrefix)_\(counter)"
        counter += 1

        // Write geometry if this node has any (pure-assembly nodes have no shape).
        if let shape = node.shape {
            let bodyURL = emitDir.appendingPathComponent("\(id).brep")
            try GraphIO.writeBREP(shape, to: bodyURL.path)
            bodies.append(BodyDescriptor(
                id: id,
                file: "\(id).brep",
                format: "brep",
                name: node.name,
                color: node.color.map { [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)] }
            ))
            addedIds.append(id)
        }

        let xform = node.transform
        let transform = flatten4x4(xform)
        let color = node.color.map { [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)] }

        var children: [Response.Component] = []
        for child in node.children {
            children.append(try walkNode(
                node: child, idPrefix: idPrefix, parentPathSegment: id,
                emitDir: emitDir, bodies: &bodies, addedIds: &addedIds, counter: &counter
            ))
        }

        return Response.Component(
            id: id,
            name: node.name,
            transform: transform,
            color: color,
            children: children
        )
    }

    private static func flatten4x4(_ m: simd_float4x4) -> [Float] {
        let cols = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        return cols.flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--emit-manifest") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputPath = args.first, !inputPath.hasPrefix("-") else {
            throw ScriptError.message("Missing input path positional argument")
        }
        var emitManifest: String?
        var format: Format = .auto
        var idPrefix: String = "imported"
        var preserveAssembly = false
        var healOnImport = false
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--emit-manifest":
                i += 1; emitManifest = try valueOrThrow(args: args, i: i, flag: "--emit-manifest")
            case "--format":
                i += 1
                let v = try valueOrThrow(args: args, i: i, flag: "--format")
                guard let f = Format(rawValue: v) else {
                    throw ScriptError.message("--format must be auto|step|iges|stl|obj (got \(v))")
                }
                format = f
            case "--id-prefix":
                i += 1; idPrefix = try valueOrThrow(args: args, i: i, flag: "--id-prefix")
            case "--preserve-assembly":
                preserveAssembly = true
            case "--heal-on-import":
                healOnImport = true
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        guard let emitManifest else { throw ScriptError.message("--emit-manifest is required") }
        return Request(inputPath: inputPath, emitManifest: emitManifest, format: format,
                       idPrefix: idPrefix, preserveAssembly: preserveAssembly,
                       healOnImport: healOnImport)
    }

    private static func valueOrThrow(args: [String], i: Int, flag: String) throws -> String {
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
            inputPath: raw.inputPath,
            emitManifest: raw.emitManifest,
            format: raw.format ?? .auto,
            idPrefix: raw.idPrefix ?? "imported",
            preserveAssembly: raw.preserveAssembly ?? false,
            healOnImport: raw.healOnImport ?? false
        )
    }
}
