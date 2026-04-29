// SetMetadata — write document- or component-level XCAF metadata onto an
// OCAF document and save it.
//
// Part of the OCCTMCP-driver XCAF batch (OCCTSwiftScripts#23). Writes a
// new file (does not mutate the input in place).
//
// Output format: OCAF binary (.xbf). STEP write-back is not done in v1
// because OCCTSwift's STEP exporter signature on Document doesn't currently
// expose a one-call "write doc with custom XCAF named-data" path; .xbf
// preserves all attributes set here and is loadable by inspect-assembly
// for round-trip verification.
//
// Title-block keys at document scope are stored as TDataStd_NamedData
// strings on the document's main label, using the canonical key set:
//   title / drawnBy / material / weight / revision / partNumber
// Component scope writes name (TDataStd_Name) plus arbitrary
// `--custom-attr key=value` strings on the target labelId.
//
// Two input modes:
//   1. Flag form:
//      occtkit set-metadata <input> --output <out.xbf>
//          [--scope document|component] [--component-id <int64>]
//          [--title <s>] [--drawn-by <s>] [--material <s>]
//          [--weight <n>] [--revision <s>] [--part-number <s>]
//          [--custom-attr key=value]   (repeatable)
//
//   2. JSON form:
//      { "inputPath": "...", "outputPath": "...",
//        "scope": "document"|"component", "componentId": <int64>,
//        "title": ..., "drawnBy": ..., ... ,
//        "customAttrs": { "k": "v", ... } }

import Foundation
import OCCTSwift
import ScriptHarness

enum SetMetadataCommand: Subcommand {
    static let name = "set-metadata"
    static let summary = "Write document- or component-level XCAF metadata; save as .xbf"
    static let usage = """
        Usage:
          set-metadata <input> --output <out.xbf>
              [--scope document|component] [--component-id <int64>]
              [--title <s>] [--drawn-by <s>] [--material <s>]
              [--weight <n>] [--revision <s>] [--part-number <s>]
              [--custom-attr key=value]   (repeatable)
          set-metadata <request.json>
          set-metadata                    (JSON request from stdin)
        """

    private struct Request {
        var inputPath: String
        var outputPath: String
        var scope: Scope
        var componentId: Int64?
        var title: String?
        var drawnBy: String?
        var material: String?
        var weight: Double?
        var revision: String?
        var partNumber: String?
        var customAttrs: [String: String]
    }

    private enum Scope: String, Decodable {
        case document, component
    }

    private struct JSONRequest: Decodable {
        let inputPath: String
        let outputPath: String
        let scope: Scope?
        let componentId: Int64?
        let title: String?
        let drawnBy: String?
        let material: String?
        let weight: Double?
        let revision: String?
        let partNumber: String?
        let customAttrs: [String: String]?
    }

    struct Response: Encodable {
        let outputPath: String
        let applied: [String: String]
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)
        let document = try InspectAssemblyCommand.loadDocument(path: req.inputPath)
        // Touch rootNodes once before any node(at:) lookup. Without this,
        // OCCTSwift v0.156.x's Document.node(at:) returns nil for labelId 0
        // (the document main label) on a freshly-loaded STEP doc — the XCAF
        // shape tool isn't registered until rootNodes is accessed. Costs an
        // unused property read; should go away once OCCTSwift's node(at:)
        // does the eager registration itself.
        _ = document.rootNodes.count

        let target: AssemblyNode = try {
            switch req.scope {
            case .document:
                guard let main = document.mainLabel ?? document.rootNodes.first else {
                    throw ScriptError.message("Document has no main/root label to attach metadata to")
                }
                return main
            case .component:
                guard let id = req.componentId else {
                    throw ScriptError.message("--component-id is required when --scope=component")
                }
                guard let node = document.node(at: id) else {
                    throw ScriptError.message("No component with labelId \(id) in document")
                }
                return node
            }
        }()

