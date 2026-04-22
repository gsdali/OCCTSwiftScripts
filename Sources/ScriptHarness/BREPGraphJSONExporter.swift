// BREPGraphJSONExporter.swift
// ScriptHarness
//
// Serializes a TopologyGraph to a JSON file following the BREPGraph v1 schema.

import Foundation
import OCCTSwift

/// Exports a `TopologyGraph` to a structured JSON file.
public enum BREPGraphJSONExporter {

    /// Export a topology graph to a JSON file.
    /// - Parameters:
    ///   - graph: The topology graph to export.
    ///   - url: Destination file URL.
    ///   - description: Optional description for the metadata.
    public static func export(_ graph: TopologyGraph, to url: URL, description: String? = nil) throws {
        let doc = buildDocument(graph, description: description)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: url)
    }

    // MARK: - Document Assembly

    static func buildDocument(_ g: TopologyGraph, description: String?) -> GraphDocument {
        let s = g.stats

        let statsBlock = StatsBlock(
            topology: TopologyStats(
                compounds: s.compounds,
                compSolids: g.compSolidCount,
                solids: s.solids,
                shells: s.shells,
                faces: s.faces,
                wires: s.wires,
                edges: s.edges,
                vertices: s.vertices,
                coedges: s.coedges,
                totalNodes: s.totalNodes
            ),
            geometry: GeometryStats(
                surfaces: s.surfaces,
                curves3D: s.curves3D,
                curves2D: s.curves2D
            ),
            active: ActiveStats(
                faces: g.activeFaceCount,
                edges: g.activeEdgeCount,
                vertices: g.activeVertexCount,
                surfaces: g.activeSurfaceCount,
                curves3D: g.activeCurve3DCount,
                curves2D: g.activeCurve2DCount
            )
        )

        let v = g.validate()
        let validation = ValidationBlock(isValid: v.isValid, errorCount: v.errorCount, warningCount: v.warningCount)

        let roots = g.rootNodes.map { RootNodeEntry(kind: nodeKindName($0.kind), index: $0.index) }

        let nodes = buildNodes(g)
        let refs = buildReferences(g)
        let adjacency = buildAdjacency(g)
        let assembly = buildAssembly(g)

        return GraphDocument(
            meta: MetaBlock(
                schemaVersion: "1.0.0",
                generator: "OCCTSwift/BREPGraph",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                description: description
            ),
            stats: statsBlock,
            validation: validation,
            roots: roots,
            nodes: nodes,
            references: refs,
            adjacency: adjacency,
            assembly: assembly
        )
    }

    // MARK: - Nodes

    static func buildNodes(_ g: TopologyGraph) -> NodesBlock {
        // Vertices
        var vertices: [VertexNode] = []
        for i in 0..<g.vertexCount {
            let pt = g.vertexPoint(i)
            let edgeList = g.edges(of: i)
            vertices.append(VertexNode(
                index: i,
                point: PointXYZ(x: pt.x, y: pt.y, z: pt.z),
                tolerance: g.vertexTolerance(i),
                edgeCount: edgeList.count,
                edges: edgeList,
                removed: g.isRemoved(nodeKind: .vertex, nodeIndex: i)
            ))
        }

        // Edges
        var edges: [EdgeNode] = []
        for i in 0..<g.edgeCount {
            let r = g.edgeRange(i)
            let faceList = g.faces(of: i)
            let wireList = g.edgeWires(i)
            let coedgeList = g.edgeCoEdges(i)
            let adjList = g.adjacentEdges(of: i)
            edges.append(EdgeNode(
                index: i,
                tolerance: g.edgeTolerance(i),
                degenerated: g.isEdgeDegenerated(i),
                closed: g.isEdgeClosed(i),
                hasCurve: g.edgeHasCurve(i),
                hasPolygon3D: g.edgeHasPolygon3D(i),
                sameParameter: g.isEdgeSameParameter(i),
                sameRange: g.isEdgeSameRange(i),
                maxContinuity: g.edgeMaxContinuity(i),
                range: RangeBlock(first: r.first, last: r.last),
                startVertex: g.edgeStartVertex(i),
                endVertex: g.edgeEndVertex(i),
                boundary: g.isBoundaryEdge(i),
                manifold: g.isManifoldEdge(i),
                faceCount: faceList.count,
                faces: faceList,
                wireCount: wireList.count,
                wires: wireList,
                coedges: coedgeList,
                adjacentEdges: adjList,
                removed: g.isRemoved(nodeKind: .edge, nodeIndex: i)
            ))
        }

        // Faces
        var faces: [FaceNode] = []
        for i in 0..<g.faceCount {
            let adjFaces = g.adjacentFaces(of: i)
            let sdFaces = g.sameDomainFaces(of: i)
            let shells = g.faceShells(i)
            faces.append(FaceNode(
                index: i,
                tolerance: g.faceTolerance(i),
                hasSurface: g.faceHasSurface(i),
                hasTriangulation: g.faceHasTriangulation(i),
                naturalRestriction: g.isFaceNaturalRestriction(i),
                wireCount: g.faceWireCount(i),
                outerWire: g.outerWire(of: i),
                vertexRefCount: g.faceVertexRefCount(i),
                shellCount: shells.count,
                shells: shells,
                compoundCount: g.faceCompoundCount(i),
                adjacentFaces: adjFaces,
                sameDomainFaces: sdFaces,
                removed: g.isRemoved(nodeKind: .face, nodeIndex: i)
            ))
        }

        // Wires
        var wires: [WireNode] = []
        for i in 0..<g.wireCount {
            let wireFaceList = g.wireFaces(i)
            wires.append(WireNode(
                index: i,
                closed: g.isWireClosed(i),
                coedgeCount: g.wireCoEdgeCount(i),
                faceCount: wireFaceList.count,
                faces: wireFaceList,
                removed: g.isRemoved(nodeKind: .wire, nodeIndex: i)
            ))
        }

        // CoEdges
        var coedges: [CoEdgeNode] = []
        for i in 0..<g.coedgeCount {
            let r = g.coedgeRange(i)
            coedges.append(CoEdgeNode(
                index: i,
                edge: g.coedgeEdge(i),
                face: g.coedgeFace(i),
                seamPair: g.coedgeSeamPair(i),
                hasPCurve: g.coedgeHasPCurve(i),
                range: RangeBlock(first: r.first, last: r.last),
                removed: g.isRemoved(nodeKind: .coedge, nodeIndex: i)
            ))
        }

        // Shells
        var shells: [ShellNode] = []
        for i in 0..<g.shellCount {
            let solidList = g.shellSolids(i)
            shells.append(ShellNode(
                index: i,
                closed: g.isShellClosed(i),
                solidCount: solidList.count,
                solids: solidList,
                compoundCount: g.shellCompoundCount(i),
                removed: g.isRemoved(nodeKind: .shell, nodeIndex: i)
            ))
        }

        // Solids
        var solids: [SolidNode] = []
        for i in 0..<g.solidCount {
            solids.append(SolidNode(
                index: i,
                compSolidCount: g.solidCompSolidCount(i),
                compoundCount: g.solidCompoundCount(i),
                removed: g.isRemoved(nodeKind: .solid, nodeIndex: i)
            ))
        }

        // Compounds
        var compounds: [CompoundNode] = []
        for i in 0..<g.compoundCount {
            compounds.append(CompoundNode(
                index: i,
                childCount: g.compoundChildCount(i),
                parentCount: g.compoundParentCount(i),
                removed: g.isRemoved(nodeKind: .compound, nodeIndex: i)
            ))
        }

        // CompSolids
        var compSolids: [CompSolidNode] = []
        for i in 0..<g.compSolidCount {
            compSolids.append(CompSolidNode(
                index: i,
                solidCount: g.compSolidSolidCount(i),
                compoundCount: g.compSolidCompoundCount(i),
                removed: g.isRemoved(nodeKind: .compSolid, nodeIndex: i)
            ))
        }

        return NodesBlock(
            vertices: vertices,
            edges: edges,
            faces: faces,
            wires: wires,
            coedges: coedges,
            shells: shells,
            solids: solids,
            compounds: compounds,
            compSolids: compSolids
        )
    }

    // MARK: - References

    static func buildReferences(_ g: TopologyGraph) -> ReferencesBlock {
        func collectRefs(_ refKind: TopologyGraph.RefKind, count: Int) -> [RefEntry] {
            var entries: [RefEntry] = []
            for i in 0..<count {
                guard let childKind = g.refChildNodeKind(refKind, refIndex: i) else { continue }
                entries.append(RefEntry(
                    index: i,
                    childKind: nodeKindName(childKind),
                    childIndex: g.refChildNodeIndex(refKind, refIndex: i),
                    orientation: g.refOrientation(refKind, refIndex: i),
                    removed: g.isRefRemoved(refKind, refIndex: i)
                ))
            }
            return entries
        }

        return ReferencesBlock(
            shell: collectRefs(.shell, count: g.shellRefCount),
            face: collectRefs(.face, count: g.faceRefCount),
            wire: collectRefs(.wire, count: g.wireRefCount),
            coedge: collectRefs(.coedge, count: g.coedgeRefCount),
            vertex: collectRefs(.vertex, count: g.vertexRefCount),
            solid: collectRefs(.solid, count: g.solidRefCount),
            child: collectRefs(.child, count: g.childRefCount),
            occurrence: collectRefs(.occurrence, count: g.occurrenceRefCount)
        )
    }

    // MARK: - Adjacency (COO sparse)

    static func buildAdjacency(_ g: TopologyGraph) -> AdjacencyBlock {
        var f2fSrc: [Int] = [], f2fTgt: [Int] = []
        var f2eSrc: [Int] = [], f2eTgt: [Int] = []
        var e2vSrc: [Int] = [], e2vTgt: [Int] = []

        for i in 0..<g.faceCount {
            for adj in g.adjacentFaces(of: i) {
                f2fSrc.append(i); f2fTgt.append(adj)
            }
        }

        for i in 0..<g.edgeCount {
            for f in g.faces(of: i) {
                f2eSrc.append(f); f2eTgt.append(i)
            }
            if let sv = g.edgeStartVertex(i) { e2vSrc.append(i); e2vTgt.append(sv) }
            if let ev = g.edgeEndVertex(i) { e2vSrc.append(i); e2vTgt.append(ev) }
        }

        return AdjacencyBlock(
            faceToFace: COOSparse(sources: f2fSrc, targets: f2fTgt),
            faceToEdge: COOSparse(sources: f2eSrc, targets: f2eTgt),
            edgeToVertex: COOSparse(sources: e2vSrc, targets: e2vTgt)
        )
    }

    // MARK: - Assembly

    static func buildAssembly(_ g: TopologyGraph) -> AssemblyBlock {
        var products: [ProductEntry] = []
        for i in 0..<g.productCount {
            let root = g.productShapeRoot(i)
            products.append(ProductEntry(
                index: i,
                isAssembly: g.productIsAssembly(i),
                isPart: g.productIsPart(i),
                componentCount: g.productComponentCount(i),
                shapeRootKind: root.map { nodeKindName($0.kind) },
                shapeRootIndex: root?.index
            ))
        }

        var occurrences: [OccurrenceEntry] = []
        for i in 0..<g.occurrenceCount {
            occurrences.append(OccurrenceEntry(
                index: i,
                productIndex: g.occurrenceProduct(i),
                parentProductIndex: g.occurrenceParentProduct(i),
                parentOccurrenceIndex: g.occurrenceParentOccurrence(i)
            ))
        }

        return AssemblyBlock(
            products: products,
            occurrences: occurrences,
            rootProducts: g.rootProductIndices
        )
    }

    // MARK: - Helpers

    static func nodeKindName(_ kind: TopologyGraph.NodeKind) -> String {
        switch kind {
        case .solid: return "solid"
        case .shell: return "shell"
        case .face: return "face"
        case .wire: return "wire"
        case .edge: return "edge"
        case .vertex: return "vertex"
        case .compound: return "compound"
        case .compSolid: return "compSolid"
        case .coedge: return "coedge"
        }
    }
}

