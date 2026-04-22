// SolveSketch — solve a 2D constraint sketch (SwiftGCS) from JSON.
//
// Reads a JSON sketch description from stdin (or argv[0] file path), builds a
// ConstraintSketch, solves it, and writes the resolved positions + diagnostics
// to stdout as JSON. Closes #4.
//
// Usage:
//   SolveSketch                  (reads JSON from stdin)
//   SolveSketch <sketch.json>    (reads JSON from file)
//
// Request schema:
//   {
//     "points":      [{"id": "p1", "x": 0, "y": 0, "fixed": false}, ...],
//     "lines":       [{"id": "l1", "p1": "p1", "p2": "p2"}, ...],
//     "circles":     [{"id": "c1", "center": "p1", "radius": 1.0}, ...],
//     "constraints": [{"type": "coincident", "a": "p1", "b": "p2"}, ...]
//   }
//
// Supported constraint types:
//   coincident, horizontal, vertical, fixed_distance, fixed,
//   parallel, perpendicular, angle, point_on_line, point_on_circle,
//   tangent_line_circle, tangent_circle_circle
//
// Response shape:
//   { "status": "converged"|"max_iterations"|"failed", "message": str?,
//     "iterations": int, "residualNorm": double,
//     "diagnostics": { "degreesOfFreedom": int, "overConstrained": bool,
//                      "fullyConstrained": bool, "redundantConstraints": [int] },
//     "points": [{"id": "p1", "x": 0.0, "y": 0.0}, ...] }

import Foundation
import ScriptHarness
import SwiftGCS

struct Request: Decodable {
    let points: [PointSpec]
    let lines: [LineSpec]?
    let circles: [CircleSpec]?
    let constraints: [ConstraintSpec]?

    struct PointSpec: Decodable { let id: String; let x: Double; let y: Double; let fixed: Bool? }
    struct LineSpec: Decodable { let id: String; let p1: String; let p2: String }
    struct CircleSpec: Decodable { let id: String; let center: String; let radius: Double }
    struct ConstraintSpec: Decodable {
        let type: String
        let a: String?
        let b: String?
        let line: String?
        let circle: String?
        let point: String?
        let value: Double?
        let radians: Double?
        let tangentType: String?
    }
}

