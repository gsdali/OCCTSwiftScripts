// DrawingExport — multi-view ISO technical drawing → DXF.
//
// Reads a JSON spec describing the source shape, sheet, views, sections, and
// annotations; produces a single DXF R12 ASCII file with:
//   - ISO 5457 trimmed-sheet border + centring marks
//   - ISO 7200 title block (bottom-right)
//   - ISO 5456-2 first/third-angle projection symbol
//   - HLR-projected orthographic views (front/top/right etc) laid out per
//     ISO 128-30 first or third angle
//   - Section views (Shape.sectionWithPlane) projected into each plane's 2D
//     frame, labelled "SECTION A-A"
//   - Cutting-plane lines + arrows + labels on parent views
//   - Auto-centerlines per view (Drawing.addAutoCentrelines using
//     Shape.revolutionAxes)
//   - User-specified centermarks and dimensions (linear, radial, diameter,
//     angular) per view
//
// Usage:
//   drawing-export                  (read JSON spec from stdin)
//   drawing-export <spec.json>      (read JSON spec from file)
//
// Stdout: small JSON report (output path, view count, section count, scale).

import Foundation
import OCCTSwift
import ScriptHarness
import simd

enum DrawingExportCommand: Subcommand {
    static let name = "drawing-export"
    static let summary = "Multi-view ISO technical drawing → DXF (border + title block + sections)"
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

        // 1. Project all requested views and compute their 2D bounds.
        let items = MultiViewLayout.project(shape, views: spec.views, deflection: deflection)
        guard !items.isEmpty else {
            throw ScriptError.message("No views projected — check the `views` array in the spec")
        }

        // 2. Determine an autoscale that fits all view bboxes inside the
        //    drawing area with sensible spacing for the multi-view layout.
        let sheet = Sheet(
            size: spec.sheet.size,
            orientation: spec.sheet.orientation,
            title: spec.title,
            projection: spec.sheet.projection,
            scaleLabel: scaleLabel(spec.sheet.scale),
            drawProjectionSymbol: spec.sheet.projectionSymbol ?? true
        )
        let area = sheet.drawingArea
        let scale = chooseScale(spec.sheet.scale,
                                items: items,
                                drawingAreaWidth: area.width - 100,        // reserve for labels
                                drawingAreaHeight: area.height - 60)       // reserve for title block
        let scaleLabelStr = formatScale(scale)

        // 3. Build sheet (border + title block + projection symbol) onto a
        //    fresh DXFWriter.
        let writer = DXFWriter(deflection: deflection)
        let sheetWithScale = Sheet(
            size: spec.sheet.size,
            orientation: spec.sheet.orientation,
            title: spec.title,
            projection: spec.sheet.projection,
            scaleLabel: scaleLabelStr,
            drawProjectionSymbol: spec.sheet.projectionSymbol ?? true
        )
        if spec.sheet.border ?? true {
            sheetWithScale.render(into: writer)
        }

        // 4. Place the views around the drawing-area centre (slightly above
        //    the title block).
        let centre = SIMD2(area.x + (area.width - 60) / 2, area.y + (area.height + 40) / 2)
        let placements = MultiViewLayout.place(
            items: items,
            angle: spec.sheet.projection,
            sheetCentre: centre,
            scale: scale,
            deflection: deflection
        )

        // 5. Populate per-view annotations into each Drawing before placement.
        applyAutoCenterlines(items: items, shape: shape, spec: spec)
        applyManualAnnotations(items: items, spec: spec)

        // 6. Render every view into the writer at its placement.
        for item in items {
            guard let p = placements[item.name] else { continue }
            ViewPlacer.place(item.drawing, placement: p, into: writer)
            // View label (e.g. "TOP", "FRONT") below the view.
            if let bb = item.bounds {
                let centreX = (bb.min.x + bb.max.x) / 2
                let yBelow = bb.min.y - 5
                let labelPos = p.t(SIMD2(centreX, yBelow))
                writer.addText(item.name.uppercased(),
                               at: labelPos, height: 4.0, layer: "TEXT")
            }
        }

        // 7. Render section views.
        let sections = renderSections(spec: spec, shape: shape, items: items,
                                       placements: placements, sheetCentre: centre,
                                       scale: scale, deflection: deflection,
                                       drawingArea: area, writer: writer)

        // 8. Finalise: write the DXF file.
        let outURL = URL(fileURLWithPath: spec.output)
        do {
            try writer.write(to: outURL)
        } catch {
            throw ScriptError.message("DXF write failed: \(error.localizedDescription)")
        }