// MARK: - Codable Types

struct GraphDocument: Codable {
    let meta: MetaBlock
    let stats: StatsBlock
    let validation: ValidationBlock
    let roots: [RootNodeEntry]
    let nodes: NodesBlock
    let references: ReferencesBlock
    let adjacency: AdjacencyBlock
    let assembly: AssemblyBlock
}

struct MetaBlock: Codable {
    let schemaVersion: String
    let generator: String
    let timestamp: String
    let description: String?
}

struct StatsBlock: Codable {
    let topology: TopologyStats
    let geometry: GeometryStats
    let active: ActiveStats
}

struct TopologyStats: Codable {
    let compounds, compSolids, solids, shells, faces, wires, edges, vertices, coedges, totalNodes: Int
}

struct GeometryStats: Codable {
    let surfaces, curves3D, curves2D: Int
}

struct ActiveStats: Codable {
    let faces, edges, vertices, surfaces, curves3D, curves2D: Int
}

struct ValidationBlock: Codable {
    let isValid: Bool
    let errorCount, warningCount: Int
}

struct RootNodeEntry: Codable {
    let kind: String
    let index: Int
}

struct NodesBlock: Codable {
    let vertices: [VertexNode]
    let edges: [EdgeNode]
    let faces: [FaceNode]
    let wires: [WireNode]
    let coedges: [CoEdgeNode]
    let shells: [ShellNode]
    let solids: [SolidNode]
    let compounds: [CompoundNode]
    let compSolids: [CompSolidNode]
}

