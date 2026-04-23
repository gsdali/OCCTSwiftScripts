// Composer.swift
// Public entry point: turn a `DrawingSpec` + a live `Shape` into a fully
// populated `DXFWriter`. Same logic as the `occtkit drawing-export` CLI verb
// but takes geometry in-process — for iOS apps and library consumers that
// can't subprocess. Closes OCCTSwiftScripts#7.

import Foundation
import OCCTSwift
import simd

public enum DrawingComposerError: Error, LocalizedError {
    case noViewsProjected
    case shapeBuildFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noViewsProjected:
            return "No views projected — check the `views` array in the spec"
        case .shapeBuildFailed(let m):
            return m
        }
    }
}

public struct DrawingComposerResult: Sendable {
    public let writer: DXFWriter
    public let scaleLabel: String
    public let viewCount: Int
    public let sectionCount: Int
    public let detailCount: Int

    public init(writer: DXFWriter, scaleLabel: String,
                viewCount: Int, sectionCount: Int, detailCount: Int) {
        self.writer = writer; self.scaleLabel = scaleLabel
        self.viewCount = viewCount
        self.sectionCount = sectionCount; self.detailCount = detailCount
    }
}

public enum Composer {

    /// Compose a multi-view ISO drawing for `shape` per `spec` and return a
    /// populated `DXFWriter`. The caller writes the result with
    /// `try result.writer.write(to: url)`.
    ///
    /// Same logic as the `occtkit drawing-export` CLI verb, minus the BREP
    /// load and DXF write steps.
    public static func render(spec: DrawingSpec, shape: Shape) throws -> DrawingComposerResult {
        let deflection = spec.deflection ?? 0.1
        let projectionAngle = spec.sheet.projection.upstream
        let paperSize = spec.sheet.size.upstream
        let orientation = spec.sheet.orientation.upstream

        // Project all requested views, compute bounds.
        let items = MultiViewLayout.project(shape, views: spec.views, deflection: deflection)
        guard !items.isEmpty else { throw DrawingComposerError.noViewsProjected }

        // Determine drawing scale (ISO 5455 snapped if "auto").
        let sheetSize = paperSize.size(in: orientation)
        let drawableArea = (width: sheetSize.x - 30, height: sheetSize.y - 80)
        let drawScale = chooseScale(spec.sheet.scale, items: items, drawableArea: drawableArea)
        let scaleLabel = formatDrawingScale(drawScale)

        // Sheet (border + title block + projection symbol) via upstream.
        let sheet = Sheet(size: paperSize,
                          orientation: orientation,
                          projection: projectionAngle,
                          title: spec.title?.upstream(scale: scaleLabel),
                          scale: scaleLabel)

        let writer = DXFWriter(deflection: deflection)
        if spec.sheet.border ?? true {
            sheet.render(into: writer)
        }

        // Place views around drawing-area centre (above the title block).
        let inner = sheet.innerFrame
        let centre = SIMD2((inner.min.x + inner.max.x) / 2,
                           inner.min.y + (inner.max.y - inner.min.y - 60) / 2 + 60)
        let placed = MultiViewLayout.place(items: items,
                                           angle: projectionAngle,
                                           sheetCentre: centre,
                                           scale: drawScale)

        // Per-view annotations.
        applyCenterAnnotations(items: items, shape: shape, spec: spec)
        applyManualAnnotations(items: items, spec: spec)

        // Render each view onto the writer at its placement.
        for item in items {
            guard let p = placed[item.name] else { continue }
            writer.collectFromDrawing(item.drawing.transformed(
                translate: p.translate, scale: p.scale))
            if let bb = item.bounds {
                let centreX = (bb.min.x + bb.max.x) / 2
                let yBelow = bb.min.y - 5
                let labelPos = SIMD2(centreX * p.scale + p.translate.x,
                                     yBelow * p.scale + p.translate.y)
                writer.addText(item.name.uppercased(),
                               at: labelPos, height: 4.0, layer: "TEXT")
            }
        }

        // Section views (auto-hatched, labelled).
        var sectionsRendered = 0
        var stackedY = inner.max.y - 80
        let sectionStackX = inner.max.x - 80
        for sec in spec.sections ?? [] {
            guard sec.plane.origin.count == 3, sec.plane.normal.count == 3 else { continue }
            let origin = SIMD3(sec.plane.origin[0], sec.plane.origin[1], sec.plane.origin[2])
            let normal = SIMD3(sec.plane.normal[0], sec.plane.normal[1], sec.plane.normal[2])
            guard let secView = shape.section2DView(planeOrigin: origin,
                                                     planeNormal: normal,
                                                     label: sec.name,
                                                     hatchAngle: sec.hatchAngle ?? .pi / 4,
                                                     hatchSpacing: sec.hatchSpacing ?? 3,
                                                     deflection: deflection) else {
                continue
            }
            let bb = secView.drawing.bounds(deflection: deflection) ?? (SIMD2(-50, -50), SIMD2(50, 50))
            let w = (bb.max.x - bb.min.x) * drawScale
            let h = (bb.max.y - bb.min.y) * drawScale
            let cx = sectionStackX - w / 2
            let cy = stackedY - h / 2
            let tr = SIMD2(cx - (bb.min.x + bb.max.x) / 2 * drawScale,
                           cy - (bb.min.y + bb.max.y) / 2 * drawScale)
            writer.collectFromDrawing(secView.drawing.transformed(
                translate: tr, scale: drawScale))
            stackedY -= (h + 30)

            if let parentName = sec.labelOnView,
               let parent = items.first(where: { $0.name == parentName }) {
                _ = parent.drawing.addCuttingPlaneLine(
                    label: sec.name,
                    cuttingPlaneOrigin: origin,
                    cuttingPlaneNormal: normal,
                    sectionViewDirection: SIMD3(sec.viewDirection?[0] ?? normal.x,
                                                 sec.viewDirection?[1] ?? normal.y,
                                                 sec.viewDirection?[2] ?? normal.z),
                    viewDirection: parent.direction
                )
                if let parentPlaced = placed[parentName] {
                    writer.collectFromDrawing(parent.drawing.transformed(
                        translate: parentPlaced.translate, scale: parentPlaced.scale))
                }
            }
            sectionsRendered += 1
        }

        // Detail views.
        var detailsRendered = 0
        for d in spec.detailViews ?? [] {
            guard d.centre.count == 2,
                  let parent = items.first(where: { $0.name == d.fromView }) else { continue }
            let placement = SIMD2(d.placement?[0] ?? sectionStackX - 40,
                                   d.placement?[1] ?? stackedY - 40)
            let detail = parent.drawing.detailView(at: placement, scale: d.scale)
            writer.collectFromDrawing(detail)
            writer.addText("DETAIL \(d.name) (\(formatDrawingScale(d.scale)))",
                           at: SIMD2(placement.x, placement.y - 5),
                           height: 3.5, layer: "TEXT")
            stackedY -= 60
            detailsRendered += 1
        }

        return DrawingComposerResult(
            writer: writer, scaleLabel: scaleLabel,
            viewCount: items.count,
            sectionCount: sectionsRendered,
            detailCount: detailsRendered
        )
    }

