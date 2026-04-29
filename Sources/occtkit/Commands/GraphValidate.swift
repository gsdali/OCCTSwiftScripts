// GraphValidate — validate a BREP's topology graph and emit structured health.
//
// Existing fields (isValid / errorCount / warningCount) are preserved for
// backward compatibility. Per the OCCTMCP-driver introspection batch
// (OCCTSwiftScripts#18), the response also carries a normalized
// `healthRecord` populated from Shape.analyze() — small-edge / free-edge /
// self-intersection counts, plus the shape's top-level type. `nakedVertexCount`
// isn't exposed by OCCTSwift today; emitted as 0 with a docstring note.

import Foundation
import OCCTSwift
import ScriptHarness

enum GraphValidateCommand: Subcommand {
    static let name = "graph-validate"
    static let summary = "Validate a BREP shape's topology graph and surface a structured health record"
    static let usage = "Usage: graph-validate <shape.brep>"

    struct Response: Encodable {
        let isValid: Bool
        let errorCount: Int
        let warningCount: Int
        let healthRecord: HealthRecord

        struct HealthRecord: Encodable {
            let isValid: Bool
            let shapeType: String
            let freeEdgeCount: Int
            // OCCTSwift v0.156 doesn't expose a naked-vertex count; reported as 0.
            let nakedVertexCount: Int
            let smallEdgeCount: Int
            let smallFaceCount: Int
            let selfIntersecting: Bool
            let errors: [String]
        }
    }

    static func run(args: [String]) throws -> Int32 {
        let path = try GraphIO.argument(at: 0, in: args, usage: usage)
        let shape = try GraphIO.loadBREP(at: path)
        let graph = try GraphIO.buildGraph(from: shape)
        let validation = graph.validate()
        let analysis = shape.analyze()

        let record = Response.HealthRecord(
            isValid: shape.isValid,
            shapeType: shape.shapeType.toLowercaseString(),
            freeEdgeCount: analysis?.freeEdgeCount ?? 0,
            nakedVertexCount: 0,
            smallEdgeCount: analysis?.smallEdgeCount ?? 0,
            smallFaceCount: analysis?.smallFaceCount ?? 0,
            selfIntersecting: (analysis?.selfIntersectionCount ?? 0) > 0,
            errors: []
        )

        try GraphIO.emitJSON(Response(
            isValid: validation.isValid,
            errorCount: validation.errorCount,
            warningCount: validation.warningCount,
            healthRecord: record
        ))
        return 0
    }
}

// `ShapeType.toLowercaseString()` is defined in LoadBrep.swift.