struct VertexNode: Codable {
    let index: Int
    let point: PointXYZ
    let tolerance: Double
    let edgeCount: Int
    let edges: [Int]
    let removed: Bool
}

struct PointXYZ: Codable {
    let x, y, z: Double
}

struct EdgeNode: Codable {
    let index: Int
    let tolerance: Double
    let degenerated, closed, hasCurve, hasPolygon3D, sameParameter, sameRange: Bool
    let maxContinuity: Int
    let range: RangeBlock
    let startVertex, endVertex: Int?
    let boundary, manifold: Bool
    let faceCount: Int
    let faces: [Int]
    let wireCount: Int
    let wires: [Int]
    let coedges: [Int]
    let adjacentEdges: [Int]
    let removed: Bool
}

struct RangeBlock: Codable {
    let first, last: Double
}

struct FaceNode: Codable {
    let index: Int
    let tolerance: Double
    let hasSurface, hasTriangulation, naturalRestriction: Bool
    let wireCount: Int
    let outerWire: Int
    let vertexRefCount, shellCount: Int
    let shells: [Int]
    let compoundCount: Int
    let adjacentFaces: [Int]
    let sameDomainFaces: [Int]
    let removed: Bool
}

struct WireNode: Codable {
    let index: Int
    let closed: Bool
    let coedgeCount, faceCount: Int
    let faces: [Int]
    let removed: Bool
}

