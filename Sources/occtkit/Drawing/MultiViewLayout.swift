// MultiViewLayout.swift
// Lay out orthographic views on a sheet per ISO 128-30 (first or third angle).
//
// Algorithm:
//   1. For each named view, derive a 3D direction (or use the spec's override).
//   2. Project the shape with `Drawing.project(...)` and compute the view's
//      2D bounding box from `visibleEdges`.
//   3. Pack the views around an anchor (the front view) per ISO 128-30
//      arrangement rules:
//         third-angle: top above front, right to right, left to left, etc.
//         first-angle: top below front, right to LEFT, left to RIGHT.
//   4. Apply the global drawing scale to all view bboxes; pick a uniform
//      view-to-view gutter to keep alignment readable.

import Foundation
import OCCTSwift
import simd

struct ViewItem {
    let name: String
    let direction: SIMD3<Double>
    let drawing: Drawing
    let bounds: (min: SIMD2<Double>, max: SIMD2<Double>)?
}

/// Standard view directions per ISO. These are the camera direction vectors —
/// i.e. the direction *from which the viewer is looking*. The HLR projection
/// uses the same convention: `Drawing.project(_:direction:)` projects onto the
/// plane perpendicular to `direction`.
enum StandardView: String {
    case front, back, top, bottom, left, right, isometric

    var direction: SIMD3<Double> {
        switch self {
        case .front:     return SIMD3( 0, -1,  0)   // looking +Y
        case .back:      return SIMD3( 0,  1,  0)
        case .top:       return SIMD3( 0,  0, -1)   // looking +Z
        case .bottom:    return SIMD3( 0,  0,  1)
        case .left:      return SIMD3(-1,  0,  0)
        case .right:     return SIMD3( 1,  0,  0)
        case .isometric: return simd_normalize(SIMD3(1.0, 1.0, 1.0))
        }
    }
}

enum MultiViewLayout {

    /// Project the shape per requested view and compute each view's 2D bounds.
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
                bounds: bounds(of: drawing, deflection: deflection)
            )
        }
    }

    static func direction(for spec: ViewSpec) -> SIMD3<Double> {
        if let d = spec.direction, d.count == 3 {
            return simd_normalize(SIMD3(d[0], d[1], d[2]))
        }
        return StandardView(rawValue: spec.name)?.direction ?? SIMD3(0, -1, 0)
    }

    /// 2D bounding box of all projected edges (visible + hidden + outline).
    static func bounds(of drawing: Drawing, deflection: Double) -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for layer in [drawing.visibleEdges, drawing.hiddenEdges, drawing.outlineEdges] {
            guard let compound = layer else { continue }
            for poly in compound.allEdgePolylines(deflection: deflection) {
                for p in poly {
                    minX = min(minX, p.x); minY = min(minY, p.y)
                    maxX = max(maxX, p.x); maxY = max(maxY, p.y)
                    any = true
                }
            }
        }
        if !any { return nil }
        return (SIMD2(minX, minY), SIMD2(maxX, maxY))
    }

    /// ISO 128-30 placement: position each view's local 2D origin on the sheet.
    /// `front` is the anchor; siblings are offset by their own + neighbour's
    /// half-bbox plus a fixed gutter. For unnamed/custom views we drop them
    /// horizontally to the right of the anchor (caller's responsibility to
    /// avoid collisions).
    ///
    /// Returns a dictionary view-name → ViewPlacement where the placement's
    /// `offset` is the sheet position for that view's coordinate-system origin.
    /// Drawing-units have already been multiplied by `scale`.
    static func place(items: [ViewItem],
                      angle: ProjectionAngle,
                      sheetCentre: SIMD2<Double>,
                      scale: Double,
                      gutter: Double = 25,
                      deflection: Double) -> [String: ViewPlacement] {
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        // Anchor = front. If no front view in the spec, pick the first item.
        guard let anchor = byName["front"] ?? items.first else { return [:] }
        let anchorBB = anchor.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
        let anchorW = (anchorBB.max.x - anchorBB.min.x) * scale
        let anchorH = (anchorBB.max.y - anchorBB.min.y) * scale

        // Anchor's offset: place the anchor's bbox centre at sheetCentre.
        let anchorOffset = SIMD2(
            sheetCentre.x - (anchorBB.min.x + anchorBB.max.x) / 2 * scale,
            sheetCentre.y - (anchorBB.min.y + anchorBB.max.y) / 2 * scale
        )

        var placements: [String: ViewPlacement] = [:]
        placements[anchor.name] = ViewPlacement(offset: anchorOffset, scale: scale, deflection: deflection)

        // Helper: place a view to the relative direction (dx, dy) of the anchor.
        // dx/dy ∈ {-1, 0, 1}. The placed view's *bbox centre* lands at
        //   anchorBboxCentreOnSheet + (dx*(anchorHalfW + gutter + viewHalfW),
        //                              dy*(anchorHalfH + gutter + viewHalfH))
        func placeRelative(_ name: String, dx: Double, dy: Double) {
            guard let v = byName[name], v.name != anchor.name else { return }
            let bb = v.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
            let w = (bb.max.x - bb.min.x) * scale
            let h = (bb.max.y - bb.min.y) * scale
            let centreX = sheetCentre.x + dx * (anchorW / 2 + gutter + w / 2)
            let centreY = sheetCentre.y + dy * (anchorH / 2 + gutter + h / 2)
            let off = SIMD2(
                centreX - (bb.min.x + bb.max.x) / 2 * scale,
                centreY - (bb.min.y + bb.max.y) / 2 * scale
            )
            placements[name] = ViewPlacement(offset: off, scale: scale, deflection: deflection)
        }

        // ISO 128-30 placement table. dx is horizontal sign (+ right, − left),
        // dy vertical (+ up, − down). Third-angle keeps the natural quadrant;
        // first-angle inverts horizontal & vertical.
        let isFirst = (angle == .first)
        // top: ABOVE for third, BELOW for first
        placeRelative("top",    dx: 0, dy: isFirst ? -1 :  1)
        placeRelative("bottom", dx: 0, dy: isFirst ?  1 : -1)
        // right: to the RIGHT for third, to the LEFT for first
        placeRelative("right",  dx: isFirst ? -1 :  1, dy: 0)
        placeRelative("left",   dx: isFirst ?  1 : -1, dy: 0)
        // back: same row, to the right of "left" (or left of "right"); for
        // simplicity, drop it diagonally upper-right.
        placeRelative("back",   dx: isFirst ? -2 :  2, dy: 0)
        // isometric: upper-right corner
        placeRelative("isometric", dx: 1, dy: 1)

        // Custom-named views: stack them column-wise to the right.
        var col = 2
        for v in items where placements[v.name] == nil {
            let bb = v.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
            let centreX = sheetCentre.x + Double(col) * (anchorW / 2 + gutter + (bb.max.x - bb.min.x) * scale / 2)
            let centreY = sheetCentre.y
            let off = SIMD2(
                centreX - (bb.min.x + bb.max.x) / 2 * scale,
                centreY - (bb.min.y + bb.max.y) / 2 * scale
            )
            placements[v.name] = ViewPlacement(offset: off, scale: scale, deflection: deflection)
            col += 1
        }
        return placements
    }
}
