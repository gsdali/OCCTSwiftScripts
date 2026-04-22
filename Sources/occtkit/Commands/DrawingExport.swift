// DrawingExport — multi-view ISO technical drawing → DXF.
//
// Reads a JSON spec and produces a single DXF R12 sheet with full ISO
// scaffolding by orchestrating OCCTSwift v0.147+ primitives:
//   - `Sheet.render(into:)`                     → ISO 5457 border + ISO 7200
//                                                  title block + ISO 5456-2
//                                                  projection symbol
//   - `Drawing.project(_:direction:)` per view  → HLR projection
//   - `Drawing.bounds(deflection:)`             → autoscale + layout
//   - `Drawing.transformed(translate:scale:)`   → place each view on sheet
//   - `DXFWriter.collectFromDrawing(_:)`        → emit edges + dims + anns
//   - `Shape.section2DView(...)`                → section view (auto-hatched
//                                                  with ISO 128-50 45° lines)
//   - `Drawing.addCuttingPlaneLine(...)`        → ISO 128-40 section mark on
//                                                  parent view
//   - `Drawing.addAutoCentrelines(...)`         → revolution axes per view
//   - `Drawing.addAutoCentermarks(...)`         → circular feature centres
//   - `Drawing.addCosmeticThreadSide(...)`      → ISO 6410 cosmetic threads
//   - `DrawingAnnotation.surfaceFinish(...)`    → ISO 1302 finish marks
//   - `DrawingAnnotation.featureControlFrame(...)` → ISO 1101 GD&T frames
//   - `Drawing.detailView(at:scale:)`           → zoomed close-ups
//   - `DrawingScale.preferred`                  → ISO 5455 scale snapping
//
// Usage:
//   drawing-export                  (read JSON spec from stdin)
//   drawing-export <spec.json>      (read JSON spec from file)

import Foundation
import OCCTSwift
import ScriptHarness
import simd

enum DrawingExportCommand: Subcommand {
    static let name = "drawing-export"
    static let summary = "Multi-view ISO technical drawing → DXF (border + title + sections + GD&T)"
    static let usage = """
        Usage:
          drawing-export                  (read JSON spec from stdin)
          drawing-export <spec.json>      (read JSON spec from file)
        """

    struct Report: Codable {
        let output: String
        let sheet: String
        let projection: String
        let scale: String
        let viewCount: Int
        let sectionCount: Int
        let detailCount: Int
    }

