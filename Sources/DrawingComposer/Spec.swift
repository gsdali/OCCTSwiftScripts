// Spec.swift
// Codable request schema for the multi-view ISO drawing composer.
//
// Mirrors the OCCTSwift v0.147+ types that aren't yet Codable upstream
// (PaperSize, Orientation, ProjectionAngle, TitleBlock fields). Translation
// to upstream types happens via the `upstream` accessors.
//
// `shape` and `output` are optional — they're populated by the CLI wrapper
// (`occtkit drawing-export`) but unused when `Composer.render(spec:shape:)`
// is called directly with a live `Shape` from in-process consumers.

import Foundation
import OCCTSwift

public struct DrawingSpec: Codable, Sendable {
    public var shape: String?                                // path to BREP (CLI only)
    public var output: String?                               // path for output DXF (CLI only)
    public var sheet: SheetSpec
    public var title: TitleBlockSpec?                        // omitted → no title block
    public var views: [ViewSpec]                             // typically 3 orthographic views
    public var sections: [SectionSpec]?                      // optional section views
    public var centerlines: AutoToggle?                      // .auto | .none (default .auto)
    public var centermarks: CentermarkRequest?               // .auto | .none | [explicit]
    public var cosmeticThreads: [CosmeticThreadSpec]?        // ISO 6410 thread overlays
    public var surfaceFinish: [SurfaceFinishSpec]?           // ISO 1302 surface-finish symbols
    public var gdt: [GDTSpec]?                               // ISO 1101 feature control frames
    public var detailViews: [DetailViewSpec]?                // zoomed close-ups
    public var dimensions: [DimensionSpec]?                  // explicit dimensions per view
    public var deflection: Double?                           // tessellation deflection (default 0.1)

    public init(shape: String? = nil,
                output: String? = nil,
                sheet: SheetSpec,
                title: TitleBlockSpec? = nil,
                views: [ViewSpec],
                sections: [SectionSpec]? = nil,
                centerlines: AutoToggle? = nil,
                centermarks: CentermarkRequest? = nil,
                cosmeticThreads: [CosmeticThreadSpec]? = nil,
                surfaceFinish: [SurfaceFinishSpec]? = nil,
                gdt: [GDTSpec]? = nil,
                detailViews: [DetailViewSpec]? = nil,
                dimensions: [DimensionSpec]? = nil,
                deflection: Double? = nil) {
        self.shape = shape
        self.output = output
        self.sheet = sheet
        self.title = title
        self.views = views
        self.sections = sections
        self.centerlines = centerlines
        self.centermarks = centermarks
        self.cosmeticThreads = cosmeticThreads
        self.surfaceFinish = surfaceFinish
        self.gdt = gdt
        self.detailViews = detailViews
        self.dimensions = dimensions
        self.deflection = deflection
    }
}

public enum AutoToggle: String, Codable, Sendable { case auto, none }

// MARK: - Sheet

public struct SheetSpec: Codable, Sendable {
    public var size: PaperSizeName
    public var orientation: OrientationName
    public var projection: ProjectionAngleName
    public var scale: ScaleSpec
    public var border: Bool?
    public var projectionSymbol: Bool?

    public init(size: PaperSizeName, orientation: OrientationName,
                projection: ProjectionAngleName, scale: ScaleSpec,
                border: Bool? = nil, projectionSymbol: Bool? = nil) {
        self.size = size; self.orientation = orientation
        self.projection = projection; self.scale = scale
        self.border = border; self.projectionSymbol = projectionSymbol
    }
}

public enum PaperSizeName: String, Codable, Sendable {
    case a0, a1, a2, a3, a4
    public var upstream: PaperSize {
        switch self {
        case .a0: return .A0
        case .a1: return .A1
        case .a2: return .A2
        case .a3: return .A3
        case .a4: return .A4
        }
    }
}

public enum OrientationName: String, Codable, Sendable {
    case landscape, portrait
    public var upstream: Orientation {
        switch self {
        case .landscape: return .landscape
        case .portrait:  return .portrait
        }
    }
}

public enum ProjectionAngleName: String, Codable, Sendable {
    case first, third
    public var upstream: ProjectionAngle {
        switch self {
        case .first: return .first
        case .third: return .third
        }
    }
}

public enum ScaleSpec: Codable, Equatable, Sendable {
    case auto
    case ratio(numerator: Double, denominator: Double)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "auto" { self = .auto; return }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "invalid scale: \(raw)")
        }
        self = .ratio(numerator: parts[0], denominator: parts[1])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .ratio(let n, let d): try c.encode("\(n):\(d)")
        }
    }

    /// Multiplier from model units → drawing-paper units (mm).
    public var multiplier: Double {
        switch self {
        case .auto: return 1.0
        case .ratio(let n, let d): return n / d
        }
    }
}

// MARK: - Title block

public struct TitleBlockSpec: Codable, Sendable {
    public var title: String
    public var drawingNumber: String?
    public var owner: String?
    public var creator: String?
    public var approver: String?
    public var documentType: String?
    public var dateOfIssue: String?
    public var revision: String?
    public var sheetNumber: String?
    public var language: String?
    public var material: String?
    public var weight: String?