    // MARK: - Annotation application

    static func applyCenterAnnotations(items: [ViewItem], shape: Shape, spec: DrawingSpec) {
        if (spec.centerlines ?? .auto) == .auto {
            for item in items {
                _ = item.drawing.addAutoCentrelines(
                    from: shape,
                    viewDirection: item.direction,
                    overshoot: 5,
                    tolerance: 1e-6,
                    bounds: item.bounds
                )
            }
        }
        switch spec.centermarks ?? .auto {
        case .auto:
            for item in items {
                _ = item.drawing.addAutoCentermarks(
                    from: shape,
                    viewDirection: item.direction,
                    extent: 8, minRadius: 0,
                    bounds: item.bounds
                )
            }
        case .off:
            break
        case .explicit(let xs):
            let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
            for cm in xs {
                guard let item = byName[cm.view] else { continue }
                item.drawing.addCentermark(centre: SIMD2(cm.x, cm.y),
                                           extent: cm.extent ?? 8)
            }
        }
    }

    static func applyManualAnnotations(items: [ViewItem], spec: DrawingSpec) {
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        for ct in spec.cosmeticThreads ?? [] {
            guard let item = byName[ct.view],
                  ct.axisStart.count == 2, ct.axisEnd.count == 2 else { continue }
            _ = item.drawing.addCosmeticThreadSide(
                axisStart: SIMD2(ct.axisStart[0], ct.axisStart[1]),
                axisEnd:   SIMD2(ct.axisEnd[0],   ct.axisEnd[1]),
                majorDiameter: ct.majorDiameter,
                pitch: ct.pitch,
                callout: ct.callout
            )
        }

        for sf in spec.surfaceFinish ?? [] {
            guard let item = byName[sf.view],
                  sf.position.count == 2, sf.leaderTo.count == 2 else { continue }
            let symbol = SurfaceFinishSymbol(rawValue: sf.symbol ?? "machiningRequired")
                         ?? .machiningRequired
            replay(DrawingAnnotation.surfaceFinish(
                at: SIMD2(sf.position[0], sf.position[1]),
                leaderTo: SIMD2(sf.leaderTo[0], sf.leaderTo[1]),
                ra: sf.ra, symbol: symbol, method: sf.method
            ), on: item.drawing)
        }

        for g in spec.gdt ?? [] {
            guard let item = byName[g.view], g.position.count == 2,
                  let symbol = GDTSymbol(rawValue: g.symbol) else { continue }
            let leader = g.leaderTo.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
            replay(DrawingAnnotation.featureControlFrame(
                at: SIMD2(g.position[0], g.position[1]),
                symbol: symbol, tolerance: g.tolerance,
                datums: g.datums ?? [], leaderTo: leader
            ), on: item.drawing)
        }

        for d in spec.dimensions ?? [] {
            guard let item = byName[d.view] else { continue }
            switch d.type {
            case .linear:
                guard let f = d.from, f.count == 2, let t = d.to, t.count == 2 else { continue }
                item.drawing.addLinearDimension(from: SIMD2(f[0], f[1]),
                                                to: SIMD2(t[0], t[1]),
                                                offset: d.offset ?? 10, label: d.label)
            case .radial:
                guard let c = d.centre, c.count == 2, let r = d.radius else { continue }
                item.drawing.addRadialDimension(centre: SIMD2(c[0], c[1]), radius: r,
                                                leaderAngle: d.leaderAngle ?? .pi / 4,
                                                label: d.label)
            case .diameter:
                guard let c = d.centre, c.count == 2, let r = d.radius else { continue }
                item.drawing.addDiameterDimension(centre: SIMD2(c[0], c[1]), radius: r,
                                                  leaderAngle: d.leaderAngle ?? .pi / 4,
                                                  label: d.label)
            case .angular:
                guard let v = d.vertex, v.count == 2,
                      let r1 = d.ray1, r1.count == 2,
                      let r2 = d.ray2, r2.count == 2 else { continue }
                item.drawing.addAngularDimension(vertex: SIMD2(v[0], v[1]),
                                                 ray1: SIMD2(r1[0], r1[1]),
                                                 ray2: SIMD2(r2[0], r2[1]),
                                                 arcRadius: d.arcRadius ?? 20,
                                                 label: d.label)
            }
        }
    }

