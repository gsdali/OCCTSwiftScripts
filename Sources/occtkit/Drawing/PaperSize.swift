// PaperSize.swift
// ISO 5457:1999 trimmed sheet sizes. All units in millimetres.

import Foundation

enum PaperSize {
    enum Size: String, Codable, CaseIterable {
        case A0, A1, A2, A3, A4

        /// Trimmed sheet (short × long), per ISO 5457.
        var portrait: (width: Double, height: Double) {
            switch self {
            case .A0: return (841,  1189)
            case .A1: return (594,  841)
            case .A2: return (420,  594)
            case .A3: return (297,  420)
            case .A4: return (210,  297)
            }
        }
    }

    /// Trimmed sheet dimensions for a given size + orientation.
    static func dimensions(_ size: Size, _ orientation: Orientation) -> (width: Double, height: Double) {
        let p = size.portrait
        switch orientation {
        case .portrait:  return p
        case .landscape: return (p.height, p.width)
        }
    }

    /// ISO 5457 inner frame (drawing-area) inset relative to the trimmed edge.
    /// 20 mm on the binding (left) edge, 10 mm on the other three.
    /// Returned as (left, right, top, bottom) insets.
    static let frameInsets: (left: Double, right: Double, top: Double, bottom: Double) =
        (left: 20, right: 10, top: 10, bottom: 10)

    /// ISO 5457 frame line width.
    static let frameLineWidth: Double = 0.7

    /// Centring-mark thickness extension past the frame.
    static let centringMarkExtension: Double = 5
}