    public init(title: String,
                drawingNumber: String? = nil,
                owner: String? = nil,
                creator: String? = nil,
                approver: String? = nil,
                documentType: String? = nil,
                dateOfIssue: String? = nil,
                revision: String? = nil,
                sheetNumber: String? = nil,
                language: String? = nil,
                material: String? = nil,
                weight: String? = nil) {
        self.title = title
        self.drawingNumber = drawingNumber
        self.owner = owner; self.creator = creator
        self.approver = approver; self.documentType = documentType
        self.dateOfIssue = dateOfIssue; self.revision = revision
        self.sheetNumber = sheetNumber; self.language = language
        self.material = material; self.weight = weight
    }

    public func upstream(scale: String) -> TitleBlock {
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

public struct ViewSpec: Codable, Sendable {
    public var name: String
    public var direction: [Double]?

    public init(name: String, direction: [Double]? = nil) {
        self.name = name; self.direction = direction
    }
}

public struct SectionSpec: Codable, Sendable {
    public var name: String
    public var plane: PlaneSpec
    public var labelOnView: String?
    public var viewDirection: [Double]?
    public var hatchAngle: Double?                          // radians, default π/4
    public var hatchSpacing: Double?                        // mm, default 3

    public init(name: String, plane: PlaneSpec,
                labelOnView: String? = nil,
                viewDirection: [Double]? = nil,
                hatchAngle: Double? = nil,
                hatchSpacing: Double? = nil) {
        self.name = name; self.plane = plane
        self.labelOnView = labelOnView; self.viewDirection = viewDirection
        self.hatchAngle = hatchAngle; self.hatchSpacing = hatchSpacing
    }
}

public struct PlaneSpec: Codable, Sendable {
    public var origin: [Double]
    public var normal: [Double]

    public init(origin: [Double], normal: [Double]) {
        self.origin = origin; self.normal = normal
    }
}

// MARK: - Annotations

public enum CentermarkRequest: Codable, Sendable {
    case auto
    case off
    case explicit([CentermarkSpec])

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .off: try c.encode("none")
        case .explicit(let xs): try c.encode(xs)
        }
    }
}

public struct CentermarkSpec: Codable, Sendable {
    public var view: String
    public var x: Double
    public var y: Double
    public var extent: Double?

    public init(view: String, x: Double, y: Double, extent: Double? = nil) {
        self.view = view; self.x = x; self.y = y; self.extent = extent
    }
}

public struct CosmeticThreadSpec: Codable, Sendable {
    public var view: String
    public var axisStart: [Double]
    public var axisEnd: [Double]
    public var majorDiameter: Double
    public var pitch: Double
    public var callout: String?

    public init(view: String, axisStart: [Double], axisEnd: [Double],
                majorDiameter: Double, pitch: Double, callout: String? = nil) {
        self.view = view; self.axisStart = axisStart; self.axisEnd = axisEnd
        self.majorDiameter = majorDiameter; self.pitch = pitch; self.callout = callout
    }
}

public struct SurfaceFinishSpec: Codable, Sendable {
    public var view: String
    public var position: [Double]
    public var leaderTo: [Double]
    public var ra: Double
    public var symbol: String?                              // any | machiningRequired | machiningProhibited
    public var method: String?

    public init(view: String, position: [Double], leaderTo: [Double],
                ra: Double, symbol: String? = nil, method: String? = nil) {
        self.view = view; self.position = position; self.leaderTo = leaderTo
        self.ra = ra; self.symbol = symbol; self.method = method
    }
}

public struct GDTSpec: Codable, Sendable {
    public var view: String
    public var position: [Double]
    public var symbol: String                               // perpendicularity | flatness | …
    public var tolerance: String
    public var datums: [String]?
    public var leaderTo: [Double]?

    public init(view: String, position: [Double], symbol: String, tolerance: String,
                datums: [String]? = nil, leaderTo: [Double]? = nil) {
        self.view = view; self.position = position; self.symbol = symbol
        self.tolerance = tolerance; self.datums = datums; self.leaderTo = leaderTo
    }
}

public struct DetailViewSpec: Codable, Sendable {
    public var name: String
    public var fromView: String
    public var centre: [Double]
    public var radius: Double
    public var scale: Double
    public var placement: [Double]?

    public init(name: String, fromView: String, centre: [Double], radius: Double,
                scale: Double, placement: [Double]? = nil) {
        self.name = name; self.fromView = fromView; self.centre = centre
        self.radius = radius; self.scale = scale; self.placement = placement
    }
}

// MARK: - Dimensions

public struct DimensionSpec: Codable, Sendable {
    public var view: String
    public var type: DimensionKind
    public var from: [Double]?
    public var to: [Double]?
    public var offset: Double?
    public var centre: [Double]?
    public var radius: Double?
    public var leaderAngle: Double?
    public var vertex: [Double]?
    public var ray1: [Double]?
    public var ray2: [Double]?
    public var arcRadius: Double?
    public var label: String?

    public init(view: String, type: DimensionKind,
                from: [Double]? = nil, to: [Double]? = nil, offset: Double? = nil,
                centre: [Double]? = nil, radius: Double? = nil, leaderAngle: Double? = nil,
                vertex: [Double]? = nil, ray1: [Double]? = nil, ray2: [Double]? = nil,
                arcRadius: Double? = nil, label: String? = nil) {
        self.view = view; self.type = type
        self.from = from; self.to = to; self.offset = offset
        self.centre = centre; self.radius = radius; self.leaderAngle = leaderAngle
        self.vertex = vertex; self.ray1 = ray1; self.ray2 = ray2
        self.arcRadius = arcRadius; self.label = label
    }
}

public enum DimensionKind: String, Codable, Sendable {
    case linear, radial, diameter, angular
}
