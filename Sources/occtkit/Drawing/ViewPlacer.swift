// ViewPlacer.swift
// Render a Drawing's projected edges, annotations, and dimensions into a
// DXFWriter at a given sheet offset + uniform scale.
//
// We re-implement the bits of OCCTSwift's `DXFWriter.collectFromDrawing` that
// we need rather than calling it directly, because that helper has no
// transform/offset hook — it always emits geometry at the drawing's intrinsic
// 2D coordinates. ISSUE filed upstream to add `Drawing.translated(by:scale:)`
// (or a `DXFWriter.collectFromDrawing(drawing:transform:)` overload) so this
// re-implementation can eventually go away.

import Foundation
import OCCTSwift
import simd

struct ViewPlacement {
    let offset: SIMD2<Double>            // sheet position of the view's intrinsic origin
    let scale: Double                    // model-units → mm multiplier (e.g. 0.5 for 1:2)
    let deflection: Double               // tessellation deflection for edge polylines

    func t(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(p.x * scale + offset.x, p.y * scale + offset.y)
    }

    func t(_ p: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(p.x * scale + offset.x, p.y * scale + offset.y)
    }
}

enum ViewPlacer {

    /// Render `drawing`'s edges + annotations + dimensions into `writer` at the
    /// given placement. Edge layers map to: visible→VISIBLE (continuous),
    /// hidden→HIDDEN (dashed), outline→OUTLINE.
    static func place(_ drawing: Drawing,
                      placement: ViewPlacement,
                      into writer: DXFWriter) {
        placeEdges(drawing.visibleEdges, layer: "VISIBLE", placement: placement, writer: writer)
        placeEdges(drawing.hiddenEdges,  layer: "HIDDEN",  placement: placement, writer: writer)
        placeEdges(drawing.outlineEdges, layer: "OUTLINE", placement: placement, writer: writer)
        placeAnnotations(drawing.annotations, placement: placement, writer: writer)
        placeDimensions(drawing.dimensions,   placement: placement, writer: writer)
    }

    private static func placeEdges(_ compound: Shape?,
                                   layer: String,
                                   placement: ViewPlacement,
                                   writer: DXFWriter) {
        guard let compound else { return }
        let polys = compound.allEdgePolylines(deflection: placement.deflection)
        for poly in polys {
            guard poly.count >= 2 else { continue }
            let pts = poly.map { placement.t($0) }
            if pts.count == 2 {
                writer.addLine(from: pts[0], to: pts[1], layer: layer)
            } else {
                writer.addPolyline(pts, closed: false, layer: layer)
            }
        }
    }

    private static func placeAnnotations(_ anns: [DrawingAnnotation],
                                         placement: ViewPlacement,
                                         writer: DXFWriter) {
        for ann in anns {
            switch ann {
            case .centreline(let c):
                writer.addLine(from: placement.t(c.from), to: placement.t(c.to), layer: "CENTER")
            case .centermark(let m):
                let h = m.extent * placement.scale / 2
                let c = placement.t(m.centre)
                writer.addLine(from: SIMD2(c.x - h, c.y), to: SIMD2(c.x + h, c.y), layer: "CENTER")
                writer.addLine(from: SIMD2(c.x, c.y - h), to: SIMD2(c.x, c.y + h), layer: "CENTER")
            case .textLabel(let t):
                writer.addText(t.text, at: placement.t(t.position),
                               height: t.height, rotationDeg: t.rotation * 180 / .pi, layer: "TEXT")
            }
        }
    }

    // MARK: - Dimensions
    //
    // Minimal ISO 129-style rendering: extension lines, dimension line, arrows,
    // text. Re-implements what `DXFExporter.collectDimensions` does, with the
    // transform applied. Linear dimensions are common; radial, diameter, and
    // angular are simpler "leader + label" forms here (full ISO conformance is
    // a follow-up — file upstream issue for richer dimension primitives).

    private static func placeDimensions(_ dims: [DrawingDimension],
                                        placement: ViewPlacement,
                                        writer: DXFWriter) {
        for dim in dims {
            switch dim {
            case .linear(let lin):   placeLinear(lin, placement: placement, writer: writer)
            case .radial(let rad):   placeRadial(rad, placement: placement, writer: writer)
            case .diameter(let dia): placeDiameter(dia, placement: placement, writer: writer)
            case .angular(let ang):  placeAngular(ang, placement: placement, writer: writer)
            }
        }
    }

    private static func placeLinear(_ lin: DrawingDimension.Linear,
                                    placement p: ViewPlacement,
                                    writer: DXFWriter) {
        let from = p.t(lin.from)
        let to   = p.t(lin.to)
        let baseDir = simd_normalize(SIMD2(to.x - from.x, to.y - from.y))
        // Perpendicular, rotated +90° (left-handed for "above")
        let perp = SIMD2(-baseDir.y, baseDir.x)
        let off = lin.offset * p.scale
        let dimFrom = SIMD2(from.x + perp.x * off, from.y + perp.y * off)
        let dimTo   = SIMD2(to.x   + perp.x * off, to.y   + perp.y * off)

        // Extension lines (extend slightly beyond the dimension line)
        let ext = SIMD2(perp.x * 2, perp.y * 2)
        writer.addLine(from: from,
                       to:   SIMD2(dimFrom.x + ext.x, dimFrom.y + ext.y),
                       layer: "DIMENSION")
        writer.addLine(from: to,
                       to:   SIMD2(dimTo.x + ext.x, dimTo.y + ext.y),
                       layer: "DIMENSION")
        // Dimension line
        writer.addLine(from: dimFrom, to: dimTo, layer: "DIMENSION")
        // Arrowheads
        addArrow(at: dimFrom, along: SIMD2(-baseDir.x, -baseDir.y), writer: writer)
        addArrow(at: dimTo,   along: baseDir, writer: writer)
        // Text at midpoint, slightly offset perp away from the geometry
        let mid = SIMD2((dimFrom.x + dimTo.x) / 2, (dimFrom.y + dimTo.y) / 2)
        let label = lin.label ?? formattedLength(simd_length(SIMD2(to.x - from.x, to.y - from.y)) / p.scale)
        writer.addText(label,
                       at: SIMD2(mid.x + perp.x * 1.5, mid.y + perp.y * 1.5),
                       height: 3.5, layer: "TEXT")
    }

