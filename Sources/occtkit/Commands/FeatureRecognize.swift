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

        try GraphIO.emitJSON(Report(pockets: pockets, holes: holes))
        return 0
    }
}