struct Response: Encodable {
    let status: String
    let message: String?
    let iterations: Int
    let residualNorm: Double
    let diagnostics: Diagnostics
    let points: [PointOut]
    struct Diagnostics: Encodable {
        let degreesOfFreedom: Int
        let overConstrained: Bool
        let fullyConstrained: Bool
        let redundantConstraints: [Int]
    }
    struct PointOut: Encodable { let id: String; let x: Double; let y: Double }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

let inputData: Data
if let path = args.first, !path.hasPrefix("-") {
    guard let bytes = FileManager.default.contents(atPath: path) else {
        die("Failed to read \(path)")
    }
    inputData = bytes
} else {
    inputData = FileHandle.standardInput.readDataToEndOfFile()
}

let request: Request
do {
    request = try JSONDecoder().decode(Request.self, from: inputData)
} catch {
    die("Invalid request JSON: \(error.localizedDescription)")
}

@MainActor
func solve(_ req: Request) throws -> Response {
    let sketch = ConstraintSketch()
    var points: [String: Point2D] = [:]
    var lines: [String: LineSegment2D] = [:]
    var circles: [String: Circle2D] = [:]

    for spec in req.points {
        let p = sketch.addPoint(x: spec.x, y: spec.y)
        points[spec.id] = p
        if spec.fixed == true {
            sketch.addFixed(p, x: spec.x, y: spec.y)
        }
    }
    for spec in req.lines ?? [] {
        guard let p1 = points[spec.p1], let p2 = points[spec.p2] else {
            throw ScriptError.message("Line \(spec.id) references unknown point(s)")
        }
        lines[spec.id] = sketch.addLineSegment(from: p1, to: p2)
    }
    for spec in req.circles ?? [] {
        guard let center = points[spec.center] else {
            throw ScriptError.message("Circle \(spec.id) references unknown center: \(spec.center)")
        }
        circles[spec.id] = sketch.addCircle(centre: center, radius: spec.radius)
    }

    func need<T>(_ id: String?, _ table: [String: T], _ kind: String, _ ctype: String) throws -> T {
        guard let id, let v = table[id] else {
            throw ScriptError.message("Constraint \(ctype) references unknown \(kind): \(id ?? "<missing>")")
        }
        return v
    }

    for spec in req.constraints ?? [] {
        switch spec.type {
        case "coincident":
            sketch.addCoincident(try need(spec.a, points, "point", spec.type),
                                 try need(spec.b, points, "point", spec.type))
        case "horizontal":
            if let l = spec.line {
                sketch.addHorizontal(try need(l, lines, "line", spec.type))
            } else {
                sketch.addHorizontal(try need(spec.a, points, "point", spec.type),
                                     try need(spec.b, points, "point", spec.type))
            }
        case "vertical":
            if let l = spec.line {
                sketch.addVertical(try need(l, lines, "line", spec.type))
            } else {
                sketch.addVertical(try need(spec.a, points, "point", spec.type),
                                   try need(spec.b, points, "point", spec.type))
            }
        case "fixed_distance":
            guard let value = spec.value else { throw ScriptError.message("fixed_distance requires \"value\"") }
            sketch.addDistance(try need(spec.a, points, "point", spec.type),
                               try need(spec.b, points, "point", spec.type), value: value)
        case "fixed":
            let p = try need(spec.point ?? spec.a, points, "point", spec.type)
            if let x = spec.value, let y = spec.radians {
                sketch.addFixed(p, x: x, y: y)
            } else {
                sketch.addFixed(p)
            }
        case "parallel":
            sketch.addParallel(try need(spec.a, lines, "line", spec.type),
                               try need(spec.b, lines, "line", spec.type))
        case "perpendicular":
            sketch.addPerpendicular(try need(spec.a, lines, "line", spec.type),
                                    try need(spec.b, lines, "line", spec.type))
        case "angle":
            guard let radians = spec.radians else { throw ScriptError.message("angle requires \"radians\"") }
            sketch.addAngle(try need(spec.a, lines, "line", spec.type),
                            try need(spec.b, lines, "line", spec.type), radians: radians)
        case "point_on_line":
            sketch.addPointOnLine(try need(spec.point, points, "point", spec.type),
                                  try need(spec.line, lines, "line", spec.type))
        case "point_on_circle":
            sketch.addPointOnCircle(try need(spec.point, points, "point", spec.type),
                                    try need(spec.circle, circles, "circle", spec.type))
        case "tangent_line_circle":
            sketch.addTangent(try need(spec.line, lines, "line", spec.type),
                              try need(spec.circle, circles, "circle", spec.type))
        case "tangent_circle_circle":
            let t: TangentType = (spec.tangentType == "internal") ? .internal_ : .external
            sketch.addTangent(try need(spec.a, circles, "circle", spec.type),
                              try need(spec.b, circles, "circle", spec.type), type: t)
        default:
            throw ScriptError.message("Unknown constraint type: \(spec.type)")
        }
    }

    let result = sketch.solve()
    let statusString: String
    let message: String?
    switch result.status {
    case .converged:           statusString = "converged";     message = nil
    case .maxIterationsReached: statusString = "max_iterations"; message = nil
    case .failed(let reason):  statusString = "failed";        message = reason
    }

    let resolved = req.points.map { spec -> Response.PointOut in
        let p = points[spec.id]!
        let pos = sketch.position(of: p)
        return Response.PointOut(id: spec.id, x: pos.x, y: pos.y)
    }

    return Response(
        status: statusString,
        message: message,
        iterations: result.iterations,
        residualNorm: result.finalResidualNorm,
        diagnostics: Response.Diagnostics(
            degreesOfFreedom: result.diagnostics.degreesOfFreedom,
            overConstrained: result.diagnostics.isOverConstrained,
            fullyConstrained: result.diagnostics.isFullyConstrained,
            redundantConstraints: result.diagnostics.redundantConstraints
        ),
        points: resolved
    )
}

let response: Response
do {
    response = try MainActor.assumeIsolated { try solve(request) }
} catch {
    die(error.localizedDescription)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let out: Data
do {
    out = try encoder.encode(response)
} catch {
    die("Failed to encode JSON: \(error.localizedDescription)")
}
FileHandle.standardOutput.write(out)
FileHandle.standardOutput.write(Data([0x0A]))

if response.status == "failed" { exit(2) }
