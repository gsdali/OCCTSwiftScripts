// MultiViewLayout.swift
// Lay out orthographic views on a sheet per ISO 128-30 (first or third angle).
// Layout math only — projection / bounds / placement transforms come from
// OCCTSwift v0.147 (`Drawing.project`, `Drawing.bounds`, `Drawing.transformed`).

import Foundation
import OCCTSwift
import simd

struct ViewItem {
    let name: String
    let direction: SIMD3<Double>
    let drawing: Drawing
    let bounds: (min: SIMD2<Double>, max: SIMD2<Double>)?
}

struct PlacedView {
    let item: ViewItem
    let translate: SIMD2<Double>
    let scale: Double
}

/// Standard view directions per ISO 128-30. Camera direction = the direction
/// the viewer is looking *along*. `Drawing.project(_:direction:)` consumes
/// the same convention.
enum StandardView: String {
    case front, back, top, bottom, left, right, isometric

    var direction: SIMD3<Double> {
        switch self {
        case .front:     return SIMD3( 0, -1,  0)
        case .back:      return SIMD3( 0,  1,  0)
        case .top:       return SIMD3( 0,  0, -1)
        case .bottom:    return SIMD3( 0,  0,  1)
        case .left:      return SIMD3(-1,  0,  0)
        case .right:     return SIMD3( 1,  0,  0)
        case .isometric: return simd_normalize(SIMD3(1.0, 1.0, 1.0))
        }
    }
}

enum MultiViewLayout {

    static func project(_ shape: Shape,
                        views: [ViewSpec],
                        deflection: Double) -> [ViewItem] {
        views.compactMap { spec in
            let dir = direction(for: spec)
            guard let drawing = Drawing.project(shape, direction: dir) else { return nil }
            return ViewItem(
                name: spec.name,
                direction: dir,
                drawing: drawing,
                bounds: drawing.bounds(deflection: deflection)
            )
        }
    }

    static func direction(for spec: ViewSpec) -> SIMD3<Double> {
        if let d = spec.direction, d.count == 3 {
            return simd_normalize(SIMD3(d[0], d[1], d[2]))
        }
        return StandardView(rawValue: spec.name)?.direction ?? SIMD3(0, -1, 0)
    }

    /// Place views on the sheet around the front-view anchor per ISO 128-30.
    /// Returns each view's `(translate, scale)` for `Drawing.transformed`.
    static func place(items: [ViewItem],
                      angle: ProjectionAngle,
                      sheetCentre: SIMD2<Double>,
                      scale: Double,
                      gutter: Double = 25) -> [String: PlacedView] {
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        guard let anchor = byName["front"] ?? items.first else { return [:] }
        let anchorBB = anchor.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
        let anchorW = (anchorBB.max.x - anchorBB.min.x) * scale
        let anchorH = (anchorBB.max.y - anchorBB.min.y) * scale

        var placed: [String: PlacedView] = [:]
        let anchorTranslate = SIMD2(
            sheetCentre.x - (anchorBB.min.x + anchorBB.max.x) / 2 * scale,
            sheetCentre.y - (anchorBB.min.y + anchorBB.max.y) / 2 * scale
        )
        placed[anchor.name] = PlacedView(item: anchor, translate: anchorTranslate, scale: scale)

        func placeRelative(_ name: String, dx: Double, dy: Double) {
            guard let v = byName[name], v.name != anchor.name else { return }
            let bb = v.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
            let w = (bb.max.x - bb.min.x) * scale
            let h = (bb.max.y - bb.min.y) * scale
            let cx = sheetCentre.x + dx * (anchorW / 2 + gutter + w / 2)
            let cy = sheetCentre.y + dy * (anchorH / 2 + gutter + h / 2)
            let tr = SIMD2(
                cx - (bb.min.x + bb.max.x) / 2 * scale,
                cy - (bb.min.y + bb.max.y) / 2 * scale
            )
            placed[name] = PlacedView(item: v, translate: tr, scale: scale)
        }

        // First-angle inverts axes relative to third-angle.
        let isFirst = (angle == .first)
        placeRelative("top",       dx: 0, dy: isFirst ? -1 :  1)
        placeRelative("bottom",    dx: 0, dy: isFirst ?  1 : -1)
        placeRelative("right",     dx: isFirst ? -1 :  1, dy: 0)
        placeRelative("left",      dx: isFirst ?  1 : -1, dy: 0)
        placeRelative("back",      dx: isFirst ? -2 :  2, dy: 0)
        placeRelative("isometric", dx: 1, dy: 1)

        // Custom-named views: stack to the right.
        var col = 2
        for v in items where placed[v.name] == nil {
            let bb = v.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
            let cx = sheetCentre.x + Double(col) * (anchorW / 2 + gutter + (bb.max.x - bb.min.x) * scale / 2)
            let cy = sheetCentre.y
            let tr = SIMD2(
                cx - (bb.min.x + bb.max.x) / 2 * scale,
                cy - (bb.min.y + bb.max.y) / 2 * scale
            )
            placed[v.name] = PlacedView(item: v, translate: tr, scale: scale)
            col += 1
        }
        return placed
    }
}
