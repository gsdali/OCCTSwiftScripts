// Sheet.swift
// Render an ISO 5457 trimmed sheet border + ISO 7200 title block onto a DXFWriter.
//
// Layout convention: the DXF coordinate origin is at the bottom-left of the
// trimmed sheet (matches paper-space convention). The drawing-area frame and
// title block are drawn into the writer using existing DXFWriter primitives
// (lines, polylines, text). Layers used: BORDER, TITLE, TEXT.

import Foundation
import OCCTSwift

struct Sheet {
    let size: PaperSize.Size
    let orientation: Orientation
    let title: TitleBlockSpec?
    let projection: ProjectionAngle
    let scaleLabel: String                       // e.g. "1:1"
    let drawProjectionSymbol: Bool

    /// Trimmed sheet (width, height) in mm.
    var trimmed: (width: Double, height: Double) {
        PaperSize.dimensions(size, orientation)
    }

    /// Inner drawing-area rectangle (the ISO 5457 frame), as
    /// (origin_x, origin_y, width, height). Bottom-left at (insets.left, insets.bottom).
    var drawingArea: (x: Double, y: Double, width: Double, height: Double) {
        let t = trimmed
        let i = PaperSize.frameInsets
        return (i.left, i.bottom, t.width - i.left - i.right, t.height - i.top - i.bottom)
    }

    /// Render border, centring marks, projection symbol, and title block onto
    /// the writer. Idempotent for a given Sheet value.
    func render(into writer: DXFWriter) {
        renderBorder(into: writer)
        renderCentringMarks(into: writer)
        if let title { renderTitleBlock(title, into: writer) }
        if drawProjectionSymbol { renderProjectionSymbol(into: writer) }
        renderScaleLabel(into: writer)
    }

    private func renderBorder(into writer: DXFWriter) {
        let a = drawingArea
        // Drawing-area frame (ISO 5457: continuous 0.7 mm line)
        writer.addPolyline([
            SIMD2(a.x,         a.y),
            SIMD2(a.x + a.width, a.y),
            SIMD2(a.x + a.width, a.y + a.height),
            SIMD2(a.x,         a.y + a.height),
        ], closed: true, layer: "BORDER")
    }

    private func renderCentringMarks(into writer: DXFWriter) {
        let t = trimmed
        let a = drawingArea
        let ext = PaperSize.centringMarkExtension
        // Four marks at midpoints of each edge of the drawing-area frame,
        // extending outward to the trimmed edge. Per ISO 5457 §5.4.
        // Bottom
        writer.addLine(from: SIMD2(t.width / 2, 0),
                       to:   SIMD2(t.width / 2, a.y + ext),
                       layer: "BORDER")
        // Top
        writer.addLine(from: SIMD2(t.width / 2, t.height),
                       to:   SIMD2(t.width / 2, a.y + a.height - ext),
                       layer: "BORDER")
        // Left
        writer.addLine(from: SIMD2(0, t.height / 2),
                       to:   SIMD2(a.x + ext, t.height / 2),
                       layer: "BORDER")
        // Right
        writer.addLine(from: SIMD2(t.width, t.height / 2),
                       to:   SIMD2(a.x + a.width - ext, t.height / 2),
                       layer: "BORDER")
    }

    /// ISO 7200-shaped title block in the bottom-right corner of the drawing area.
    /// Width fits 8 mandatory + a few optional fields in a compact 2-row 4-col grid.
    private func renderTitleBlock(_ t: TitleBlockSpec, into writer: DXFWriter) {
        let a = drawingArea
        // Title block: 180mm wide, 40mm tall, snapped to the bottom-right corner.
        let tbW: Double = 180
        let tbH: Double = 40
        let x0 = a.x + a.width - tbW
        let y0 = a.y
        let x1 = a.x + a.width
        let y1 = a.y + tbH

        // Outer frame
        writer.addPolyline([
            SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1),
        ], closed: true, layer: "TITLE")

        // Internal grid (3 columns × 4 rows: title spans the full width on top row)
        let colWidths: [Double] = [60, 60, 60]    // sums to 180
        let rowHeights: [Double] = [12, 8, 8, 12] // bottom→top, sums to 40
        var y = y0
        var rowYs: [Double] = [y]
        for h in rowHeights {
            y += h
            rowYs.append(y)
        }
        var x = x0
        var colXs: [Double] = [x]
        for w in colWidths {
            x += w
            colXs.append(x)
        }

        // Horizontal grid lines (skip outer)
        for i in 1..<rowYs.count - 1 {
            writer.addLine(from: SIMD2(x0, rowYs[i]), to: SIMD2(x1, rowYs[i]), layer: "TITLE")
        }
        // Vertical grid lines (skip outer; top row is full-width title so we omit
        // verticals across the top row by clipping to rowYs[3])
        for i in 1..<colXs.count - 1 {
            writer.addLine(from: SIMD2(colXs[i], y0), to: SIMD2(colXs[i], rowYs[3]), layer: "TITLE")
        }

