// Reconstruct — JSON `[FeatureSpec]` → BREP via OCCTSwift.FeatureReconstructor.
//
// Closes OCCTSwiftScripts#3. Was blocked on OCCTSwift#62 (FeatureReconstructor
// landed v0.142) and #82 (FeatureSpec Codable; ended up as a discriminator-flat
// JSON front end via FeatureReconstructor.buildJSON in v0.147).
//
// Request schema: a JSON object with three top-level keys:
//   outputDir   path where the rebuilt BREP is written
//   outputName  optional file stem (default "reconstructed")
//   features    array of feature entries — each with a "kind" discriminator
//               ("revolve" | "extrude" | "hole" | "thread" | "fillet" |
//                "chamfer") and snake_case fields per
//               FeatureReconstructor.swift's private FeatureEntry decoder.
//
// Stdout: JSON envelope:
//   { "shape": "/path/to/<name>.brep" | null,
//     "fulfilled":  ["id1", ...],
//     "skipped":    [{"id","stage","reason","detail"}, ...],
//     "annotations":[{"id","kind","detail"}, ...] }

import Foundation
import OCCTSwift
import ScriptHarness

enum ReconstructCommand: Subcommand {
    static let name = "reconstruct"
    static let summary = "Build a BREP from a [FeatureSpec] JSON via FeatureReconstructor"
    static let usage = """
        Usage:
          reconstruct                  (read JSON request from stdin)
          reconstruct <request.json>   (read JSON request from file)
        """

    struct Response: Encodable {
        let shape: String?
        let fulfilled: [String]
        let skipped: [SkippedReport]
        let annotations: [AnnotationReport]
    }
    struct SkippedReport: Encodable {
        let id: String; let stage: String; let reason: String; let detail: String?
    }
    struct AnnotationReport: Encodable {
        let id: String; let kind: String; let detail: String?
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

        // Top-level envelope is parsed via JSONSerialization so we can extract
        // outputDir + outputName, then re-pack the features array into the
        // {"features": [...]} shape that FeatureReconstructor.buildJSON expects.
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ScriptError.message("Invalid JSON: \(error.localizedDescription)")
        }
        guard let dict = raw as? [String: Any] else {
            throw ScriptError.message("Top-level JSON must be an object with outputDir, features")
        }
        guard let outputDir = dict["outputDir"] as? String else {
            throw ScriptError.message("Missing required field: outputDir")
        }
        let outputName = (dict["outputName"] as? String) ?? "reconstructed"
        guard let featuresAny = dict["features"] as? [Any] else {
            throw ScriptError.message("Missing required field: features (array)")
        }

        let envelope: [String: Any] = ["features": featuresAny]
        let envelopeData: Data
        do {
            envelopeData = try JSONSerialization.data(withJSONObject: envelope, options: [])
        } catch {
            throw ScriptError.message("Failed to repack features: \(error.localizedDescription)")
        }

        let result: FeatureReconstructor.BuildResult
        do {
            result = try FeatureReconstructor.buildJSON(envelopeData)
        } catch {
            throw ScriptError.message("FeatureReconstructor failed: \(error.localizedDescription)")
        }

        // Write the rebuilt BREP if produced.
        var outPath: String? = nil
        if let shape = result.shape {
            let outDir = URL(fileURLWithPath: outputDir)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outURL = outDir.appendingPathComponent("\(outputName).brep")
            try GraphIO.writeBREP(shape, to: outURL.path)
            outPath = outURL.path
        }

        let response = Response(
            shape: outPath,
            fulfilled: result.fulfilled,
            skipped: result.skipped.map { s in
                let (reasonName, detail): (String, String?) = {
                    switch s.reason {
                    case .underDetermined(let d): return ("under_determined", d)
                    case .occtFailure(let d):     return ("occt_failure", d)
                    case .unresolvedRef(let d):   return ("unresolved_ref", d)
                    case .unsupported(let d):     return ("unsupported", d)
                    }
                }()
                return SkippedReport(id: s.featureID, stage: s.stage.rawValue,
                                     reason: reasonName, detail: detail)
            },
            annotations: result.annotations.map { a in
                switch a.kind {
                case .thread(let spec, let holeRef, let length):
                    let detail = "spec=\(spec); hole=\(holeRef)" + (length.map { "; length=\($0)" } ?? "")
                    return AnnotationReport(id: a.featureID, kind: "thread", detail: detail)
                }
            }
        )
        try GraphIO.emitJSON(response)
        return result.shape == nil && !featuresAny.isEmpty ? 2 : 0
    }
}