        try GraphIO.emitJSON(Report(
            output: spec.output,
            sheet: "\(spec.sheet.size.rawValue) \(spec.sheet.orientation.rawValue)",
            projection: spec.sheet.projection.rawValue,
            scale: scaleLabelStr,
            viewCount: items.count,
            sectionCount: sections
        ))
        return 0
    }

    // MARK: - Annotation application

    private static func applyAutoCenterlines(items: [ViewItem], shape: Shape, spec: DrawingSpec) {
        guard (spec.centerlines ?? .auto) == .auto else { return }
        for item in items {
            // Drawing.addAutoCentrelines requires the view direction used at
            // projection time (which we have) and the drawing's 2D bounds.
            _ = item.drawing.addAutoCentrelines(
                from: shape,
                viewDirection: item.direction,
                overshoot: 5,
                tolerance: 1e-6,
                bounds: item.bounds
            )
        }
    }

    private static func applyManualAnnotations(items: [ViewItem], spec: DrawingSpec) {
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        for cm in spec.centermarks ?? [] {
            guard let item = byName[cm.view] else { continue }
            item.drawing.addCentermark(centre: SIMD2(cm.x, cm.y),
                                       extent: cm.extent ?? 8)
        }

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

    // MARK: - Sections

    private static func renderSections(spec: DrawingSpec,
                                       shape: Shape,
                                       items: [ViewItem],
                                       placements: [String: ViewPlacement],
                                       sheetCentre: SIMD2<Double>,
                                       scale: Double,
                                       deflection: Double,
                                       drawingArea: (x: Double, y: Double, width: Double, height: Double),
                                       writer: DXFWriter) -> Int {
        let sectionsSpec = spec.sections ?? []
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        var rendered = 0
        // Stack section views to the right of the main layout.
        var nextX = drawingArea.x + drawingArea.width - 80
        let sectionY = drawingArea.y + drawingArea.height - 80
        var stackedY = sectionY

        for section in sectionsSpec {
            guard section.plane.origin.count == 3, section.plane.normal.count == 3 else { continue }
            let basis = SectionExtraction.basis(
                origin: SIMD3(section.plane.origin[0],
                              section.plane.origin[1],
                              section.plane.origin[2]),
                normal: SIMD3(section.plane.normal[0],
                              section.plane.normal[1],
                              section.plane.normal[2])
            )
            guard let result = SectionExtraction.extract(shape, plane: basis, deflection: deflection) else {
                continue
            }
            // Place the section view in the stacked-right column.
            let bb = result.bounds ?? (SIMD2(-50, -50), SIMD2(50, 50))
            let w = (bb.max.x - bb.min.x) * scale
            let h = (bb.max.y - bb.min.y) * scale
            let centreX = nextX - w / 2
            let centreY = stackedY - h / 2
            let off = SIMD2(centreX - (bb.min.x + bb.max.x) / 2 * scale,
                            centreY - (bb.min.y + bb.max.y) / 2 * scale)
            let placement = ViewPlacement(offset: off, scale: scale, deflection: deflection)
            SectionExtraction.place(result, placement: placement, label: section.name, writer: writer)

            // Draw the cutting-plane line + arrows on the labelOnView
            if let parentName = section.labelOnView, let parent = byName[parentName],
               let parentPlacement = placements[parentName] {
                SectionMark.draw(
                    label: section.name,
                    cuttingPlane: basis,
                    onViewDirection: parent.direction,
                    viewBounds: parent.bounds,
                    placement: parentPlacement,
                    writer: writer
                )
            }
            stackedY -= (h + 30)
            if stackedY < drawingArea.y + 50 {
                stackedY = sectionY
                nextX -= 100
            }
            rendered += 1
        }
        return rendered
    }

    // MARK: - Scale

    private static func chooseScale(_ requested: ScaleSpec,
                                    items: [ViewItem],
                                    drawingAreaWidth: Double,
                                    drawingAreaHeight: Double) -> Double {
        if case .ratio = requested { return requested.multiplier }
        // .auto: pick the largest standard ratio that fits the front-view bbox
        // plus the largest of (top-bbox-h, bottom-bbox-h) and the largest of
        // (left-bbox-w, right-bbox-w), with gutter.
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
        let limitW = drawingAreaWidth / max(totalW, 1)
        let limitH = drawingAreaHeight / max(totalH, 1)
        let raw = min(limitW, limitH)
        return snapToStandardScale(raw)
    }

    private static let standardScales: [Double] = [
        100.0, 50.0, 20.0, 10.0, 5.0, 2.0,    // enlargements
        1.0,
        1.0/2, 1.0/5, 1.0/10, 1.0/20, 1.0/50, 1.0/100, 1.0/200, 1.0/500, 1.0/1000,
    ]

    private static func snapToStandardScale(_ raw: Double) -> Double {
        // Pick the largest standard scale that does not exceed the raw fit.
        for s in standardScales where s <= raw { return s }
        return standardScales.last ?? raw
    }

    private static func scaleLabel(_ s: ScaleSpec) -> String {
        switch s {
        case .auto: return "auto"
        case .ratio(let n, let d): return formatScale(n / d)
        }
    }

    private static func formatScale(_ multiplier: Double) -> String {
        if multiplier >= 1 {
            let n = multiplier.rounded()
            if abs(multiplier - n) < 1e-6 { return "\(Int(n)):1" }
            return String(format: "%.2f:1", multiplier)
        } else {
            let d = (1.0 / multiplier).rounded()
            if abs((1.0 / multiplier) - d) < 1e-6 { return "1:\(Int(d))" }
            return String(format: "1:%.2f", 1.0 / multiplier)
        }
    }
}
