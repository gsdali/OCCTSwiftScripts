// main.swift — Script Harness Template
//
// This is your OCCTSwift scratchpad. Edit freely, then run:
//   swift run Script
//
// The viewport app (with Script Watcher enabled) will auto-reload.
// Output goes to ~/.occtswift-scripts/output/ (BREP + STEP files).
//
// You have access to the FULL OCCTSwift API:
//   Shape, Wire, Edge, Face, Curve2D, Curve3D, Surface, Document,
//   booleans, fillets, chamfers, sweeps, lofts, transforms, patterns,
//   projections, measurements, GD&T, file I/O, and more.

import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// ── Example: Parametric bracket with filleted edges and bolt hole ──

// 1. Sketch an L-shaped profile
let profile = Wire.polygon([
    SIMD2(0, 0),
    SIMD2(40, 0),
    SIMD2(40, 5),
    SIMD2(5, 5),
    SIMD2(5, 25),
    SIMD2(0, 25),
])!
try ctx.add(profile, id: "sketch", color: C.yellow, name: "Profile sketch")

// 2. Extrude to solid
let extruded = Shape.extrude(
    profile: profile,
    direction: SIMD3(0, 0, 1),
    length: 20
)!

// 3. Fillet all edges
let filleted = extruded.filleted(radius: 1.5) ?? extruded

// 4. Drill a bolt hole through the base flange
let bracket = filleted.drilled(
    at: SIMD3(20, 2.5, 10),
    direction: SIMD3(0, 1, 0),
    radius: 3,
    depth: 10
) ?? filleted

try ctx.add(bracket, id: "bracket", color: C.steel, name: "Bracket")

// 5. Add a mounting bolt (separate part)
let boltShaft = Shape.cylinder(radius: 2.8, height: 12)!
    .translated(by: SIMD3(20, -2, 10))!
let boltHead = Shape.cylinder(radius: 5, height: 3)!
    .translated(by: SIMD3(20, -5, 10))!
let bolt = boltShaft.union(with: boltHead) ?? boltShaft
try ctx.add(bolt, id: "bolt", color: C.brass, name: "M6 Bolt")

try ctx.emit(description: "Parametric bracket with bolt hole and hardware")
