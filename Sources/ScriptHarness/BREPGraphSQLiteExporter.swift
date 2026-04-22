// BREPGraphSQLiteExporter.swift
// ScriptHarness
//
// Serializes a TopologyGraph to a SQLite database with per-kind property tables,
// references, precomputed adjacency, and built-in analysis views.

import Foundation
import OCCTSwift

#if canImport(SQLite3)
import SQLite3
#endif

/// Exports a `TopologyGraph` to a SQLite database.
public enum BREPGraphSQLiteExporter {

    /// Export a topology graph to a SQLite file.
    /// - Parameters:
    ///   - graph: The topology graph to export.
    ///   - url: Destination `.sqlite` file URL.
    ///   - description: Optional description stored in metadata.
    public static func export(_ graph: TopologyGraph, to url: URL, description: String? = nil) throws {
        // Remove existing file
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteExportError.cannotOpen(url.path)
        }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA journal_mode = WAL")
        try exec(db, "PRAGMA foreign_keys = ON")
        try exec(db, "BEGIN TRANSACTION")

        try createSchema(db)
        try insertMeta(db, graph: graph, description: description)
        try insertNodes(db, graph: graph)
        try insertReferences(db, graph: graph)
        try insertAdjacency(db, graph: graph)
        try insertAssembly(db, graph: graph)
        try createViews(db)