    private static func placeRadial(_ rad: DrawingDimension.Radial,
                                    placement p: ViewPlacement,
                                    writer: DXFWriter) {
        let centre = p.t(rad.centre)
        let r = rad.radius * p.scale
        let dir = SIMD2(cos(rad.leaderAngle), sin(rad.leaderAngle))
        let onCircle = SIMD2(centre.x + dir.x * r, centre.y + dir.y * r)
        let leaderEnd = SIMD2(centre.x + dir.x * (r + 8), centre.y + dir.y * (r + 8))
        writer.addLine(from: onCircle, to: leaderEnd, layer: "DIMENSION")
        addArrow(at: onCircle, along: SIMD2(-dir.x, -dir.y), writer: writer)
        let label = rad.label ?? "R\(formattedLength(rad.radius))"
        writer.addText(label, at: SIMD2(leaderEnd.x + 1, leaderEnd.y + 1), height: 3.5, layer: "TEXT")
    }

    private static func placeDiameter(_ dia: DrawingDimension.Diameter,
                                      placement p: ViewPlacement,
                                      writer: DXFWriter) {
        let centre = p.t(dia.centre)
        let r = dia.radius * p.scale
        let dir = SIMD2(cos(dia.leaderAngle), sin(dia.leaderAngle))
        let near = SIMD2(centre.x - dir.x * r, centre.y - dir.y * r)
        let far  = SIMD2(centre.x + dir.x * r, centre.y + dir.y * r)
        let leaderEnd = SIMD2(far.x + dir.x * 8, far.y + dir.y * 8)
        writer.addLine(from: near, to: leaderEnd, layer: "DIMENSION")
        addArrow(at: near, along: dir, writer: writer)
        addArrow(at: far,  along: SIMD2(-dir.x, -dir.y), writer: writer)
        let label = dia.label ?? "Ø\(formattedLength(dia.radius * 2))"
        writer.addText(label, at: SIMD2(leaderEnd.x + 1, leaderEnd.y + 1), height: 3.5, layer: "TEXT")
    }

    private static func placeAngular(_ ang: DrawingDimension.Angular,
                                     placement p: ViewPlacement,
                                     writer: DXFWriter) {
        let vertex = p.t(ang.vertex)
        let r1 = SIMD2(ang.ray1.x - ang.vertex.x, ang.ray1.y - ang.vertex.y)
        let r2 = SIMD2(ang.ray2.x - ang.vertex.x, ang.ray2.y - ang.vertex.y)
        let a1 = atan2(r1.y, r1.x)
        let a2 = atan2(r2.y, r2.x)
        let r = ang.arcRadius * p.scale
        writer.addArc(centre: vertex, radius: r,
                      startAngleDeg: a1 * 180 / .pi,
                      endAngleDeg: a2 * 180 / .pi,
                      layer: "DIMENSION")
        // Extension rays from vertex
        writer.addLine(from: vertex,
                       to: SIMD2(vertex.x + cos(a1) * (r + 4), vertex.y + sin(a1) * (r + 4)),
                       layer: "DIMENSION")
        writer.addLine(from: vertex,
                       to: SIMD2(vertex.x + cos(a2) * (r + 4), vertex.y + sin(a2) * (r + 4)),
                       layer: "DIMENSION")
        let mid = (a1 + a2) / 2
        let textPos = SIMD2(vertex.x + cos(mid) * (r + 4), vertex.y + sin(mid) * (r + 4))
        let degrees = abs(a2 - a1) * 180 / .pi
        let label = ang.label ?? String(format: "%.1f°", degrees)
        writer.addText(label, at: textPos, height: 3.5, layer: "TEXT")
    }

    // 3 mm filled-style arrow approximated with two short lines (DXF R12 has
    // no native arrowhead entity; CAD apps will see the dimension line + V).
    private static func addArrow(at tip: SIMD2<Double>,
                                 along dir: SIMD2<Double>,
                                 writer: DXFWriter) {
        let len: Double = 3
        let half: Double = 1
        let perp = SIMD2(-dir.y, dir.x)
        let base = SIMD2(tip.x - dir.x * len, tip.y - dir.y * len)
        writer.addLine(from: tip,
                       to: SIMD2(base.x + perp.x * half, base.y + perp.y * half),
                       layer: "DIMENSION")
        writer.addLine(from: tip,
                       to: SIMD2(base.x - perp.x * half, base.y - perp.y * half),
                       layer: "DIMENSION")
    }

    private static func formattedLength(_ v: Double) -> String {
        // Drop trailing zeros, sensible precision for engineering dims (mm).
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        f.minimumFractionDigits = 0
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}
