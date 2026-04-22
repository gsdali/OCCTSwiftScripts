// DrawingExport — CLI wrapper around DrawingComposer.render.
//
// Reads a JSON spec and a BREP, calls into the public DrawingComposer
// library to compose the drawing, writes the resulting DXF, and emits a
// JSON report on stdout.
//
// In-process callers (iOS apps, library consumers) should `import
// DrawingComposer` and call `Composer.render(spec:shape:)` directly. See
// OCCTSwiftScripts#7 for the rationale.
//
// Usage:
//   drawing-export                  (read JSON spec from stdin)
//   drawing-export <spec.json>      (read JSON spec from file)

import Foundation
import DrawingComposer
import OCCTSwift
import ScriptHarness

enum DrawingExportCommand: Subcommand {
    static let name = "drawing-export"
    static let summary = "Multi-view ISO technical drawing → DXF (border + title + sections + GD&T)"
    static let usage = """
        Usage:
          drawing-export                  (read JSON spec from stdin)
          drawing-export <spec.json>      (read JSON spec from file)
        """

    struct Report: Codable {
        let output: String
        let sheet: String
        let projection: String
        let scale: String
        let viewCount: Int
        let sectionCount: Int
        let detailCount: Int
    }

    static func run(args: [String]) throws -> Int32 {
        let data: Data
        if let path = args.first, !path.hasPrefix("-") {
            guard let bytes = FileManager.default.contents(atPath: path) else {
                throw ScriptError.message("Failed to read spec at \(path)")
            }
            data = bytes
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }

        let spec: DrawingSpec
        do {
            spec = try JSONDecoder().decode(DrawingSpec.self, from: data)
        } catch {
            throw ScriptError.message("Invalid spec JSON: \(error.localizedDescription)")
        }

        guard let shapePath = spec.shape else {
            throw ScriptError.message("CLI requires `shape` (path to BREP) in the spec")
        }
        guard let outputPath = spec.output else {
            throw ScriptError.message("CLI requires `output` (path for DXF) in the spec")
        }

        let shape = try GraphIO.loadBREP(at: shapePath)
        let result: DrawingComposerResult
        do {
            result = try Composer.render(spec: spec, shape: shape)
        } catch {
            throw ScriptError.message(error.localizedDescription)
        }

        do {
            try result.writer.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            throw ScriptError.message("DXF write failed: \(error.localizedDescription)")
        }

        try GraphIO.emitJSON(Report(
            output: outputPath,
            sheet: "\(spec.sheet.size.rawValue.uppercased()) \(spec.sheet.orientation.rawValue)",
            projection: spec.sheet.projection.rawValue,
            scale: result.scaleLabel,
            viewCount: result.viewCount,
            sectionCount: result.sectionCount,
            detailCount: result.detailCount
        ))
        return 0
    }
}
