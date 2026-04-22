// SectionExtraction.swift
// Slice a 3D shape with a plane (Shape.sectionWithPlane) and project the
// resulting 3D edges into the cutting plane's own 2D frame, so the contour
// can be laid out as a section view on the sheet.
//
// OCCTSwift's `Shape.sectionWithPlane(normal:origin:)` returns 3D edges in
// world space. To draw the section view, we need (u, v) coordinates in the
// plane. We construct a right-handed orthonormal basis (u, v) for the plane
// and transform each polyline point with p · u, p · v.
//
// FILED UPSTREAM: a future `Shape.section2D(plane:) -> Drawing` would let us
// drop this whole file in favour of a single OCCTSwift call.

import Foundation
import OCCTSwift
import simd

struct SectionResult {
    let polylines: [[SIMD2<Double>]]                        // contour in plane 2D
    let bounds: (min: SIMD2<Double>, max: SIMD2<Double>)?
    let basis: PlaneBasis
}

struct PlaneBasis {
    let origin: SIMD3<Double>
    let normal: SIMD3<Double>
    let u: SIMD3<Double>            // in-plane right
    let v: SIMD3<Double>            // in-plane up
}

enum SectionExtraction {

    /// Build a plane basis from origin + normal, choosing an `u` axis
    /// orthogonal to the normal and aligned (where possible) with the world
    /// horizontal.
    static func basis(origin: SIMD3<Double>, normal: SIMD3<Double>) -> PlaneBasis {
        let n = simd_normalize(normal)
        var u = simd_cross(SIMD3<Double>(0, 0, 1), n)
        if simd_length(u) < 1e-9 {
            u = simd_cross(SIMD3<Double>(0, 1, 0), n)
        }
        u = simd_normalize(u)
        let v = simd_normalize(simd_cross(n, u))
        return PlaneBasis(origin: origin, normal: n, u: u, v: v)
    }

    /// Slice `shape` with the plane and return the contour in plane 2D.
    /// Returns nil if the section is empty or fails.
    static func extract(_ shape: Shape,
                        plane: PlaneBasis,
                        deflection: Double) -> SectionResult? {
        guard let edges = shape.sectionWithPlane(normal: plane.normal, origin: plane.origin) else {
            return nil
        }
        let polys3D = edges.allEdgePolylines(deflection: deflection)
        guard !polys3D.isEmpty else { return nil }

        var polys2D: [[SIMD2<Double>]] = []
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for poly in polys3D {
            let mapped: [SIMD2<Double>] = poly.map { p in
                let d = SIMD3(p.x - plane.origin.x, p.y - plane.origin.y, p.z - plane.origin.z)
                let uu = simd_dot(d, plane.u)
                let vv = simd_dot(d, plane.v)
                minX = min(minX, uu); maxX = max(maxX, uu)
                minY = min(minY, vv); maxY = max(maxY, vv)
                return SIMD2(uu, vv)
            }
            if mapped.count >= 2 { polys2D.append(mapped) }
        }
        guard !polys2D.isEmpty else { return nil }
        return SectionResult(
            polylines: polys2D,
            bounds: (SIMD2(minX, minY), SIMD2(maxX, maxY)),
            basis: plane
        )
    }

    /// Stage section polylines onto the writer at a given placement, on the
    /// VISIBLE layer (sections show what's "in" the cut as solid outlines —
    /// hatching is rendered separately when supported).
    static func place(_ result: SectionResult,
                      placement: ViewPlacement,
                      label: String,
                      writer: DXFWriter) {
        for poly in result.polylines {
            let pts = poly.map { placement.t($0) }
            if pts.count == 2 {
                writer.addLine(from: pts[0], to: pts[1], layer: "VISIBLE")
            } else {
                writer.addPolyline(pts, closed: false, layer: "VISIBLE")
            }
        }
        // Section title placed beneath the bbox: "SECTION A-A"
        if let bb = result.bounds {
            let titlePos = placement.t(SIMD2((bb.min.x + bb.max.x) / 2, bb.min.y - 5))
            writer.addText("SECTION \(label)-\(label)",
                           at: titlePos, height: 5.0, layer: "TEXT")
        }
    }
}

