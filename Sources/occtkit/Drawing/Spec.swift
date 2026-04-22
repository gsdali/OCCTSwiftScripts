// Spec.swift
// JSON request schema for the `drawing-export` verb.
//
// Mirrors the OCCTSwift v0.147+ types that aren't yet Codable upstream
// (PaperSize, Orientation, ProjectionAngle, TitleBlock fields). Translation
// to upstream types happens at the verb boundary in DrawingExport.swift.

import Foundation
import OCCTSwift

struct DrawingSpec: Codable {
    let shape: String                                // path to BREP file
    let output: String                               // path for output DXF
    let sheet: SheetSpec
    let title: TitleBlockSpec?                       // omitted → no title block
    let views: [ViewSpec]                            // typically 3 orthographic views
    let sections: [SectionSpec]?                     // optional section views
    let centerlines: AutoToggle?                     // .auto | .none (default .auto)
    let centermarks: CentermarkRequest?              // .auto | .none | [explicit]
    let cosmeticThreads: [CosmeticThreadSpec]?       // ISO 6410 thread overlays
    let surfaceFinish: [SurfaceFinishSpec]?          // ISO 1302 surface-finish symbols
    let gdt: [GDTSpec]?                              // ISO 1101 feature control frames
    let detailViews: [DetailViewSpec]?               // zoomed close-ups
    let dimensions: [DimensionSpec]?                 // explicit dimensions per view
    let deflection: Double?                          // tessellation deflection (default 0.1)
}

enum AutoToggle: String, Codable { case auto, none }

// MARK: - Sheet

struct SheetSpec: Codable {
    let size: PaperSizeName                          // a0..a4
    let orientation: OrientationName                 // landscape | portrait
    let projection: ProjectionAngleName              // first | third
    let scale: ScaleSpec                             // .auto | .ratio(num, den)
    let border: Bool?                                // default true
    let projectionSymbol: Bool?                      // default true
}

enum PaperSizeName: String, Codable {
    case a0, a1, a2, a3, a4
    var upstream: PaperSize {
        switch self {
        case .a0: return .A0
        case .a1: return .A1
        case .a2: return .A2
        case .a3: return .A3
        case .a4: return .A4
        }
    }
}

enum OrientationName: String, Codable {
    case landscape, portrait
    var upstream: Orientation {
        switch self {
        case .landscape: return .landscape
        case .portrait:  return .portrait
        }
    }
}

enum ProjectionAngleName: String, Codable {
    case first, third
    var upstream: ProjectionAngle {
        switch self {
        case .first: return .first
        case .third: return .third
        }
    }
}

enum ScaleSpec: Codable, Equatable {
    case auto
    case ratio(numerator: Double, denominator: Double)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "auto" { self = .auto; return }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "invalid scale: \(raw)")
        }
        self = .ratio(numerator: parts[0], denominator: parts[1])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .ratio(let n, let d): try c.encode("\(n):\(d)")
        }
    }

    /// Multiplier from model units → drawing-paper units (mm).
    var multiplier: Double {
        switch self {
        case .auto: return 1.0
        case .ratio(let n, let d): return n / d
        }
    }
}

// MARK: - Title block

struct TitleBlockSpec: Codable {
    let title: String
    let drawingNumber: String?
    let owner: String?
    let creator: String?
    let approver: String?
    let documentType: String?
    let dateOfIssue: String?
    let revision: String?
    let sheetNumber: String?
    let language: String?
    let material: String?
    let weight: String?

    func upstream(scale: String) -> TitleBlock {
        TitleBlock(
            title: title,
            drawingNumber: drawingNumber,
            owner: owner,
            creator: creator,
            approver: approver,
            documentType: documentType,
            dateOfIssue: dateOfIssue,
            revision: revision,
            sheetNumber: sheetNumber,
            language: language,
            material: material,
            weight: weight,
            scale: scale
        )
    }
}

// MARK: - Views

struct ViewSpec: Codable {
    let name: String
    let direction: [Double]?
}

struct SectionSpec: Codable {
    let name: String
    let plane: PlaneSpec
    let labelOnView: String?
    let viewDirection: [Double]?
    let hatchAngle: Double?                          // radians, default π/4
    let hatchSpacing: Double?                        // mm, default 3
}

struct PlaneSpec: Codable {
    let origin: [Double]
    let normal: [Double]
}

// MARK: - Annotations

enum CentermarkRequest: Codable {
    case auto
    case off
    case explicit([CentermarkSpec])

    init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            switch raw {
            case "auto": self = .auto; return
            case "none", "off": self = .off; return
            default:
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                       debugDescription: "centermarks expects \"auto\", \"none\", or [...]")
            }
        }
        let arr = try decoder.singleValueContainer().decode([CentermarkSpec].self)
        self = .explicit(arr)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .off: try c.encode("none")
        case .explicit(let xs): try c.encode(xs)
        }
    }
}

struct CentermarkSpec: Codable {
    let view: String
    let x: Double
    let y: Double
    let extent: Double?
}

struct CosmeticThreadSpec: Codable {
    let view: String                                 // which view's 2D frame
    let axisStart: [Double]                          // 2D
    let axisEnd: [Double]                            // 2D
    let majorDiameter: Double
    let pitch: Double
    let callout: String?
}

struct SurfaceFinishSpec: Codable {
    let view: String
    let position: [Double]                           // 2D label position
    let leaderTo: [Double]                           // 2D feature target
    let ra: Double                                   // micrometres
    let symbol: String?                              // any | machiningRequired | machiningProhibited
    let method: String?                              // process text
}

struct GDTSpec: Codable {
    let view: String
    let position: [Double]
    let symbol: String                               // perpendicularity | flatness | …
    let tolerance: String                            // "0.05" or "0.1 M"
    let datums: [String]?
    let leaderTo: [Double]?
}

struct DetailViewSpec: Codable {
    let name: String                                 // e.g. "D"
    let fromView: String                             // parent view name
    let centre: [Double]                             // 2D centre of detail circle
    let radius: Double                               // 2D radius of region
    let scale: Double                                // detail scale multiplier
    let placement: [Double]?                         // 2D sheet position; auto-stacked if nil
}

// MARK: - Dimensions

struct DimensionSpec: Codable {
    let view: String
    let type: DimensionKind
    let from: [Double]?
    let to: [Double]?
    let offset: Double?
    let centre: [Double]?
    let radius: Double?
    let leaderAngle: Double?
    let vertex: [Double]?
    let ray1: [Double]?
    let ray2: [Double]?
    let arcRadius: Double?
    let label: String?
}

enum DimensionKind: String, Codable {
    case linear, radial, diameter, angular
}