    static func run(args: [String]) throws -> Int32 {
        let data: Data
        if let path = args.first, !path.hasPrefix("-") {
            guard let bytes = FileManager.default.contents(atPath: path) else {
                throw ScriptError.message("Failed to read spec at \(path)")
            }
            data = bytes
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }

        let spec: DrawingSpec
        do {
            spec = try JSONDecoder().decode(DrawingSpec.self, from: data)
        } catch {
            throw ScriptError.message("Invalid spec JSON: \(error.localizedDescription)")
        }

        let shape = try GraphIO.loadBREP(at: spec.shape)
        let deflection = spec.deflection ?? 0.1
        let projectionAngle = spec.sheet.projection.upstream
        let paperSize = spec.sheet.size.upstream
        let orientation = spec.sheet.orientation.upstream

        // 1. Project all requested views, compute bounds.
        let items = MultiViewLayout.project(shape, views: spec.views, deflection: deflection)
        guard !items.isEmpty else {
            throw ScriptError.message("No views projected — check the `views` array in the spec")
        }

        // 2. Determine drawing scale (ISO 5455 snapped if "auto").
        let sheetSize = paperSize.size(in: orientation)
        let drawableArea = (width: sheetSize.x - 30, height: sheetSize.y - 80)  // reserve title block + margins
        let drawScale = chooseScale(spec.sheet.scale, items: items,
                                    drawableArea: drawableArea)
        let scaleLabel = formatDrawingScale(drawScale)

        // 3. Sheet (border + title block + projection symbol) via upstream.
        let sheet = Sheet(size: paperSize,
                          orientation: orientation,
                          projection: projectionAngle,
                          title: spec.title?.upstream(scale: scaleLabel),
                          scale: scaleLabel)

        let writer = DXFWriter(deflection: deflection)
        if spec.sheet.border ?? true {
            sheet.render(into: writer)
        }

        // 4. Place views around drawing-area centre (above the title block).
        let inner = sheet.innerFrame
        let centre = SIMD2((inner.min.x + inner.max.x) / 2,
                           inner.min.y + (inner.max.y - inner.min.y - 60) / 2 + 60)
        let placed = MultiViewLayout.place(items: items,
                                           angle: projectionAngle,
                                           sheetCentre: centre,
                                           scale: drawScale)

        // 5. Per-view annotations: auto-centerlines, auto-centermarks,
        //    user-specified centermarks, cosmetic threads, surface finish,
        //    GD&T, dimensions.
        applyCenterAnnotations(items: items, shape: shape, spec: spec)
        applyManualAnnotations(items: items, spec: spec)

        // 6. Render every view onto the writer at its placement.
        for item in items {
            guard let p = placed[item.name] else { continue }
            writer.collectFromDrawing(item.drawing.transformed(
                translate: p.translate, scale: p.scale))
            // View label below the bbox.
            if let bb = item.bounds {
                let centreX = (bb.min.x + bb.max.x) / 2
                let yBelow = bb.min.y - 5
                let labelPos = SIMD2(centreX * p.scale + p.translate.x,
                                     yBelow * p.scale + p.translate.y)
                writer.addText(item.name.uppercased(),
                               at: labelPos, height: 4.0, layer: "TEXT")
            }
        }

        // 7. Section views (Shape.section2DView ships pre-hatched + labelled).
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
            // Cutting-plane line on parent view via upstream typed annotation.
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
                // Re-emit parent view to pick up the freshly-added annotation.
                if let parentPlaced = placed[parentName] {
                    writer.collectFromDrawing(parent.drawing.transformed(
                        translate: parentPlaced.translate, scale: parentPlaced.scale))
                }
            }
            sectionsRendered += 1
        }

        // 8. Detail views — Drawing.detailView(at:scale:) returns a TransformedDrawing.
        var detailsRendered = 0
        for d in spec.detailViews ?? [] {
            guard d.centre.count == 2,
                  let parent = items.first(where: { $0.name == d.fromView }) else { continue }
            let placement = SIMD2(d.placement?[0] ?? sectionStackX - 40,
                                   d.placement?[1] ?? stackedY - 40)
            let detail = parent.drawing.detailView(
                at: placement,
                scale: d.scale
            )
            writer.collectFromDrawing(detail)
            writer.addText("DETAIL \(d.name) (\(formatDrawingScale(d.scale)))",
                           at: SIMD2(placement.x, placement.y - 5),
                           height: 3.5, layer: "TEXT")
            stackedY -= 60
            detailsRendered += 1
        }

        // 9. Write DXF.
        let outURL = URL(fileURLWithPath: spec.output)
        do {
            try writer.write(to: outURL)
        } catch {
            throw ScriptError.message("DXF write failed: \(error.localizedDescription)")
        }

        try GraphIO.emitJSON(Report(
            output: spec.output,
            sheet: "\(spec.sheet.size.rawValue.uppercased()) \(spec.sheet.orientation.rawValue)",
            projection: spec.sheet.projection.rawValue,
            scale: scaleLabel,
            viewCount: items.count,
            sectionCount: sectionsRendered,
            detailCount: detailsRendered
        ))
        return 0
    }

    // MARK: - Annotation application

    private static func applyCenterAnnotations(items: [ViewItem], shape: Shape, spec: DrawingSpec) {
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
        // Centermarks: auto by default.
        let request = spec.centermarks ?? .auto
        switch request {
        case .auto:
            for item in items {
                _ = item.drawing.addAutoCentermarks(
                    from: shape,
                    viewDirection: item.direction,
                    extent: 8,
                    minRadius: 0,
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

    private static func applyManualAnnotations(items: [ViewItem], spec: DrawingSpec) {
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        // Cosmetic threads
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

        // Surface finish (ISO 1302) → annotations appended to the per-view drawing
        for sf in spec.surfaceFinish ?? [] {
            guard let item = byName[sf.view],
                  sf.position.count == 2, sf.leaderTo.count == 2 else { continue }
            let symbol = SurfaceFinishSymbol(rawValue: sf.symbol ?? "machiningRequired")
                         ?? .machiningRequired
            let anns = DrawingAnnotation.surfaceFinish(
                at: SIMD2(sf.position[0], sf.position[1]),
                leaderTo: SIMD2(sf.leaderTo[0], sf.leaderTo[1]),
                ra: sf.ra,
                symbol: symbol,
                method: sf.method
            )
            replay(anns, on: item.drawing)
        }

        // GD&T feature control frames (ISO 1101)
        for g in spec.gdt ?? [] {
            guard let item = byName[g.view],
                  g.position.count == 2,
                  let symbol = GDTSymbol(rawValue: g.symbol) else { continue }
            let leader = g.leaderTo.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
            let anns = DrawingAnnotation.featureControlFrame(
                at: SIMD2(g.position[0], g.position[1]),
                symbol: symbol,
                tolerance: g.tolerance,
                datums: g.datums ?? [],
                leaderTo: leader
            )
            replay(anns, on: item.drawing)
        }

        // Dimensions (linear / radial / diameter / angular)
        for d in spec.dimensions ?? [] {
            guard let item = byName[d.view] else { continue }
            switch d.type {
            case .linear:
                guard let f = d.from, f.count == 2, let t = d.to, t.count == 2 else { continue }
                item.drawing.addLinearDimension(
                    from: SIMD2(f[0], f[1]),
                    to:   SIMD2(t[0], t[1]),
                    offset: d.offset ?? 10,
                    label: d.label
                )
            case .radial:
                guard let c = d.centre, c.count == 2, let r = d.radius else { continue }
                item.drawing.addRadialDimension(
                    centre: SIMD2(c[0], c[1]),
                    radius: r,
                    leaderAngle: d.leaderAngle ?? .pi / 4,
                    label: d.label
                )
            case .diameter:
                guard let c = d.centre, c.count == 2, let r = d.radius else { continue }
                item.drawing.addDiameterDimension(
                    centre: SIMD2(c[0], c[1]),
                    radius: r,
                    leaderAngle: d.leaderAngle ?? .pi / 4,
                    label: d.label
                )
            case .angular:
                guard let v = d.vertex, v.count == 2,
                      let r1 = d.ray1, r1.count == 2,
                      let r2 = d.ray2, r2.count == 2 else { continue }
                item.drawing.addAngularDimension(
                    vertex: SIMD2(v[0], v[1]),
                    ray1: SIMD2(r1[0], r1[1]),
                    ray2: SIMD2(r2[0], r2[1]),
                    arcRadius: d.arcRadius ?? 20,
                    label: d.label
                )
            }
        }
    }

    /// Re-emit a list of `DrawingAnnotation` onto a `Drawing` via its typed
    /// public methods. Workaround for the absence of a public
    /// `Drawing.appendAnnotation(_:)` — see upstream OCCTSwift issue.
    private static func replay(_ anns: [DrawingAnnotation], on drawing: Drawing) {
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
                // No public typed setter for these on Drawing yet; the
                // surfaceFinish / featureControlFrame factories don't emit
                // them, so this branch is unreachable in practice.
                break
            }
        }
    }

    // MARK: - Scale (ISO 5455)

    private static func chooseScale(_ requested: ScaleSpec,
                                    items: [ViewItem],
                                    drawableArea: (width: Double, height: Double)) -> Double {
        if case .ratio = requested { return requested.multiplier }
        // Auto: largest ISO 5455 preferred scale that fits the layout bbox.
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
        // Snap to ISO 5455 preferred series (largest that doesn't exceed raw).
        for s in DrawingScale.preferred where s.factor <= raw {
            return s.factor
        }
        return DrawingScale.preferred.last?.factor ?? raw
    }

    private static func formatDrawingScale(_ multiplier: Double) -> String {
        // Match an ISO 5455 preferred scale if possible for the label.
        for s in DrawingScale.preferred where abs(s.factor - multiplier) < 1e-6 {
            return s.label
        }
        return DrawingScale.custom(multiplier).label
    }
}