struct CoEdgeNode: Codable {
    let index: Int
    let edge, face: Int
    let seamPair: Int?
    let hasPCurve: Bool
    let range: RangeBlock
    let removed: Bool
}

struct ShellNode: Codable {
    let index: Int
    let closed: Bool
    let solidCount: Int
    let solids: [Int]
    let compoundCount: Int
    let removed: Bool
}

struct SolidNode: Codable {
    let index: Int
    let compSolidCount, compoundCount: Int
    let removed: Bool
}

struct CompoundNode: Codable {
    let index: Int
    let childCount, parentCount: Int
    let removed: Bool
}

struct CompSolidNode: Codable {
    let index: Int
    let solidCount, compoundCount: Int
    let removed: Bool
}

struct ReferencesBlock: Codable {
    let shell, face, wire, coedge, vertex, solid, child, occurrence: [RefEntry]
}

struct RefEntry: Codable {
    let index: Int
    let childKind: String
    let childIndex: Int
    let orientation: Int
    let removed: Bool
}

struct AdjacencyBlock: Codable {
    let faceToFace, faceToEdge, edgeToVertex: COOSparse
}

struct COOSparse: Codable {
    let sources, targets: [Int]
}

struct AssemblyBlock: Codable {
    let products: [ProductEntry]
    let occurrences: [OccurrenceEntry]
    let rootProducts: [Int]
}

struct ProductEntry: Codable {
    let index: Int
    let isAssembly, isPart: Bool
    let componentCount: Int
    let shapeRootKind: String?
    let shapeRootIndex: Int?
}

struct OccurrenceEntry: Codable {
    let index: Int
    let productIndex, parentProductIndex: Int
    let parentOccurrenceIndex: Int?
}