    /// Re-emit a list of `DrawingAnnotation` onto a `Drawing` via its typed
    /// add-* methods. Workaround for the absence of public
    /// `Drawing.appendAnnotation(_:)` — see OCCTSwift#83.
    static func replay(_ anns: [DrawingAnnotation], on drawing: Drawing) {
        for ann in anns {
            switch ann {
            case .centreline(let c):
                drawing.addCentreLine(from: c.from, to: c.to, style: c.style, id: c.id)
            case .centermark(let m):
                drawing.addCentermark(centre: m.centre, extent: m.extent, style: m.style, id: m.id)
            case .textLabel(let t):
                drawing.addTextLabel(t.text, at: t.position, height: t.height,
                                     rotation: t.rotation, id: t.id)
            case .hatch, .cuttingPlaneLine:
                break
            }
        }
    }

    // MARK: - Scale (ISO 5455)

    static func chooseScale(_ requested: ScaleSpec,
                             items: [ViewItem],
                             drawableArea: (width: Double, height: Double)) -> Double {
        if case .ratio = requested { return requested.multiplier }
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        let front = byName["front"] ?? items[0]
        let frontBB = front.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
        let frontW = frontBB.max.x - frontBB.min.x
        let frontH = frontBB.max.y - frontBB.min.y
        let topH = byName["top"]?.bounds.map { $0.max.y - $0.min.y } ?? 0
        let bottomH = byName["bottom"]?.bounds.map { $0.max.y - $0.min.y } ?? 0
        let leftW = byName["left"]?.bounds.map { $0.max.x - $0.min.x } ?? 0
        let rightW = byName["right"]?.bounds.map { $0.max.x - $0.min.x } ?? 0
        let totalW = leftW + frontW + rightW + 50
        let totalH = topH + frontH + bottomH + 50
        let limitW = drawableArea.width / max(totalW, 1)
        let limitH = drawableArea.height / max(totalH, 1)
        let raw = min(limitW, limitH)
        for s in DrawingScale.preferred where s.factor <= raw { return s.factor }
        return DrawingScale.preferred.last?.factor ?? raw
    }

    static func formatDrawingScale(_ multiplier: Double) -> String {
        for s in DrawingScale.preferred where abs(s.factor - multiplier) < 1e-6 {
            return s.label
        }
        return DrawingScale.custom(multiplier).label
    }
}
