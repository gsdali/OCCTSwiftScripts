import Foundation
import OCCTSwift
import ScriptHarness

enum FeatureRecognizeCommand: Subcommand {
    static let name = "feature-recognize"
    static let summary = "Detect pockets and holes via AAG heuristics"
    static let usage = "Usage: feature-recognize <shape.brep>"

    struct Report: Codable {
        let pockets: [Pocket]
        let holes: [Hole]
        // Unified, OCCTMCP-friendly view (OCCTSwiftScripts#18). Each entry has a
        // `kind` discriminator and `topologyRefs` aligned with the
        // query-topology verb's `face[N]` / `edge[N]` ID scheme. Coexists with
        // the existing pockets/holes arrays so existing consumers keep working.
        let features: [Feature]

        struct Pocket: Codable {
            let floorFaceIndex: Int
            let wallFaceIndices: [Int]
            let zLevel: Double
            let depth: Double
            let isOpen: Bool
            let bounds: Bounds
        }

        struct Hole: Codable {
            let faceIndex: Int
            let radius: Double
            let depth: Double
        }

        struct Bounds: Codable {
            let min: [Double]
            let max: [Double]
        }

        struct Feature: Codable {
            let id: String
            let kind: String           // "pocket" | "hole"
            let confidence: Double     // 1.0 — AAG is rule-based, no probabilistic score
            let params: [String: Double]
            let topologyRefs: [String]
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let path = try GraphIO.argument(at: 0, in: args, usage: usage)
        let shape = try GraphIO.loadBREP(at: path)
        let aag = AAG(shape: shape)

        let pockets = aag.detectPockets().map { p in
            Report.Pocket(
                floorFaceIndex: p.floorFaceIndex,
                wallFaceIndices: p.wallFaceIndices,
                zLevel: p.zLevel,
                depth: p.depth,
                isOpen: p.isOpen,
                bounds: Report.Bounds(
                    min: [p.bounds.min.x, p.bounds.min.y, p.bounds.min.z],
                    max: [p.bounds.max.x, p.bounds.max.y, p.bounds.max.z]
                )
            )
        }
        let holes = aag.detectHoles().map { h in
            Report.Hole(faceIndex: h.faceIndex, radius: h.radius, depth: h.depth)
        }

        var features: [Report.Feature] = []
        for (i, p) in pockets.enumerated() {
            var refs = ["face[\(p.floorFaceIndex)]"]
            refs.append(contentsOf: p.wallFaceIndices.map { "face[\($0)]" })
            features.append(Report.Feature(
                id: "feat[\(features.count)]",
                kind: "pocket",
                confidence: 1.0,
                params: [
                    "zLevel": p.zLevel,
                    "depth": p.depth,
                    "isOpen": p.isOpen ? 1.0 : 0.0,
                    "pocketIndex": Double(i),
                ],
                topologyRefs: refs
            ))
        }
        for (i, h) in holes.enumerated() {
            features.append(Report.Feature(
                id: "feat[\(features.count)]",
                kind: "hole",
                confidence: 1.0,
                params: [
                    "radius": h.radius,
                    "depth": h.depth,
                    "holeIndex": Double(i),
                ],
                topologyRefs: ["face[\(h.faceIndex)]"]
            ))
        }

        try GraphIO.emitJSON(Report(pockets: pockets, holes: holes, features: features))
        return 0
    }
}
