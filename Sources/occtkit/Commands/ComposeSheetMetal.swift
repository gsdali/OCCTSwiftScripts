// ComposeSheetMetal — JSON sheet-metal spec → BREP via OCCTSwift.SheetMetal.
//
// Closes OCCTSwiftScripts#10. Wraps the SheetMetal namespace shipped in
// OCCTSwift v0.151 (closing OCCTSwift#85). Kept as a dedicated verb rather
// than folded into `reconstruct` because SheetMetal lives in its own
// namespace upstream — `FeatureReconstructor.build` does not dispatch
// SheetMetal entries, and the upstream split anticipates the reverse
// direction (bent BRep → flat pattern) that does not fit FeatureSpec's
// one-way contract.
//
// Request schema (top-level JSON object):
//   outputDir   path where the composed BREP is written
//   outputName  optional file stem (default "sheet-metal")
//   thickness   sheet thickness; matches upstream `Builder(thickness:)`
//   flanges     [{ id, profile: [[x,y], ...], origin: [x,y,z],
//                  uAxis:  [x,y,z], vAxis?: [x,y,z], normal: [x,y,z] }]
//                — vAxis defaults to cross(normal, uAxis) per upstream.
//   bends       [{ from, to, radius }]   (optional; default [])
//
// Stdout: { "shape": "<path>", "flanges": <int>, "bends": <int> }

import Foundation
import OCCTSwift
import ScriptHarness

enum ComposeSheetMetalCommand: Subcommand {
    static let name = "compose-sheet-metal"
    static let summary = "Compose a sheet-metal BREP from a JSON spec via SheetMetal.Builder"
    static let usage = """
        Usage:
          compose-sheet-metal                   (read JSON request from stdin)
          compose-sheet-metal <request.json>    (read JSON request from file)
        """

    private struct Request: Decodable {
        let outputDir: String
        let outputName: String?
        let thickness: Double
        let flanges: [FlangeSpec]
        let bends: [BendSpec]?
    }

    private struct FlangeSpec: Decodable {
        let id: String
        let profile: [[Double]]
        let origin: [Double]
        let uAxis: [Double]
        let vAxis: [Double]?
        let normal: [Double]
    }

    private struct BendSpec: Decodable {
        let from: String
        let to: String
        let radius: Double
    }

    struct Response: Encodable {
        let shape: String
        let flanges: Int
        let bends: Int
    }

    static func run(args: [String]) throws -> Int32 {
        let data: Data
        if let path = args.first, !path.hasPrefix("-") {
            guard let bytes = FileManager.default.contents(atPath: path) else {
                throw ScriptError.message("Failed to read request at \(path)")
            }
            data = bytes
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }

        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            throw ScriptError.message("Invalid JSON: \(error.localizedDescription)")
        }

        let flanges = try request.flanges.map(buildFlange)
        let bends = (request.bends ?? []).map {
            SheetMetal.Bend(from: $0.from, to: $0.to, radius: $0.radius)
        }

        let builder = SheetMetal.Builder(thickness: request.thickness)
        let shape: Shape
        do {
            shape = try builder.build(flanges: flanges, bends: bends)
        } catch let error as SheetMetal.BuildError {
            throw ScriptError.message(error.description)
        } catch {
            throw ScriptError.message("SheetMetal build failed: \(error.localizedDescription)")
        }

        let outputName = request.outputName ?? "sheet-metal"
        let outDir = URL(fileURLWithPath: request.outputDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(outputName).brep")
        try GraphIO.writeBREP(shape, to: outURL.path)

        try GraphIO.emitJSON(Response(
            shape: outURL.path,
            flanges: flanges.count,
            bends: bends.count
        ))
        return 0
    }

    private static func buildFlange(_ spec: FlangeSpec) throws -> SheetMetal.Flange {
        guard spec.origin.count == 3 else {
            throw ScriptError.message("flange '\(spec.id)': origin must be [x,y,z]")
        }
        guard spec.uAxis.count == 3 else {
            throw ScriptError.message("flange '\(spec.id)': uAxis must be [x,y,z]")
        }
        guard spec.normal.count == 3 else {
            throw ScriptError.message("flange '\(spec.id)': normal must be [x,y,z]")
        }
        let profile = try spec.profile.map { p -> SIMD2<Double> in
            guard p.count == 2 else {
                throw ScriptError.message("flange '\(spec.id)': profile points must be [x,y]")
            }
            return SIMD2(p[0], p[1])
        }
        let vAxis: SIMD3<Double>?
        if let v = spec.vAxis {
            guard v.count == 3 else {
                throw ScriptError.message("flange '\(spec.id)': vAxis must be [x,y,z]")
            }
            vAxis = SIMD3(v[0], v[1], v[2])
        } else {
            vAxis = nil
        }
        return SheetMetal.Flange(
            id: spec.id,
            profile: profile,
            origin: SIMD3(spec.origin[0], spec.origin[1], spec.origin[2]),
            normal: SIMD3(spec.normal[0], spec.normal[1], spec.normal[2]),
            uAxis: SIMD3(spec.uAxis[0], spec.uAxis[1], spec.uAxis[2]),
            vAxis: vAxis
        )
    }
}
