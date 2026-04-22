// GraphML — export a BREP shape's topology graph in an ML-friendly JSON shape:
// COO sparse adjacency + per-face UV-grid samples (positions/normals/curvatures)
// + per-edge curve samples. Intended for GNN / UV-Net / BRepNet pipelines.
//
// Usage: GraphML <shape.brep> [--uv-samples N] [--edge-samples N]
// Stdout: JSON

import Foundation
import OCCTSwift
import ScriptHarness

struct MLExport: Codable {
    let vertexPositions: [[Double]]
    let edgeBoundaryFlags: [Bool]
    let edgeManifoldFlags: [Bool]
    let faceAdjacentFaces: [[Int]]
    let faceToFace: COO
    let faceToEdge: COO
    let edgeToVertex: COO
    let faces: [Face]
    let edges: [Edge]
    let sampling: Sampling

    struct COO: Codable { let sources: [Int]; let targets: [Int] }
    struct Face: Codable {
        let index: Int
        let uSamples: Int
        let vSamples: Int
        let positions: [[Double]]
        let normals: [[Double]]
        let gaussianCurvatures: [Double]
        let meanCurvatures: [Double]
    }
    struct Edge: Codable { let index: Int; let samples: [[Double]] }
    struct Sampling: Codable { let uvSamples: Int; let edgeSamples: Int }
}

func parseInt(_ name: String, default def: Int, args: [String]) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    return Int(args[i + 1]) ?? def
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    let usage = "Usage: GraphML <shape.brep> [--uv-samples N] [--edge-samples N]"
    guard let shapePath = args.first(where: { !$0.hasPrefix("--") }) else {
        throw ScriptError.message(usage)
    }
    let uvSamples = parseInt("--uv-samples", default: 16, args: args)
    let edgeSamples = parseInt("--edge-samples", default: 32, args: args)

    let shape = try GraphIO.loadBREP(at: shapePath)
    let graph = try GraphIO.buildGraph(from: shape)
    let g = graph.exportForML()

    let faces: [MLExport.Face] = (0..<graph.faceCount).compactMap { i in
        guard let s = graph.sampleFaceUVGrid(faceIndex: i, uSamples: uvSamples, vSamples: uvSamples) else {
            return nil
        }
        return MLExport.Face(
            index: i,
            uSamples: s.uSamples,
            vSamples: s.vSamples,
            positions: s.positions.map { [$0.x, $0.y, $0.z] },
            normals: s.normals.map { [$0.x, $0.y, $0.z] },
            gaussianCurvatures: s.gaussianCurvatures,
            meanCurvatures: s.meanCurvatures
        )
    }
    let edges: [MLExport.Edge] = (0..<graph.edgeCount).map { i in
        let pts = graph.sampleEdgeCurve(edgeIndex: i, count: edgeSamples)
        return MLExport.Edge(index: i, samples: pts.map { [$0.x, $0.y, $0.z] })
    }

    let payload = MLExport(
        vertexPositions: g.vertexPositions,
        edgeBoundaryFlags: g.edgeBoundaryFlags,
        edgeManifoldFlags: g.edgeManifoldFlags,
        faceAdjacentFaces: g.faceAdjacentFaces,
        faceToFace: MLExport.COO(sources: g.faceToFace.sources, targets: g.faceToFace.targets),
        faceToEdge: MLExport.COO(sources: g.faceToEdge.sources, targets: g.faceToEdge.targets),
        edgeToVertex: MLExport.COO(sources: g.edgeToVertex.sources, targets: g.edgeToVertex.targets),
        faces: faces,
        edges: edges,
        sampling: MLExport.Sampling(uvSamples: uvSamples, edgeSamples: edgeSamples)
    )
    try GraphIO.emitJSON(payload)
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