/// Render a cutting-plane line onto a parent view: heavy chain at endpoints,
/// thin chain in the middle, perpendicular arrows showing the viewing
/// direction, and a label letter at each arrow.
enum SectionMark {

    /// Draw a cutting-plane line on a view by intersecting the cutting plane
    /// with the view plane, producing a line in view 2D coordinates. The
    /// algorithm: project the cutting plane's origin and a point along its
    /// in-plane horizontal axis (u) onto the view plane, then extend through
    /// the view bounds.
    static func draw(label: String,
                     cuttingPlane: PlaneBasis,
                     onViewDirection viewDirection: SIMD3<Double>,
                     viewBounds: (min: SIMD2<Double>, max: SIMD2<Double>)?,
                     placement: ViewPlacement,
                     writer: DXFWriter) {
        // Compute the cutting plane's intersection with the view plane:
        //   intersection direction = cuttingPlane.normal × viewDirection
        // Reduce to 2D by projecting onto the view's natural 2D basis (the same
        // basis OCCTSwift's Drawing.project uses — see DrawingAutoCenterlines).
        let viewN = simd_normalize(viewDirection)
        var viewU = simd_cross(SIMD3<Double>(0, 0, 1), viewN)
        if simd_length(viewU) < 1e-9 {
            viewU = simd_cross(SIMD3<Double>(0, 1, 0), viewN)
        }
        viewU = simd_normalize(viewU)
        let viewV = simd_normalize(simd_cross(viewN, viewU))

        // Project cutting plane origin to view 2D.
        let o = cuttingPlane.origin
        let originView = SIMD2(simd_dot(o, viewU), simd_dot(o, viewV))

        // Direction of the cutting plane's trace in the view = projection of
        // the plane's u onto (viewU, viewV).
        let traceDir3D = simd_cross(cuttingPlane.normal, viewN)
        let traceLen = simd_length(traceDir3D)
        if traceLen < 1e-9 {
            // Cutting plane parallel to view plane: no visible trace
            return
        }
        let traceDir = SIMD2(simd_dot(traceDir3D, viewU), simd_dot(traceDir3D, viewV)) / traceLen

        // Extend along the trace through view bounds + a small overshoot.
        let bb = viewBounds ?? (SIMD2(-100, -100), SIMD2(100, 100))
        let extentU = max(bb.max.x - bb.min.x, bb.max.y - bb.min.y) + 20
        let p1 = SIMD2(originView.x - traceDir.x * extentU / 2,
                       originView.y - traceDir.y * extentU / 2)
        let p2 = SIMD2(originView.x + traceDir.x * extentU / 2,
                       originView.y + traceDir.y * extentU / 2)

        let s1 = placement.t(p1)
        let s2 = placement.t(p2)

        // Cutting plane line on CENTER layer (chain). DXF R12 has no line-weight
        // entity; the heavy/thin distinction is paper-only.
        writer.addLine(from: s1, to: s2, layer: "CENTER")

        // Arrows perpendicular to the trace, pointing in the section view direction.
        let perp2D = SIMD2(-traceDir.y, traceDir.x) * 6 * placement.scale
        writer.addLine(from: s1, to: SIMD2(s1.x + perp2D.x, s1.y + perp2D.y), layer: "CENTER")
        writer.addLine(from: s2, to: SIMD2(s2.x + perp2D.x, s2.y + perp2D.y), layer: "CENTER")

        // Letter labels at each end ("A", "A")
        writer.addText(label, at: SIMD2(s1.x + perp2D.x + 1, s1.y + perp2D.y + 1),
                       height: 5.0, layer: "TEXT")
        writer.addText(label, at: SIMD2(s2.x + perp2D.x + 1, s2.y + perp2D.y + 1),
                       height: 5.0, layer: "TEXT")
    }
}