        // Field placement helper.
        func field(_ label: String, _ value: String?, col: Int, row: Int, height: Double = 2.5) {
            let cellX = colXs[col] + 1
            let cellY = rowYs[row] + rowHeights[rowHeights.count - 1 - row] - 3
            writer.addText(label, at: SIMD2(cellX, cellY),
                           height: height, layer: "TEXT")
            if let value, !value.isEmpty {
                writer.addText(value, at: SIMD2(cellX, cellY - 4),
                               height: 3.0, layer: "TEXT")
            }
        }

        // Top row: TITLE (full width)
        let titleX = x0 + 2
        let titleY = rowYs[3] + 4
        writer.addText("TITLE", at: SIMD2(titleX, rowYs[4] - 3),
                       height: 2.5, layer: "TEXT")
        writer.addText(t.title, at: SIMD2(titleX, titleY),
                       height: 5.0, layer: "TEXT")

        // Row 3 (above bottom block): drawing number + revision + sheet number
        field("DRAWING NO.", t.drawingNumber, col: 0, row: 2)
        field("REV", t.revision, col: 1, row: 2)
        field("SHEET", t.sheetNumber, col: 2, row: 2)

        // Row 2: creator / approver / date
        field("DRAWN", t.creator, col: 0, row: 1)
        field("APPROVED", t.approver, col: 1, row: 1)
        field("DATE", t.dateOfIssue, col: 2, row: 1)

        // Row 1 (bottom): owner / document type / scale
        field("OWNER", t.owner, col: 0, row: 0, height: 2.5)
        field("DOC TYPE", t.documentType, col: 1, row: 0)
        field("SCALE", t.scaleOverride ?? scaleLabel, col: 2, row: 0)
    }

    /// ISO 5456-2 first / third angle projection symbol: a truncated cone in
    /// front view + a circle in side view, arranged to indicate the convention.
    /// Drawn to the left of the title block in a 30 × 20 mm box.
    private func renderProjectionSymbol(into writer: DXFWriter) {
        let a = drawingArea
        let boxW: Double = 30
        let boxH: Double = 20
        // Position: just to the left of the title block, on the bottom row.
        let titleX = a.x + a.width - 180
        let cx = titleX - boxW - 5 + boxW / 2
        let cy = a.y + boxH / 2

        let r1: Double = 8           // big-end radius of frustum
        let r2: Double = 4           // small-end radius
        let halfLen: Double = 7      // half axial length

        // Frustum view (front)
        let fx = cx - boxW / 4
        // Two horizontal trapezoid lines + two slanted sides
        writer.addLine(from: SIMD2(fx - halfLen, cy + r1), to: SIMD2(fx + halfLen, cy + r2), layer: "TITLE")
        writer.addLine(from: SIMD2(fx - halfLen, cy - r1), to: SIMD2(fx + halfLen, cy - r2), layer: "TITLE")
        writer.addLine(from: SIMD2(fx - halfLen, cy + r1), to: SIMD2(fx - halfLen, cy - r1), layer: "TITLE")
        writer.addLine(from: SIMD2(fx + halfLen, cy + r2), to: SIMD2(fx + halfLen, cy - r2), layer: "TITLE")
        // Centerline through frustum
        writer.addLine(from: SIMD2(fx - halfLen - 3, cy), to: SIMD2(fx + halfLen + 3, cy), layer: "CENTER")

        // Circle view (side) — placement encodes the projection convention.
        // First-angle: circle is to the LEFT of the front view (view-from-right
        // appears on the left). Third-angle: circle is to the RIGHT.
        let circleX: Double = (projection == .third) ? cx + boxW / 4 : cx - boxW / 4 - 14
        // Two concentric circles representing the cone seen end-on
        writer.addCircle(centre: SIMD2(circleX, cy), radius: r1, layer: "TITLE")
        writer.addCircle(centre: SIMD2(circleX, cy), radius: r2, layer: "TITLE")
        // Centermarks across both
        writer.addLine(from: SIMD2(circleX - r1 - 2, cy), to: SIMD2(circleX + r1 + 2, cy), layer: "CENTER")
        writer.addLine(from: SIMD2(circleX, cy - r1 - 2), to: SIMD2(circleX, cy + r1 + 2), layer: "CENTER")

        // Caption
        let label = (projection == .first) ? "FIRST ANGLE" : "THIRD ANGLE"
        writer.addText(label, at: SIMD2(cx - boxW / 2 + 1, a.y + boxH + 1),
                       height: 2.0, layer: "TEXT")
    }

    /// Show the drawing scale outside the title block — ISO 7200 "dynamic field".
    /// Placed in the bottom-left corner of the drawing area.
    private func renderScaleLabel(into writer: DXFWriter) {
        let a = drawingArea
        writer.addText("SCALE \(scaleLabel)", at: SIMD2(a.x + 2, a.y + 2),
                       height: 3.0, layer: "TEXT")
    }
}
