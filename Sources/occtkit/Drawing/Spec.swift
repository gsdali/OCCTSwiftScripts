// Spec.swift
// JSON request schema for the `drawing-export` verb.
//
// A spec describes one technical drawing sheet: which 3D shape to project,
// which orthographic views and section views to lay out, what annotations
// to add, sheet size + projection convention + ISO title block fields.

import Foundation

struct DrawingSpec: Codable {
    let shape: String                       // path to BREP file
    let output: String                      // path for output DXF
    let sheet: SheetSpec
    let title: TitleBlockSpec?              // omitted → no title block
    let views: [ViewSpec]                   // typically 1-3 orthographic views
    let sections: [SectionSpec]?            // optional section views
    let centerlines: AutoToggle?            // .auto | .none (default .auto)
    let centermarks: [CentermarkSpec]?      // explicit centermark positions per view
    let dimensions: [DimensionSpec]?        // explicit dimensions per view
    let deflection: Double?                 // tessellation deflection (default 0.1)
}

enum AutoToggle: String, Codable {
    case auto
    case none
}

struct SheetSpec: Codable {
    let size: PaperSize.Size                // A0..A4
    let orientation: Orientation
    let projection: ProjectionAngle         // first | third
    let scale: ScaleSpec                    // .auto or .ratio(num, den)
    let border: Bool?                       // default true
    let projectionSymbol: Bool?             // default true
}

enum Orientation: String, Codable {
    case landscape
    case portrait
}

enum ProjectionAngle: String, Codable {
    case first
    case third
}

enum ScaleSpec: Codable, Equatable {
    case auto
    case ratio(numerator: Double, denominator: Double)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "auto" {
            self = .auto
            return
        }
        // "1:2" or "2:1"
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
    /// scale "1:2" means model is twice paper size → multiplier = 0.5.
    var multiplier: Double {
        switch self {
        case .auto: return 1.0   // overridden by autoscale
        case .ratio(let n, let d): return n / d
        }
    }
}

/// ISO 7200 title-block data fields. Only `title` is required for a useful drawing;
/// the rest are optional and rendered when present.
struct TitleBlockSpec: Codable {
    let title: String                       // mandatory per ISO 7200
    let drawingNumber: String?              // mandatory per ISO 7200
    let owner: String?                      // legal owner (mandatory per ISO 7200)
    let creator: String?                    // mandatory per ISO 7200
    let approver: String?                   // mandatory per ISO 7200
    let documentType: String?               // mandatory per ISO 7200
    let dateOfIssue: String?                // mandatory per ISO 7200 (ISO 8601)
    let revision: String?
    let sheetNumber: String?                // e.g. "1/1"
    let language: String?
    let material: String?
    let weight: String?
    let scaleOverride: String?              // optional — defaults to derived sheet scale
}

struct ViewSpec: Codable {
    /// One of "front" / "back" / "top" / "bottom" / "left" / "right" / "isometric"
    /// for standard placements, OR a custom name when paired with `direction`.
    let name: String
    /// Custom view direction (3-vector). When omitted and `name` is a standard view,
    /// the direction is derived from the standard.
    let direction: [Double]?
}

struct SectionSpec: Codable {
    /// Section label, e.g. "A" → rendered as "SECTION A-A".
    let name: String
    /// The cutting plane.
    let plane: PlaneSpec
    /// Which named view the cutting-plane line should be drawn on.
    let labelOnView: String?
    /// Direction of view for the resulting section drawing.
    /// Defaults to plane.normal.
    let viewDirection: [Double]?
}

struct PlaneSpec: Codable {
    let origin: [Double]                    // [x, y, z]
    let normal: [Double]                    // [x, y, z]
}

struct CentermarkSpec: Codable {
    let view: String                        // matches ViewSpec.name (or section name)
    let x: Double                           // 2D position in view
    let y: Double
    let extent: Double?                     // default 8mm
}

struct DimensionSpec: Codable {
    let view: String                        // matches ViewSpec.name (or section name)
    let type: DimensionKind
    // Linear: from + to (+ optional offset, label)
    let from: [Double]?
    let to: [Double]?
    let offset: Double?                     // perpendicular distance from baseline
    // Radial / diameter: centre + radius
    let centre: [Double]?
    let radius: Double?
    let leaderAngle: Double?                // radians
    // Angular: vertex + ray1 + ray2
    let vertex: [Double]?
    let ray1: [Double]?
    let ray2: [Double]?
    let arcRadius: Double?
    let label: String?                      // override auto-generated text
}

enum DimensionKind: String, Codable {
    case linear, radial, diameter, angular
}