        var applied: [String: String] = [:]
        if let v = req.title       { _ = target.setNamedString("title", value: v); applied["title"] = v }
        if let v = req.drawnBy     { _ = target.setNamedString("drawnBy", value: v); applied["drawnBy"] = v }
        if let v = req.material    { _ = target.setNamedString("material", value: v); applied["material"] = v }
        if let v = req.weight      { _ = target.setNamedReal("weight", value: v); applied["weight"] = "\(v)" }
        if let v = req.revision    { _ = target.setNamedString("revision", value: v); applied["revision"] = v }
        if let v = req.partNumber  { _ = target.setNamedString("partNumber", value: v); applied["partNumber"] = v }
        if req.scope == .component, let v = req.title { _ = target.setName(v) }  // also set TDataStd_Name on components

        for (k, v) in req.customAttrs {
            _ = target.setNamedString(k, value: v)
            applied[k] = v
        }

        let outURL = URL(fileURLWithPath: req.outputPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Register all OCAF storage drivers and set BinXCAF as the storage format
        // so the file actually persists XCAF NamedData attrs (loadSTEP defaults
        // to MDTV-XCAF which isn't registered out of the box).
        document.defineAllFormats()
        _ = document.setStorageFormat("BinXCAF")
        let status = document.saveOCAF(to: outURL.path)
        guard status == .ok else {
            throw ScriptError.message("Failed to save OCAF document at \(outURL.path): \(status)")
        }

        try GraphIO.emitJSON(Response(outputPath: outURL.path, applied: applied))
        return 0
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--output") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputPath = args.first, !inputPath.hasPrefix("-") else {
            throw ScriptError.message("Missing input positional argument")
        }
        var output: String?
        var scope: Scope = .document
        var componentId: Int64?
        var title: String?, drawnBy: String?, material: String?
        var revision: String?, partNumber: String?
        var weight: Double?
        var customAttrs: [String: String] = [:]
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--output":         i += 1; output = try v(args, i, "--output")
            case "--scope":
                i += 1
                let raw = try v(args, i, "--scope")
                guard let s = Scope(rawValue: raw) else {
                    throw ScriptError.message("--scope must be document|component (got \(raw))")
                }
                scope = s
            case "--component-id":
                i += 1
                let raw = try v(args, i, "--component-id")
                guard let n = Int64(raw) else {
                    throw ScriptError.message("--component-id expects an int64")
                }
                componentId = n
            case "--title":          i += 1; title = try v(args, i, "--title")
            case "--drawn-by":       i += 1; drawnBy = try v(args, i, "--drawn-by")
            case "--material":       i += 1; material = try v(args, i, "--material")
            case "--weight":
                i += 1
                guard let d = Double(try v(args, i, "--weight")) else {
                    throw ScriptError.message("--weight expects a number")
                }
                weight = d
            case "--revision":       i += 1; revision = try v(args, i, "--revision")
            case "--part-number":    i += 1; partNumber = try v(args, i, "--part-number")
            case "--custom-attr":
                i += 1
                let pair = try v(args, i, "--custom-attr")
                guard let eq = pair.firstIndex(of: "=") else {
                    throw ScriptError.message("--custom-attr expects key=value (got \(pair))")
                }
                customAttrs[String(pair[pair.startIndex..<eq])] = String(pair[pair.index(after: eq)...])
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        guard let outputPath = output else { throw ScriptError.message("--output is required") }
        return Request(
            inputPath: inputPath, outputPath: outputPath,
            scope: scope, componentId: componentId,
            title: title, drawnBy: drawnBy, material: material,
            weight: weight, revision: revision, partNumber: partNumber,
            customAttrs: customAttrs
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
            inputPath: raw.inputPath, outputPath: raw.outputPath,
            scope: raw.scope ?? .document, componentId: raw.componentId,
            title: raw.title, drawnBy: raw.drawnBy, material: raw.material,
            weight: raw.weight, revision: raw.revision, partNumber: raw.partNumber,
            customAttrs: raw.customAttrs ?? [:]
        )
    }
}

