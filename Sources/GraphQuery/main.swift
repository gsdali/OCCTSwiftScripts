// GraphQuery — emit a JSON topology summary from a BREPGraph SQLite database.
//
// Reads the analysis views written by BREPGraphSQLiteExporter
// (topology_summary, free_edges, open_wires, faces_with_holes,
// face_valence, vertex_valence).
//
// Usage: GraphQuery <graph.sqlite>
// Stdout: JSON summary

import Foundation
import ScriptHarness

#if canImport(SQLite3)
import SQLite3
#endif

struct Query: Codable {
    let summary: Summary
    let counts: Counts
    let valence: Valence

    struct Summary: Codable {
        let solids: Int
        let shells: Int
        let faces: Int
        let wires: Int
        let edges: Int
        let vertices: Int
        let coedges: Int
        let boundaryEdges: Int
        let nonManifoldEdges: Int
        let degenerateEdges: Int
        let openShells: Int
    }
    struct Counts: Codable {
        let freeEdges: Int
        let openWires: Int
        let facesWithHoles: Int
    }
    struct Valence: Codable {
        let face: Stat
        let vertex: Stat
        struct Stat: Codable { let max: Int; let mean: Double; let count: Int }
    }
}

FileHandle.standardError.write(Data("DEPRECATED: 'GraphQuery' standalone target will be removed in a future release. Use 'occtkit graph-query' instead.\n".utf8))

let args = Array(CommandLine.arguments.dropFirst())
do {
    let path = try GraphIO.argument(at: 0, in: args, usage: "Usage: GraphQuery <graph.sqlite>")
    guard FileManager.default.fileExists(atPath: path) else {
        throw ScriptError.message("SQLite file not found: \(path)")
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw ScriptError.message("Failed to open SQLite database: \(path)")
    }
    defer { sqlite3_close(db) }

    func scalarInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func valence(view: String, column: String) -> Query.Valence.Stat {
        let sql = "SELECT MAX(\(column)), AVG(\(column)), COUNT(*) FROM \(view)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Query.Valence.Stat(max: 0, mean: 0, count: 0)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return Query.Valence.Stat(max: 0, mean: 0, count: 0)
        }
        return Query.Valence.Stat(
            max: Int(sqlite3_column_int64(stmt, 0)),
            mean: sqlite3_column_double(stmt, 1),
            count: Int(sqlite3_column_int64(stmt, 2))
        )
    }

    var summaryStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT * FROM topology_summary", -1, &summaryStmt, nil) == SQLITE_OK,
          sqlite3_step(summaryStmt) == SQLITE_ROW else {
        sqlite3_finalize(summaryStmt)
        throw ScriptError.message("topology_summary view missing or empty — is this a BREPGraph SQLite file?")
    }
    let summary = Query.Summary(
        solids:           Int(sqlite3_column_int64(summaryStmt, 0)),
        shells:           Int(sqlite3_column_int64(summaryStmt, 1)),
        faces:            Int(sqlite3_column_int64(summaryStmt, 2)),
        wires:            Int(sqlite3_column_int64(summaryStmt, 3)),
        edges:            Int(sqlite3_column_int64(summaryStmt, 4)),
        vertices:         Int(sqlite3_column_int64(summaryStmt, 5)),
        coedges:          Int(sqlite3_column_int64(summaryStmt, 6)),
        boundaryEdges:    Int(sqlite3_column_int64(summaryStmt, 7)),
        nonManifoldEdges: Int(sqlite3_column_int64(summaryStmt, 8)),
        degenerateEdges:  Int(sqlite3_column_int64(summaryStmt, 9)),
        openShells:       Int(sqlite3_column_int64(summaryStmt, 10))
    )
    sqlite3_finalize(summaryStmt)

    let counts = Query.Counts(
        freeEdges:      scalarInt("SELECT COUNT(*) FROM free_edges"),
        openWires:      scalarInt("SELECT COUNT(*) FROM open_wires"),
        facesWithHoles: scalarInt("SELECT COUNT(*) FROM faces_with_holes")
    )
    let v = Query.Valence(
        face:   valence(view: "face_valence",   column: "neighbor_count"),
        vertex: valence(view: "vertex_valence", column: "edge_count")
    )

    try GraphIO.emitJSON(Query(summary: summary, counts: counts, valence: v))
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
