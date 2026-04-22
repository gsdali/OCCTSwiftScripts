// DXFExport — project a BREP shape and write a DXF R12 drawing.
//
// Wraps Exporter.writeDXF(shape:to:viewDirection:deflection:) (OCCTSwift v0.138+).
// The shape is projected along the view direction (default +Z, i.e. top-down)
// and the resulting hidden-line-removed Drawing is written as DXF R12 ASCII.

import Foundation
import OCCTSwift
import ScriptHarness

enum DXFExportCommand: Subcommand {
    static let name = "dxf-export"
    static let summary = "Project a shape along a view direction and write DXF R12"
    static let usage = """
        Usage: dxf-export <shape.brep> <out.dxf> [--view x,y,z] [--deflection D]
          --view <x,y,z>   View direction for projection (default 0,0,1)
          --deflection D   Tessellation deflection (default 0.1)
        """

    struct Report: Codable {
        let output: String
        let view: [Double]
        let deflection: Double
    }

    static func run(args: [String]) throws -> Int32 {
        var positional: [String] = []
        var view = SIMD3<Double>(0, 0, 1)
        var deflection: Double = 0.1
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--view":
                i += 1
                guard i < args.count else { throw ScriptError.message("--view requires x,y,z") }
                let parts = args[i].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 3 else { throw ScriptError.message("--view expects three comma-separated numbers, got \(args[i])") }
                view = SIMD3(parts[0], parts[1], parts[2])
            case "--deflection":
                i += 1
                guard i < args.count, let d = Double(args[i]) else {
                    throw ScriptError.message("--deflection requires a number")
                }
                deflection = d
            default:
                if args[i].hasPrefix("-") {
                    throw ScriptError.message("Unknown option: \(args[i])")
                }
                positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == 2 else { throw ScriptError.message(usage) }
        let inPath = positional[0]
        let outPath = positional[1]

        let shape = try GraphIO.loadBREP(at: inPath)
        let outURL = URL(fileURLWithPath: outPath)
        do {
            try Exporter.writeDXF(shape: shape, to: outURL, viewDirection: view, deflection: deflection)
        } catch {
            throw ScriptError.message("DXF export failed: \(error.localizedDescription)")
        }

        try GraphIO.emitJSON(Report(
            output: outPath,
            view: [view.x, view.y, view.z],
            deflection: deflection
        ))
        return 0
    }
}