        try exec(db, "COMMIT")
    }

    // MARK: - Schema

    private static func createSchema(_ db: OpaquePointer) throws {
        let ddl = """
        CREATE TABLE meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE stats (
            category TEXT NOT NULL,
            key      TEXT NOT NULL,
            value    INTEGER NOT NULL,
            PRIMARY KEY (category, key)
        );

        CREATE TABLE validation (
            is_valid      INTEGER NOT NULL,
            error_count   INTEGER NOT NULL,
            warning_count INTEGER NOT NULL
        );

        CREATE TABLE root_nodes (
            kind INTEGER NOT NULL,
            idx  INTEGER NOT NULL,
            PRIMARY KEY (kind, idx)
        );

        CREATE TABLE nodes (
            kind     INTEGER NOT NULL,
            idx      INTEGER NOT NULL,
            removed  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (kind, idx)
        );
        CREATE INDEX idx_nodes_kind ON nodes(kind);

        CREATE TABLE vertex_props (
            idx        INTEGER PRIMARY KEY,
            x          REAL NOT NULL,
            y          REAL NOT NULL,
            z          REAL NOT NULL,
            tolerance  REAL NOT NULL,
            edge_count INTEGER NOT NULL
        );

        CREATE TABLE edge_props (
            idx              INTEGER PRIMARY KEY,
            tolerance        REAL    NOT NULL,
            degenerated      INTEGER NOT NULL,
            closed           INTEGER NOT NULL,
            has_curve        INTEGER NOT NULL,
            has_polygon_3d   INTEGER NOT NULL,
            same_parameter   INTEGER NOT NULL,
            same_range       INTEGER NOT NULL,
            max_continuity   INTEGER NOT NULL,
            range_first      REAL    NOT NULL,
            range_last       REAL    NOT NULL,
            start_vertex     INTEGER,
            end_vertex       INTEGER,
            is_boundary      INTEGER NOT NULL,
            is_manifold      INTEGER NOT NULL,
            face_count       INTEGER NOT NULL,
            wire_count       INTEGER NOT NULL,
            coedge_count     INTEGER NOT NULL
        );

        CREATE TABLE face_props (
            idx                 INTEGER PRIMARY KEY,
            tolerance           REAL    NOT NULL,
            has_surface         INTEGER NOT NULL,
            has_triangulation   INTEGER NOT NULL,
            natural_restriction INTEGER NOT NULL,
            wire_count          INTEGER NOT NULL,
            outer_wire          INTEGER,
            vertex_ref_count    INTEGER NOT NULL,
            shell_count         INTEGER NOT NULL,
            compound_count      INTEGER NOT NULL
        );

        CREATE TABLE wire_props (
            idx          INTEGER PRIMARY KEY,
            closed       INTEGER NOT NULL,
            coedge_count INTEGER NOT NULL,
            face_count   INTEGER NOT NULL
        );

        CREATE TABLE coedge_props (
            idx         INTEGER PRIMARY KEY,
            edge_idx    INTEGER NOT NULL,
            face_idx    INTEGER NOT NULL,
            seam_pair   INTEGER,
            has_pcurve  INTEGER NOT NULL,
            range_first REAL    NOT NULL,
            range_last  REAL    NOT NULL
        );

        CREATE TABLE shell_props (
            idx            INTEGER PRIMARY KEY,
            closed         INTEGER NOT NULL,
            solid_count    INTEGER NOT NULL,
            compound_count INTEGER NOT NULL
        );

        CREATE TABLE solid_props (
            idx               INTEGER PRIMARY KEY,
            comp_solid_count  INTEGER NOT NULL,
            compound_count    INTEGER NOT NULL
        );

        CREATE TABLE compound_props (
            idx           INTEGER PRIMARY KEY,
            child_count   INTEGER NOT NULL,
            parent_count  INTEGER NOT NULL
        );

        CREATE TABLE comp_solid_props (
            idx            INTEGER PRIMARY KEY,
            solid_count    INTEGER NOT NULL,
            compound_count INTEGER NOT NULL
        );

        CREATE TABLE refs (
            ref_kind       INTEGER NOT NULL,
            ref_idx        INTEGER NOT NULL,
            child_kind     INTEGER NOT NULL,
            child_idx      INTEGER NOT NULL,
            orientation    INTEGER NOT NULL DEFAULT 0,
            removed        INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (ref_kind, ref_idx)
        );
        CREATE INDEX idx_refs_child ON refs(child_kind, child_idx);

        CREATE TABLE face_adjacency (
            face_a INTEGER NOT NULL,
            face_b INTEGER NOT NULL,
            PRIMARY KEY (face_a, face_b)
        );
        CREATE INDEX idx_face_adj_b ON face_adjacency(face_b);

        CREATE TABLE shared_edges (
            face_a   INTEGER NOT NULL,
            face_b   INTEGER NOT NULL,
            edge_idx INTEGER NOT NULL,
            PRIMARY KEY (face_a, face_b, edge_idx)
        );

        CREATE TABLE edge_adjacency (
            edge_a INTEGER NOT NULL,
            edge_b INTEGER NOT NULL,
            PRIMARY KEY (edge_a, edge_b)
        );

        CREATE TABLE same_domain_faces (
            face_a INTEGER NOT NULL,
            face_b INTEGER NOT NULL,
            PRIMARY KEY (face_a, face_b)
        );

        CREATE TABLE face_edge_incidence (
            face_idx INTEGER NOT NULL,
            edge_idx INTEGER NOT NULL,
            PRIMARY KEY (face_idx, edge_idx)
        );
        CREATE INDEX idx_fei_edge ON face_edge_incidence(edge_idx);

        CREATE TABLE edge_vertex_incidence (
            edge_idx   INTEGER NOT NULL,
            vertex_idx INTEGER NOT NULL,
            role       TEXT NOT NULL,
            PRIMARY KEY (edge_idx, vertex_idx, role)
        );
        CREATE INDEX idx_evi_vertex ON edge_vertex_incidence(vertex_idx);

        CREATE TABLE vertex_edge_incidence (
            vertex_idx INTEGER NOT NULL,
            edge_idx   INTEGER NOT NULL,
            PRIMARY KEY (vertex_idx, edge_idx)
        );

        CREATE TABLE products (
            idx             INTEGER PRIMARY KEY,
            is_assembly     INTEGER NOT NULL,
            is_part         INTEGER NOT NULL,
            component_count INTEGER NOT NULL,
            shape_root_kind INTEGER,
            shape_root_idx  INTEGER
        );

        CREATE TABLE occurrences (
            idx                     INTEGER PRIMARY KEY,
            product_idx             INTEGER NOT NULL,
            parent_product_idx      INTEGER NOT NULL,
            parent_occurrence_idx   INTEGER
        );

        CREATE TABLE root_products (
            product_idx INTEGER PRIMARY KEY
        );
        """
        try exec(db, ddl)
    }

    // MARK: - Metadata

    private static func insertMeta(_ db: OpaquePointer, graph g: TopologyGraph, description: String?) throws {
        let metaInsert = "INSERT INTO meta (key, value) VALUES (?, ?)"
        try insert(db, metaInsert, "schema_version", "1.0.0")
        try insert(db, metaInsert, "generator", "OCCTSwift/BREPGraph")
        try insert(db, metaInsert, "timestamp", ISO8601DateFormatter().string(from: Date()))
        if let desc = description {
            try insert(db, metaInsert, "description", desc)
        }

        // Stats
        let s = g.stats
        let statInsert = "INSERT INTO stats (category, key, value) VALUES (?, ?, ?)"
        let topoStats: [(String, Int)] = [
            ("compounds", s.compounds), ("solids", s.solids), ("shells", s.shells),
            ("faces", s.faces), ("wires", s.wires), ("edges", s.edges),
            ("vertices", s.vertices), ("coedges", s.coedges), ("totalNodes", s.totalNodes),
            ("compSolids", g.compSolidCount)
        ]
        for (k, v) in topoStats { try insertStat(db, statInsert, "topology", k, v) }

        let geomStats: [(String, Int)] = [
            ("surfaces", s.surfaces), ("curves3D", s.curves3D), ("curves2D", s.curves2D)
        ]
        for (k, v) in geomStats { try insertStat(db, statInsert, "geometry", k, v) }

        let activeStats: [(String, Int)] = [
            ("faces", g.activeFaceCount), ("edges", g.activeEdgeCount),
            ("vertices", g.activeVertexCount), ("surfaces", g.activeSurfaceCount),
            ("curves3D", g.activeCurve3DCount), ("curves2D", g.activeCurve2DCount)
        ]
        for (k, v) in activeStats { try insertStat(db, statInsert, "active", k, v) }

        // Validation
        let v = g.validate()
        try exec(db, "INSERT INTO validation VALUES (\(v.isValid ? 1 : 0), \(v.errorCount), \(v.warningCount))")

        // Root nodes
        for root in g.rootNodes {
            try exec(db, "INSERT INTO root_nodes (kind, idx) VALUES (\(root.kind.rawValue), \(root.index))")
        }
    }

    // MARK: - Nodes

    private static func insertNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        // Vertices
        let nodeInsert = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        let vtxInsert = "INSERT INTO vertex_props (idx, x, y, z, tolerance, edge_count) VALUES (?, ?, ?, ?, ?, ?)"
        var vtxStmt: OpaquePointer?
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, vtxInsert, -1, &vtxStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, nodeInsert, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(vtxStmt); sqlite3_finalize(nodeStmt) }

        for i in 0..<g.vertexCount {
            let pt = g.vertexPoint(i)
            let removed = g.isRemoved(nodeKind: .vertex, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.vertex.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(vtxStmt)
            sqlite3_bind_int(vtxStmt, 1, Int32(i))
            sqlite3_bind_double(vtxStmt, 2, pt.x)
            sqlite3_bind_double(vtxStmt, 3, pt.y)
            sqlite3_bind_double(vtxStmt, 4, pt.z)
            sqlite3_bind_double(vtxStmt, 5, g.vertexTolerance(i))
            sqlite3_bind_int(vtxStmt, 6, Int32(g.edges(of: i).count))
            sqlite3_step(vtxStmt)
        }

        // Edges
        try insertEdgeNodes(db, graph: g)

        // Faces
        try insertFaceNodes(db, graph: g)

        // Wires
        try insertWireNodes(db, graph: g)

        // CoEdges
        try insertCoEdgeNodes(db, graph: g)

        // Shells
        try insertShellNodes(db, graph: g)

        // Solids
        try insertSolidNodes(db, graph: g)

        // Compounds
        try insertCompoundNodes(db, graph: g)

        // CompSolids
        try insertCompSolidNodes(db, graph: g)
    }

    private static func insertEdgeNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = """
        INSERT INTO edge_props (idx, tolerance, degenerated, closed, has_curve, has_polygon_3d,
            same_parameter, same_range, max_continuity, range_first, range_last,
            start_vertex, end_vertex, is_boundary, is_manifold, face_count, wire_count, coedge_count)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.edgeCount {
            let r = g.edgeRange(i)
            let removed = g.isRemoved(nodeKind: .edge, nodeIndex: i)

            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.edge.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_double(stmt, 2, g.edgeTolerance(i))
            sqlite3_bind_int(stmt, 3, g.isEdgeDegenerated(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 4, g.isEdgeClosed(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 5, g.edgeHasCurve(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 6, g.edgeHasPolygon3D(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 7, g.isEdgeSameParameter(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 8, g.isEdgeSameRange(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 9, Int32(g.edgeMaxContinuity(i)))
            sqlite3_bind_double(stmt, 10, r.first)
            sqlite3_bind_double(stmt, 11, r.last)
            if let sv = g.edgeStartVertex(i) { sqlite3_bind_int(stmt, 12, Int32(sv)) }
            else { sqlite3_bind_null(stmt, 12) }
            if let ev = g.edgeEndVertex(i) { sqlite3_bind_int(stmt, 13, Int32(ev)) }
            else { sqlite3_bind_null(stmt, 13) }
            sqlite3_bind_int(stmt, 14, g.isBoundaryEdge(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 15, g.isManifoldEdge(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 16, Int32(g.faces(of: i).count))
            sqlite3_bind_int(stmt, 17, Int32(g.edgeWires(i).count))
            sqlite3_bind_int(stmt, 18, Int32(g.edgeCoEdges(i).count))
            sqlite3_step(stmt)
        }
    }

    private static func insertFaceNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = """
        INSERT INTO face_props (idx, tolerance, has_surface, has_triangulation, natural_restriction,
            wire_count, outer_wire, vertex_ref_count, shell_count, compound_count)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.faceCount {
            let removed = g.isRemoved(nodeKind: .face, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.face.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_double(stmt, 2, g.faceTolerance(i))
            sqlite3_bind_int(stmt, 3, g.faceHasSurface(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 4, g.faceHasTriangulation(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 5, g.isFaceNaturalRestriction(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 6, Int32(g.faceWireCount(i)))
            sqlite3_bind_int(stmt, 7, Int32(g.outerWire(of: i)))
            sqlite3_bind_int(stmt, 8, Int32(g.faceVertexRefCount(i)))
            sqlite3_bind_int(stmt, 9, Int32(g.faceShells(i).count))
            sqlite3_bind_int(stmt, 10, Int32(g.faceCompoundCount(i)))
            sqlite3_step(stmt)
        }
    }

    private static func insertWireNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO wire_props (idx, closed, coedge_count, face_count) VALUES (?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.wireCount {
            let removed = g.isRemoved(nodeKind: .wire, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.wire.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_int(stmt, 2, g.isWireClosed(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 3, Int32(g.wireCoEdgeCount(i)))
            sqlite3_bind_int(stmt, 4, Int32(g.wireFaces(i).count))
            sqlite3_step(stmt)
        }
    }

    private static func insertCoEdgeNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO coedge_props (idx, edge_idx, face_idx, seam_pair, has_pcurve, range_first, range_last) VALUES (?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.coedgeCount {
            let removed = g.isRemoved(nodeKind: .coedge, nodeIndex: i)
            let r = g.coedgeRange(i)

            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.coedge.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_int(stmt, 2, Int32(g.coedgeEdge(i)))
            sqlite3_bind_int(stmt, 3, Int32(g.coedgeFace(i)))
            if let sp = g.coedgeSeamPair(i) { sqlite3_bind_int(stmt, 4, Int32(sp)) }
            else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int(stmt, 5, g.coedgeHasPCurve(i) ? 1 : 0)
            sqlite3_bind_double(stmt, 6, r.first)
            sqlite3_bind_double(stmt, 7, r.last)
            sqlite3_step(stmt)
        }
    }

    private static func insertShellNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO shell_props (idx, closed, solid_count, compound_count) VALUES (?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.shellCount {
            let removed = g.isRemoved(nodeKind: .shell, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.shell.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_int(stmt, 2, g.isShellClosed(i) ? 1 : 0)
            sqlite3_bind_int(stmt, 3, Int32(g.shellSolids(i).count))
            sqlite3_bind_int(stmt, 4, Int32(g.shellCompoundCount(i)))
            sqlite3_step(stmt)
        }
    }

    private static func insertSolidNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO solid_props (idx, comp_solid_count, compound_count) VALUES (?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.solidCount {
            let removed = g.isRemoved(nodeKind: .solid, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.solid.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_int(stmt, 2, Int32(g.solidCompSolidCount(i)))
            sqlite3_bind_int(stmt, 3, Int32(g.solidCompoundCount(i)))
            sqlite3_step(stmt)
        }
    }

    private static func insertCompoundNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO compound_props (idx, child_count, parent_count) VALUES (?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.compoundCount {
            let removed = g.isRemoved(nodeKind: .compound, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.compound.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_int(stmt, 2, Int32(g.compoundChildCount(i)))
            sqlite3_bind_int(stmt, 3, Int32(g.compoundParentCount(i)))
            sqlite3_step(stmt)
        }
    }

    private static func insertCompSolidNodes(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO comp_solid_props (idx, solid_count, compound_count) VALUES (?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let nodeSQL = "INSERT INTO nodes (kind, idx, removed) VALUES (?, ?, ?)"
        var nodeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(nodeStmt) }

        for i in 0..<g.compSolidCount {
            let removed = g.isRemoved(nodeKind: .compSolid, nodeIndex: i)
            sqlite3_reset(nodeStmt)
            sqlite3_bind_int(nodeStmt, 1, Int32(TopologyGraph.NodeKind.compSolid.rawValue))
            sqlite3_bind_int(nodeStmt, 2, Int32(i))
            sqlite3_bind_int(nodeStmt, 3, removed ? 1 : 0)
            sqlite3_step(nodeStmt)

            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(i))
            sqlite3_bind_int(stmt, 2, Int32(g.compSolidSolidCount(i)))
            sqlite3_bind_int(stmt, 3, Int32(g.compSolidCompoundCount(i)))
            sqlite3_step(stmt)
        }
    }

    // MARK: - References

    private static func insertReferences(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        let sql = "INSERT INTO refs (ref_kind, ref_idx, child_kind, child_idx, orientation, removed) VALUES (?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        let refKinds: [(TopologyGraph.RefKind, Int)] = [
            (.shell, g.shellRefCount), (.face, g.faceRefCount),
            (.wire, g.wireRefCount), (.coedge, g.coedgeRefCount),
            (.vertex, g.vertexRefCount), (.solid, g.solidRefCount),
            (.child, g.childRefCount), (.occurrence, g.occurrenceRefCount)
        ]

        for (refKind, count) in refKinds {
            for i in 0..<count {
                guard let childKind = g.refChildNodeKind(refKind, refIndex: i) else { continue }
                sqlite3_reset(stmt)
                sqlite3_bind_int(stmt, 1, refKind.rawValue)
                sqlite3_bind_int(stmt, 2, Int32(i))
                sqlite3_bind_int(stmt, 3, childKind.rawValue)
                sqlite3_bind_int(stmt, 4, Int32(g.refChildNodeIndex(refKind, refIndex: i)))
                sqlite3_bind_int(stmt, 5, Int32(g.refOrientation(refKind, refIndex: i)))
                sqlite3_bind_int(stmt, 6, g.isRefRemoved(refKind, refIndex: i) ? 1 : 0)
                sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Adjacency

    private static func insertAdjacency(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        // Face adjacency
        var faStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO face_adjacency (face_a, face_b) VALUES (?,?)", -1, &faStmt, nil)
        defer { sqlite3_finalize(faStmt) }

        // Shared edges
        var seStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO shared_edges (face_a, face_b, edge_idx) VALUES (?,?,?)", -1, &seStmt, nil)
        defer { sqlite3_finalize(seStmt) }

        for i in 0..<g.faceCount {
            let adj = g.adjacentFaces(of: i)
            for j in adj {
                sqlite3_reset(faStmt)
                sqlite3_bind_int(faStmt, 1, Int32(i))
                sqlite3_bind_int(faStmt, 2, Int32(j))
                sqlite3_step(faStmt)

                for e in g.sharedEdges(between: i, and: j) {
                    sqlite3_reset(seStmt)
                    sqlite3_bind_int(seStmt, 1, Int32(i))
                    sqlite3_bind_int(seStmt, 2, Int32(j))
                    sqlite3_bind_int(seStmt, 3, Int32(e))
                    sqlite3_step(seStmt)
                }
            }

            // Same-domain faces
            for sd in g.sameDomainFaces(of: i) {
                try exec(db, "INSERT OR IGNORE INTO same_domain_faces (face_a, face_b) VALUES (\(i), \(sd))")
            }
        }

        // Edge adjacency
        var eaStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO edge_adjacency (edge_a, edge_b) VALUES (?,?)", -1, &eaStmt, nil)
        defer { sqlite3_finalize(eaStmt) }

        // Face-edge incidence + edge-vertex incidence
        var feiStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO face_edge_incidence (face_idx, edge_idx) VALUES (?,?)", -1, &feiStmt, nil)
        defer { sqlite3_finalize(feiStmt) }

        var eviStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO edge_vertex_incidence (edge_idx, vertex_idx, role) VALUES (?,?,?)", -1, &eviStmt, nil)
        defer { sqlite3_finalize(eviStmt) }

        var veiStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO vertex_edge_incidence (vertex_idx, edge_idx) VALUES (?,?)", -1, &veiStmt, nil)
        defer { sqlite3_finalize(veiStmt) }

        for i in 0..<g.edgeCount {
            for adj in g.adjacentEdges(of: i) {
                sqlite3_reset(eaStmt)
                sqlite3_bind_int(eaStmt, 1, Int32(i))
                sqlite3_bind_int(eaStmt, 2, Int32(adj))
                sqlite3_step(eaStmt)
            }

            for f in g.faces(of: i) {
                sqlite3_reset(feiStmt)
                sqlite3_bind_int(feiStmt, 1, Int32(f))
                sqlite3_bind_int(feiStmt, 2, Int32(i))
                sqlite3_step(feiStmt)
            }

            if let sv = g.edgeStartVertex(i) {
                sqlite3_reset(eviStmt)
                sqlite3_bind_int(eviStmt, 1, Int32(i))
                sqlite3_bind_int(eviStmt, 2, Int32(sv))
                sqlite3_bind_text(eviStmt, 3, "start", -1, nil)
                sqlite3_step(eviStmt)

                sqlite3_reset(veiStmt)
                sqlite3_bind_int(veiStmt, 1, Int32(sv))
                sqlite3_bind_int(veiStmt, 2, Int32(i))
                sqlite3_step(veiStmt)
            }
            if let ev = g.edgeEndVertex(i) {
                sqlite3_reset(eviStmt)
                sqlite3_bind_int(eviStmt, 1, Int32(i))
                sqlite3_bind_int(eviStmt, 2, Int32(ev))
                sqlite3_bind_text(eviStmt, 3, "end", -1, nil)
                sqlite3_step(eviStmt)

                sqlite3_reset(veiStmt)
                sqlite3_bind_int(veiStmt, 1, Int32(ev))
                sqlite3_bind_int(veiStmt, 2, Int32(i))
                sqlite3_step(veiStmt)
            }
        }
    }

    // MARK: - Assembly

    private static func insertAssembly(_ db: OpaquePointer, graph g: TopologyGraph) throws {
        for i in 0..<g.productCount {
            let root = g.productShapeRoot(i)
            let rootKindStr = root.map { "\($0.kind.rawValue)" } ?? "NULL"
            let rootIdxStr = root.map { "\($0.index)" } ?? "NULL"
            try exec(db, """
                INSERT INTO products (idx, is_assembly, is_part, component_count, shape_root_kind, shape_root_idx)
                VALUES (\(i), \(g.productIsAssembly(i) ? 1 : 0), \(g.productIsPart(i) ? 1 : 0), \(g.productComponentCount(i)), \(rootKindStr), \(rootIdxStr))
                """)
        }

        for i in 0..<g.occurrenceCount {
            let parentOcc = g.occurrenceParentOccurrence(i)
            let parentOccStr = parentOcc.map { "\($0)" } ?? "NULL"
            try exec(db, """
                INSERT INTO occurrences (idx, product_idx, parent_product_idx, parent_occurrence_idx)
                VALUES (\(i), \(g.occurrenceProduct(i)), \(g.occurrenceParentProduct(i)), \(parentOccStr))
                """)
        }

        for idx in g.rootProductIndices {
            try exec(db, "INSERT INTO root_products (product_idx) VALUES (\(idx))")
        }
    }

    // MARK: - Views

    private static func createViews(_ db: OpaquePointer) throws {
        let views = """
        CREATE VIEW boundary_edges AS
        SELECT * FROM edge_props WHERE is_boundary = 1;

        CREATE VIEW non_manifold_edges AS
        SELECT * FROM edge_props WHERE is_manifold = 0 AND is_boundary = 0;

        CREATE VIEW manifold_edges AS
        SELECT * FROM edge_props WHERE is_manifold = 1;

        CREATE VIEW free_edges AS
        SELECT * FROM edge_props WHERE face_count = 0;

        CREATE VIEW degenerate_edges AS
        SELECT * FROM edge_props WHERE degenerated = 1;

        CREATE VIEW open_shells AS
        SELECT * FROM shell_props WHERE closed = 0;

        CREATE VIEW open_wires AS
        SELECT * FROM wire_props WHERE closed = 0;

        CREATE VIEW seam_coedges AS
        SELECT c1.idx AS coedge_a, c1.seam_pair AS coedge_b,
               c1.face_idx, c1.edge_idx
        FROM   coedge_props c1
        WHERE  c1.seam_pair IS NOT NULL
          AND  c1.idx < c1.seam_pair;

        CREATE VIEW face_valence AS
        SELECT face_a AS face_idx, COUNT(*) AS neighbor_count
        FROM   face_adjacency
        GROUP BY face_a;

        CREATE VIEW vertex_valence AS
        SELECT vertex_idx, COUNT(*) AS edge_count
        FROM   vertex_edge_incidence
        GROUP BY vertex_idx;

        CREATE VIEW faces_with_holes AS
        SELECT * FROM face_props WHERE wire_count > 1;

        CREATE VIEW topology_summary AS
        SELECT
            (SELECT COUNT(*) FROM nodes WHERE kind = 0 AND removed = 0) AS solids,
            (SELECT COUNT(*) FROM nodes WHERE kind = 1 AND removed = 0) AS shells,
            (SELECT COUNT(*) FROM nodes WHERE kind = 2 AND removed = 0) AS faces,
            (SELECT COUNT(*) FROM nodes WHERE kind = 3 AND removed = 0) AS wires,
            (SELECT COUNT(*) FROM nodes WHERE kind = 4 AND removed = 0) AS edges,
            (SELECT COUNT(*) FROM nodes WHERE kind = 5 AND removed = 0) AS vertices,
            (SELECT COUNT(*) FROM nodes WHERE kind = 8 AND removed = 0) AS coedges,
            (SELECT COUNT(*) FROM boundary_edges) AS boundary_edge_count,
            (SELECT COUNT(*) FROM non_manifold_edges) AS non_manifold_edge_count,
            (SELECT COUNT(*) FROM degenerate_edges) AS degenerate_edge_count,
            (SELECT COUNT(*) FROM open_shells) AS open_shell_count;
        """
        try exec(db, views)
    }

    // MARK: - SQLite Helpers

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw SQLiteExportError.execFailed(msg)
        }
    }

    private static func insert(_ db: OpaquePointer, _ sql: String, _ key: String, _ value: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, nil)
        sqlite3_bind_text(stmt, 2, value, -1, nil)
        sqlite3_step(stmt)
    }

    private static func insertStat(_ db: OpaquePointer, _ sql: String, _ category: String, _ key: String, _ value: Int) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteExportError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, category, -1, nil)
        sqlite3_bind_text(stmt, 2, key, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(value))
        sqlite3_step(stmt)
    }
}

// MARK: - Errors

public enum SQLiteExportError: Error, LocalizedError {
    case cannotOpen(String)
    case prepareFailed
    case execFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path): return "Cannot open SQLite database at \(path)"
        case .prepareFailed: return "Failed to prepare SQLite statement"
        case .execFailed(let msg): return "SQLite exec failed: \(msg)"
        }
    }
}
