// InspectAssembly — walk an XCAF document's assembly tree and report
// hierarchy + per-component metadata.
//
// Part of the OCCTMCP-driver XCAF batch (OCCTSwiftScripts#23). Pure read.
//
// Inputs (auto-detected by extension):
//   .step / .stp / .iges / .igs  -> Document.loadSTEP / loadIGES
//   .xbf                         -> Document.load(from:)  (OCAF binary)
//   .brep                        -> degenerate single-node response
//                                   (BREPs carry no XCAF metadata)
//
// Stable label IDs use OCCTSwift's `int64 labelId` which round-trips into
// `set-metadata --component-id <id>` and other XCAF-aware verbs. The id
// shape is "label_<int64>".
//
// Two input modes:
//   1. Flag form:  occtkit inspect-assembly <input> [--depth N]
//   2. JSON form:  { "inputPath": "...", "depth": N }

import Foundation
import simd
import OCCTSwift
import ScriptHarness

enum InspectAssemblyCommand: Subcommand {
    static let name = "inspect-assembly"
    static let summary = "Walk an XCAF document's assembly tree; report names / colors / transforms"
    static let usage = """
        Usage:
          inspect-assembly <input> [--depth N]
          inspect-assembly <request.json>     (JSON request from file)
          inspect-assembly                    (JSON request from stdin)
        """

    private struct Request {
        var inputPath: String
        var depth: Int?  // nil = unlimited
    }

    private struct JSONRequest: Decodable {
        let inputPath: String
        let depth: Int?
    }

    struct Response: Encodable {
        let root: Node?
        let totalComponents: Int
        let totalInstances: Int
        let totalReferences: Int

        struct Node: Encodable {
            let id: String
            let name: String?
            let isAssembly: Bool
            let transform: [Float]
            let color: [Float]?
            let material: String?
            let layer: String?
            let children: [Node]
            let referredTo: ReferredTo?
        }
        struct ReferredTo: Encodable {
            let labelId: String
            let name: String?
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let req = try parseRequest(args: args)

        if (req.inputPath as NSString).pathExtension.lowercased() == "brep" {
            // BREP has no XCAF — emit a degenerate single-node response.
            let shape = try GraphIO.loadBREP(at: req.inputPath)
            let bb = shape.bounds
            _ = bb
            let node = Response.Node(
                id: "label_0",
                name: (req.inputPath as NSString).lastPathComponent,
                isAssembly: false,
                transform: identityFloat4x4(),
                color: nil, material: nil, layer: nil,
                children: [], referredTo: nil
            )
            try GraphIO.emitJSON(Response(
                root: node, totalComponents: 1, totalInstances: 0, totalReferences: 0
            ))
            return 0
        }

        let document = try loadDocument(path: req.inputPath)
        var components = 0, instances = 0, references = 0

        let roots = document.rootNodes
        let topLevelNode: Response.Node?
        switch roots.count {
        case 0:
            topLevelNode = nil
        case 1:
            topLevelNode = walk(node: roots[0], depthRemaining: req.depth,
                                components: &components, instances: &instances,
                                references: &references)
        default:
            // Synthetic root wrapping multiple top-level shapes.
            let children = roots.compactMap {
                walk(node: $0, depthRemaining: req.depth,
                     components: &components, instances: &instances,
                     references: &references)
            }
            topLevelNode = Response.Node(
                id: "label_0", name: nil, isAssembly: true,
                transform: identityFloat4x4(),
                color: nil, material: nil, layer: nil,
                children: children, referredTo: nil
            )
        }

        try GraphIO.emitJSON(Response(
            root: topLevelNode,
            totalComponents: components,
            totalInstances: instances,
            totalReferences: references
        ))
        return 0
    }

    private static func walk(
        node: AssemblyNode,
        depthRemaining: Int?,
        components: inout Int,
        instances: inout Int,
        references: inout Int
    ) -> Response.Node {
        components += 1
        if node.shape != nil { instances += 1 }
        if node.isReference { references += 1 }

        let referredTo: Response.ReferredTo? = {
            guard node.isReference, let ref = node.referredNode else { return nil }
            return Response.ReferredTo(
                labelId: "label_\(ref.labelId)",
                name: ref.name
            )
        }()

        let nextDepth: Int?
        if let d = depthRemaining {
            if d <= 0 { return makeNode(node, children: [], referredTo: referredTo) }
            nextDepth = d - 1
        } else {
            nextDepth = nil
        }

        var kids: [Response.Node] = []
        for child in node.children {
            kids.append(walk(node: child, depthRemaining: nextDepth,
                             components: &components, instances: &instances,
                             references: &references))
        }
        return makeNode(node, children: kids, referredTo: referredTo)
    }

    private static func makeNode(_ node: AssemblyNode,
                                  children: [Response.Node],
                                  referredTo: Response.ReferredTo?) -> Response.Node {
        let xform = flatten4x4(node.transform)
        let color: [Float]? = node.color.map {
            [Float($0.red), Float($0.green), Float($0.blue), Float($0.alpha)]
        }
        return Response.Node(
            id: "label_\(node.labelId)",
            name: node.name,
            isAssembly: node.isAssembly,
            transform: xform,
            color: color,
            material: nil,  // OCCTSwift exposes Material struct but not material name on the node
            layer: nil,
            children: children,
            referredTo: referredTo
        )
    }

    static func loadDocument(path: String) throws -> Document {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "step", "stp":
            guard let doc = Document.loadSTEP(fromPath: path, modes: STEPReaderModes()) else {
                throw ScriptError.message("Failed to load STEP at \(path)")
            }
            return doc
        case "xbf":
            let result = Document.loadOCAF(from: path)
            guard let doc = result.document, result.status == .ok else {
                throw ScriptError.message("Failed to load OCAF .xbf at \(path): \(result.status)")
            }
            return doc
        default:
            throw ScriptError.message(
                "Unsupported input extension '\(ext)'. Use .step / .stp / .xbf, or .brep for a degenerate single-node response.")
        }
    }

    static func flatten4x4(_ m: simd_float4x4) -> [Float] {
        let cols = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        return cols.flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func identityFloat4x4() -> [Float] {
        [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1]
    }

    // MARK: - Request parsing

    private static func parseRequest(args: [String]) throws -> Request {
        if let first = args.first, first.hasSuffix(".json"), !first.hasPrefix("-"),
           !args.contains("--depth") {
            return try decodeJSON(data: try readFile(first))
        }
        if args.isEmpty { return try decodeJSON(data: FileHandle.standardInput.readDataToEndOfFile()) }
        guard let inputPath = args.first, !inputPath.hasPrefix("-") else {
            throw ScriptError.message("Missing input positional argument")
        }
        var depth: Int?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--depth":
                i += 1
                guard i < args.count, let n = Int(args[i]) else {
                    throw ScriptError.message("--depth expects an integer")
                }
                depth = n
            default:
                throw ScriptError.message("Unknown flag: \(args[i])")
            }
            i += 1
        }
        return Request(inputPath: inputPath, depth: depth)
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
        return Request(inputPath: raw.inputPath, depth: raw.depth)
    }
}
