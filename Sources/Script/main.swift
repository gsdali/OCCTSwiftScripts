// Pipeline reconstruction of McMaster 91502A278 M16x70 socket head cap screw
// Drawing type: 3rd_angle, 10 segments traced from real engineering drawing

import OCCTSwift
import ScriptHarness
import Foundation

let ctx = ScriptContext()

guard let c_seg1 = Curve2D.segment(from: SIMD2(2514.49492791066, 491.771863365059), to: SIMD2(2558.01083874765, 468.085981700795)),
      let w_seg1 = Wire.fromCurve2D(c_seg1) else { fatalError("seg1") }
guard let c_seg2 = Curve2D.segment(from: SIMD2(2564.92118899864, 447.19099442846), to: SIMD2(2558.01083874765, 468.085981700795)),
      let w_seg2 = Wire.fromCurve2D(c_seg2) else { fatalError("seg2") }
guard let c_seg3 = Curve2D.segment(from: SIMD2(2558.01083874765, 468.085981700795), to: SIMD2(2547.87339896333, 484.788551081164)),
      let w_seg3 = Wire.fromCurve2D(c_seg3) else { fatalError("seg3") }
guard let c_seg4 = Curve2D.segment(from: SIMD2(2547.87339896333, 484.788551081164), to: SIMD2(2532.50854415954, 493.903950335487)),
      let w_seg4 = Wire.fromCurve2D(c_seg4) else { fatalError("seg4") }
guard let c_seg5 = Curve2D.segment(from: SIMD2(2532.50854415954, 493.903950335487), to: SIMD2(2514.49492791066, 491.771863365059)),
      let w_seg5 = Wire.fromCurve2D(c_seg5) else { fatalError("seg5") }
guard let c_seg6 = Curve2D.segment(from: SIMD2(2551.03468506118, 474.635448965979), to: SIMD2(2514.49492791066, 491.771863365059)),
      let w_seg6 = Wire.fromCurve2D(c_seg6) else { fatalError("seg6") }
guard let c_seg7 = Curve2D.segment(from: SIMD2(2514.49492791066, 491.771863365059), to: SIMD2(2488.86021009317, 483.641737589616)),
      let w_seg7 = Wire.fromCurve2D(c_seg7) else { fatalError("seg7") }
guard let c_seg8 = Curve2D.segment(from: SIMD2(2488.86021009317, 483.641737589616), to: SIMD2(2470.14234865582, 461.43763920772)),
      let w_seg8 = Wire.fromCurve2D(c_seg8) else { fatalError("seg8") }
guard let c_seg9 = Curve2D.segment(from: SIMD2(2470.14234865582, 461.43763920772), to: SIMD2(2461.97468276258, 437.95263891928)),
      let w_seg9 = Wire.fromCurve2D(c_seg9) else { fatalError("seg9") }
guard let c_seg10 = Curve2D.segment(from: SIMD2(2471.88354219207, 412.803751762215), to: SIMD2(2461.97468276258, 437.95263891928)),
      let w_seg10 = Wire.fromCurve2D(c_seg10) else { fatalError("seg10") }

guard let profile = Wire.join([w_seg1, w_seg2, w_seg3, w_seg4, w_seg5, w_seg6, w_seg7, w_seg8, w_seg9, w_seg10]) else {
    fatalError("Failed to join profile wire")
}
try ctx.add(profile, color: [0, 0.8, 1], name: "profile")

guard let solid = Shape.extrude(profile: profile, direction: SIMD3(0, 0, 1), length: 10) else {
    fatalError("Failed to extrude")
}
try ctx.add(solid, color: [0.6, 0.6, 0.65], name: "Reconstructed M16x70 (FAIL)")

try ctx.emit(description: "Pipeline reconstruction of McMaster M16x70")
