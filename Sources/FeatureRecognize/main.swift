// FeatureRecognize — detect pockets and holes in a BREP shape using
// OCCTSwift's Attributed Adjacency Graph (AAG) heuristics.
//
// Usage: FeatureRecognize <shape.brep>
// Stdout: JSON { pockets: [...], holes: [...] }

import Foundation
import OCCTSwift
import ScriptHarness

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

FileHandle.standardError.write(Data("DEPRECATED: 'FeatureRecognize' standalone target will be removed in a future release. Use 'occtkit feature-recognize' instead.\n".utf8))

let args = Array(CommandLine.arguments.dropFirst())
do {
    let path = try GraphIO.argument(at: 0, in: args, usage: "Usage: FeatureRecognize <shape.brep>")
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
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
