# OCCTSwiftScripts — Workflow Guide

This document describes how to use the OCCTSwift script harness to develop parametric geometry, produce 2D/3D gallery views, and promote script code into a reusable app library.

## Overview

The script harness gives you a CadQuery/OpenSCAD-style workflow for OCCTSwift:

1. **Write** geometry code in `Sources/Script/main.swift`
2. **Run** `swift run Script` (~1-2s incremental)
3. **See** results in the OCCTSwiftViewport demo app (auto-reload via file watcher)
4. **Export** BREP + STEP files for external validation (ezdxf, FreeCAD, STEPUtils)
5. **Promote** validated geometry code into a shared library for app integration

You have access to the **full OCCTSwift API** — ~400+ methods across Shape, Wire, Edge, Face, Curve2D, Curve3D, Surface, Document, and more.

---

## 1. Writing Script Code

### Basic Structure

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext(metadata: ManifestMetadata(
    name: "JIS 60kg Rail",
    revision: "2",
    dateCreated: ISO8601DateFormatter().date(from: "2026-03-18T00:00:00Z"),
    dateModified: Date(),
    source: "JIS E 1101:2012",
    tags: ["rail", "profile", "Z-scale", "NEM-120"],
    notes: "Built from standard dimensions table"
))
let C = ScriptContext.Colors.self

// ... geometry code ...

try ctx.emit(description: "JIS 60kg rail profile")
```

### Adding Geometry

```swift
// Solid shapes (shaded + wireframe in viewport)
try ctx.add(shape, id: "bracket", color: C.steel, name: "Main bracket")

// Wire profiles / sketches (wireframe only — for 2D profile inspection)
try ctx.add(wire, id: "profile", color: C.yellow, name: "Cross-section sketch")

// Edges (wireframe only)
try ctx.add(edge, id: "axis", color: C.red, name: "Centre axis")

// Compound assemblies
try ctx.addCompound([part1, part2], id: "assembly", color: C.gray)
```

### Available Colors

```swift
let C = ScriptContext.Colors.self
// C.red  C.green  C.blue  C.yellow  C.orange  C.purple
// C.cyan  C.white  C.gray  C.steel  C.brass  C.copper
```

### Metadata Fields

Every script should set metadata via `ScriptContext(metadata:)`:

| Field | Type | Purpose |
|-------|------|---------|
| `name` | `String` | Part/assembly name (required) |
| `revision` | `String?` | Version identifier (e.g. "3", "A", "v2.1") |
| `dateCreated` | `Date?` | When the design was first created |
| `dateModified` | `Date?` | Last modification (use `Date()` for current) |
| `source` | `String?` | Reference standard, drawing number, or origin |
| `tags` | `[String]?` | Searchable keywords |
| `notes` | `String?` | Free-form design notes |

---

## 2. OCCTSwift API Quick Reference

### Sketching (Wire/Edge)

```swift
// 2D profiles (in XY plane, Z = 0)
Wire.rectangle(width: 20, height: 10)
Wire.circle(radius: 5)
Wire.polygon([SIMD2(0,0), SIMD2(10,0), SIMD2(10,5), SIMD2(0,5)])
Wire.ellipse(majorRadius: 10, minorRadius: 5)
Wire.arc(center: SIMD2(0,0), radius: 5, startAngle: 0, endAngle: .pi/2)

// 3D paths
Wire.line(from: SIMD3(0,0,0), to: SIMD3(0,0,100))
Wire.helix(radius: 5, pitch: 10, height: 50)
Wire.circle(origin: SIMD3(0,0,0), normal: SIMD3(0,0,1), radius: 10)
```

### Solid Creation

```swift
// Primitives
Shape.box(width: 10, height: 5, depth: 3)
Shape.cylinder(radius: 2, height: 8)
Shape.sphere(radius: 5)
Shape.cone(bottomRadius: 5, topRadius: 2, height: 10)
Shape.torus(majorRadius: 10, minorRadius: 2)

// From profiles
Shape.extrude(profile: wire, direction: SIMD3(0,0,1), length: 10)
Shape.revolve(axis: SIMD3(0,1,0), axisOrigin: .zero, angle: .pi*2, profile: wire)
Shape.sweep(profile: wire, along: pathWire)
Shape.loft(profiles: [wire1, wire2, wire3], solid: true)
Shape.evolved(spine: spineWire, profile: profileWire)

// Faces
Shape.face(from: wire, planar: true)       // Planar face from closed wire
Shape.face(outer: outerWire, holes: [h1])  // Face with holes
```

### Booleans & Modifications

```swift
shape.union(with: other)           // or: shape + other (no operator, use method)
shape.subtracting(other)           // Cut
shape.intersection(with: other)    // Common volume
shape.split(by: tool)              // Returns [Shape]

shape.filleted(radius: 1.0)       // All edges
shape.filleted(edges: [e1, e2], radius: 1.0)
shape.chamfered(distance: 0.5)

shape.shelled(thickness: 1.0)     // Hollow out
shape.offset(by: 2.0)             // Offset surface
shape.drafted(...)                 // Draft angle

shape.drilled(at: pos, direction: dir, radius: 3, depth: 10)  // Hole
shape.withPocket(profile: wire, direction: dir, depth: 5)
shape.withBoss(profile: wire, direction: dir, height: 3)

shape.linearPattern(direction: SIMD3(1,0,0), spacing: 20, count: 5)
shape.circularPattern(axisPoint: .zero, axisDirection: SIMD3(0,1,0), count: 6, angle: .pi*2)
```

### Transforms

```swift
shape.translated(by: SIMD3(10, 0, 0))
shape.rotated(axis: SIMD3(0, 1, 0), angle: .pi / 4)
shape.scaled(by: 2.0)
shape.mirrored(planeNormal: SIMD3(1, 0, 0), planeOrigin: .zero)
```

### Analysis

```swift
shape.volume           // Double?
shape.surfaceArea      // Double?
shape.centerOfMass     // SIMD3<Double>?
shape.bounds           // (min: SIMD3, max: SIMD3)
shape.isValid          // Bool
shape.faces()          // [Face]
shape.edges()          // [Edge]
shape.distance(to: other)  // DistanceResult?
```

### Dimensions (Programmatic Annotations)

```swift
// Length between two points
let dim = LengthDimension(from: SIMD3(0,0,0), to: SIMD3(10,0,0))
dim?.value           // 10.0
dim?.geometry        // DimensionGeometry? (for viewport rendering)

// Length of an edge
let dim2 = LengthDimension(edge: shape.subShape(type: .edge, index: 0)!)

// Distance between parallel faces
let dim3 = LengthDimension(face1: face1Shape, face2: face2Shape)

// Radius/Diameter on circular geometry
let rad = RadiusDimension(shape: cylinderShape)
let dia = DiameterDimension(shape: cylinderShape)

// Angle between edges, faces, or three points
let ang = AngleDimension(edge1: e1Shape, edge2: e2Shape)
let ang2 = AngleDimension(first: p1, vertex: p2, second: p3)
```

### Hidden Line Removal (2D Views)

HLR projects 3D geometry into 2D edge sets from a given viewing direction.
Use this to produce engineering-drawing-style 2D views with visible/hidden edges.

```swift
// Visible sharp edges from front view (looking along -Y)
let visibleEdges = shape.hlrEdges(direction: SIMD3(0, -1, 0), category: .visibleSharp)

// Hidden edges (dashed lines in drawings)
let hiddenEdges = shape.hlrEdges(direction: SIMD3(0, -1, 0), category: .hiddenSharp)

// Visible outline/silhouette
let outline = shape.hlrEdges(direction: SIMD3(0, -1, 0), category: .visibleOutline)

// Faster polygon-based HLR (approximate)
let polyVis = shape.hlrPolyEdges(direction: SIMD3(0, 0, -1), category: .visibleSharp)

// Standard engineering views:
let front = SIMD3<Double>(0, -1, 0)    // Front view (XZ plane)
let top   = SIMD3<Double>(0, 0, -1)    // Top/plan view (XY plane)
let right = SIMD3<Double>(1, 0, 0)     // Right side view (YZ plane)
let iso   = simd_normalize(SIMD3<Double>(1, -1, 1))  // Isometric
```

### File I/O

```swift
// Load existing geometry
let imported = try Shape.loadBREP(from: url)
let step = try Shape.load(from: stepURL)
let doc = try Document.load(from: stepURL)  // XDE with colors, names, GD&T

// Export (also done automatically by ctx.emit())
try Exporter.writeBREP(shape: shape, to: url)
try Exporter.writeSTEP(shape: shape, to: url, modelType: .asIs)
```

---

## 3. Gallery Pattern — 2D + 3D Views

A gallery function produces multiple visual outputs from a single part:
a 3D solid, a 2D cross-section, HLR projected views, and dimension annotations.

### Example: Rail Profile Gallery

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext(metadata: ManifestMetadata(
    name: "NEM 120 Profil 10",
    revision: "1",
    source: "NEM 120 standard",
    tags: ["rail", "profile", "Z-scale"]
))
let C = ScriptContext.Colors.self

// ── Build profile ──
let profile = Wire.polygon([...])!

// ── 3D: Swept rail ──
let path = Wire.line(from: SIMD3(0,0,0), to: SIMD3(0,0,50))!
let rail = Shape.sweep(profile: profile, along: path)!
try ctx.add(rail, id: "rail-3d", color: C.steel, name: "Rail solid")

// ── 2D: Cross-section profile ──
try ctx.add(profile, id: "profile-2d", color: C.yellow, name: "Cross-section")

// ── 2D: Scaled profile for inspection ──
// (When dimensions are sub-mm, a 10x scaled version is more readable)
let scaledPts = pts.map { SIMD2($0.x * 10, $0.y * 10) }
let scaledWire = Wire.polygon(scaledPts, closed: true)!
if let scaledShape = Shape.fromWire(scaledWire)?.translated(by: SIMD3(20, 0, 0)) {
    try ctx.add(scaledShape, id: "profile-10x", color: C.orange, name: "10x inspection")
}

// ── 2D: HLR projected views ──
let frontDir = SIMD3<Double>(0, -1, 0)
if let frontVisible = rail.hlrEdges(direction: frontDir, category: .visibleSharp),
   let frontShape = frontVisible.translated(by: SIMD3(0, 0, -30)) {
    try ctx.add(frontShape, id: "hlr-front", color: C.cyan, name: "Front view")
}
if let frontHidden = rail.hlrEdges(direction: frontDir, category: .hiddenSharp),
   let hiddenShape = frontHidden.translated(by: SIMD3(0, 0, -30)) {
    try ctx.add(hiddenShape, id: "hlr-front-hidden", color: C.gray, name: "Front hidden")
}

// ── Dimensions ──
// Key measurements as console output (and in manifest metadata)
let totalHeight = LengthDimension(from: SIMD3(0,0,0), to: SIMD3(0, 174, 0))
print("Height: \(totalHeight?.value ?? 0) mm")

let baseWidth = LengthDimension(from: SIMD3(-72.5,0,0), to: SIMD3(72.5,0,0))
print("Base width: \(baseWidth?.value ?? 0) mm")

try ctx.emit(description: "NEM 120 — profile + rail + HLR views")
```

### Gallery Output Structure

A well-formed gallery script produces:

| Body ID pattern | Type | Purpose |
|----------------|------|---------|
| `*-3d` | Solid shape | 3D rendered body |
| `*-2d` or `profile-*` | Wire | 2D cross-section / sketch |
| `*-10x` | Wire/Shape | Scaled inspection view |
| `hlr-front` | Wire | HLR front projection |
| `hlr-top` | Wire | HLR top/plan projection |
| `hlr-right` | Wire | HLR right side projection |
| `hlr-*-hidden` | Wire | Hidden edges (for dashed rendering) |
| `dim-*` | Wire/Shape | Dimension leader lines (when geometry-based) |

### HLR View Directions (Engineering Drawing Standard)

```
        Top (plan)
        ↓ (0, 0, -1)
        ┌─────────┐
        │         │
Left    │  Front  │    Right
(−1,0,0)│(0,−1,0) │   (1,0,0)
        │         │
        └─────────┘
        ↑ (0, 0, 1)
        Bottom

Isometric: normalize(1, −1, 1)
```

### Dimension Annotations in 2D Views

OCCTSwift provides four dimension types that can be created programmatically:

| Type | Constructor | Returns |
|------|-------------|---------|
| `LengthDimension` | `(from: SIMD3, to: SIMD3)` | Point-to-point distance |
| `LengthDimension` | `(edge: Shape)` | Edge length |
| `LengthDimension` | `(face1: Shape, face2: Shape)` | Face-to-face distance |
| `RadiusDimension` | `(shape: Shape)` | Radius of circular geometry |
| `DiameterDimension` | `(shape: Shape)` | Diameter of circular geometry |
| `AngleDimension` | `(edge1: Shape, edge2: Shape)` | Angle between edges |
| `AngleDimension` | `(first:vertex:second:)` | Angle from three points |
| `AngleDimension` | `(face1: Shape, face2: Shape)` | Dihedral angle |

Each dimension provides:
- `.value` — the measured quantity (mm or radians)
- `.geometry` — a `DimensionGeometry` struct with attachment points, text position, etc.

The `DimensionGeometry` can be rendered as leader lines + markers via the viewport's
`MeasurementOverlay` system, or printed to console for verification.

---

## 4. Promoting Script Code to a Shared Library

Once geometry code is validated in the script, extract it into a reusable library
that both the script and your app can import.

### Package Structure

```
OCCTSwiftScripts/
  Sources/
    RailProfiles/              ← NEW: shared geometry library
      NEM120Profile.swift        (returns Shape + Wire)
      JIS60kgProfile.swift
      ProfileTypes.swift         (shared result types)
    ScriptHarness/             ← existing: output helpers
    Script/main.swift          ← imports RailProfiles + ScriptHarness
```

### Step 1: Define a Result Type

```swift
// Sources/RailProfiles/ProfileTypes.swift
import OCCTSwift

/// Result of building a rail profile.
public struct RailProfileResult: Sendable {
    /// The closed profile wire (in XY plane, origin at base centre).
    public let profile: Wire

    /// The profile swept along a straight track.
    public let rail: Shape?

    /// Key dimensions for validation.
    public let dimensions: RailDimensions

    /// Metadata about the profile source.
    public let metadata: ManifestMetadata
}

public struct RailDimensions: Sendable {
    public let totalHeight: Double
    public let baseWidth: Double
    public let headWidth: Double
    public let webThickness: Double
    public let railVolume: Double?    // mm³ per mm of track length
}
```

### Step 2: Extract Geometry into a Library Function

```swift
// Sources/RailProfiles/NEM120Profile.swift
import OCCTSwift
import ScriptHarness

public enum NEM120Profile {

    /// Build the NEM 120 Profil 10 (Z-scale Code 40) rail profile.
    ///
    /// - Parameter trackLength: Length of straight rail to sweep (mm). Nil = profile only.
    /// - Returns: Profile wire, optional swept rail, and key dimensions.
    public static func build(trackLength: Double? = 20) -> RailProfileResult {
        let A = 1.0, B = 0.9, cW = 0.5, D = 0.2, E = 0.3, K = 0.35, R = 0.1
        // ... all the profile construction code from main.swift ...
        let profile = Wire.polygon(pts, closed: true)!

        var rail: Shape? = nil
        if let len = trackLength,
           let path = Wire.line(from: SIMD3(0,0,0), to: SIMD3(0,0,len)) {
            rail = Shape.sweep(profile: profile, along: path)
        }

        return RailProfileResult(
            profile: profile,
            rail: rail,
            dimensions: RailDimensions(
                totalHeight: A, baseWidth: B, headWidth: cW,
                webThickness: E, railVolume: rail?.volume
            ),
            metadata: ManifestMetadata(
                name: "NEM 120 Profil 10",
                revision: "1",
                source: "NEM 120 standard",
                tags: ["rail", "Z-scale", "code-40"]
            )
        )
    }
}
```

### Step 3: Add Library Target to Package.swift

```swift
.target(
    name: "RailProfiles",
    dependencies: [
        "ScriptHarness",
        .product(name: "OCCTSwift", package: "OCCTSwift"),
    ],
    path: "Sources/RailProfiles",
    swiftSettings: [.swiftLanguageMode(.v6)]
),
.executableTarget(
    name: "Script",
    dependencies: [
        "ScriptHarness",
        "RailProfiles",  // ← add dependency
        .product(name: "OCCTSwift", package: "OCCTSwift"),
    ],
    // ...
),
```

### Step 4: Simplify the Script

```swift
// Sources/Script/main.swift
import OCCTSwift
import ScriptHarness
import RailProfiles

let result = NEM120Profile.build(trackLength: 50)

let ctx = ScriptContext(metadata: result.metadata)
let C = ScriptContext.Colors.self

try ctx.add(result.profile, id: "profile", color: C.yellow)
if let rail = result.rail {
    try ctx.add(rail, id: "rail", color: C.steel)
}

// HLR front view
if let rail = result.rail,
   let vis = rail.hlrEdges(direction: SIMD3(0, -1, 0), category: .visibleSharp) {
    try ctx.add(vis, id: "hlr-front", color: C.cyan, name: "Front view")
}

print("Height: \(result.dimensions.totalHeight) mm")
print("Volume: \(result.dimensions.railVolume ?? 0) mm³")

try ctx.emit(description: result.metadata.name)
```

### Step 5: Use in Your App

In your app's `Package.swift`, add the scripts package as a dependency:

```swift
dependencies: [
    .package(path: "../OCCTSwiftScripts"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "RailProfiles", package: "OCCTSwiftScripts"),
            .product(name: "OCCTSwift", package: "OCCTSwift"),
            "OCCTSwiftViewport",
        ],
    ),
]
```

Then in your app code:

```swift
import RailProfiles
import OCCTSwift
import OCCTSwiftViewport

// Build geometry using the same validated code
let result = NEM120Profile.build(trackLength: 100)

// Convert to viewport bodies
if let rail = result.rail {
    let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
        rail, id: "rail",
        color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
    )
    if let body { bodies.append(body) }
}

// Add profile as wireframe
if let profileShape = Shape.fromWire(result.profile) {
    let (body, _) = CADFileLoader.shapeToBodyAndMetadata(
        profileShape, id: "profile",
        color: SIMD4<Float>(1.0, 0.9, 0.2, 1.0)
    )
    if let body { bodies.append(body) }
}
```

Or add it as a gallery function in the demo app:

```swift
// Sources/OCCTSwiftMetalDemo/RailGallery.swift
import RailProfiles

enum RailGallery {
    static func nem120() -> Curve2DGallery.GalleryResult {
        let result = NEM120Profile.build(trackLength: 50)
        var bodies: [ViewportBody] = []

        // 3D rail
        if let rail = result.rail {
            let (body, _) = CADFileLoader.shapeToBodyAndMetadata(
                rail, id: "rail-3d", color: SIMD4(0.7, 0.7, 0.75, 1.0)
            )
            if let body { bodies.append(body) }
        }

        // 2D profile
        if let profileShape = Shape.fromWire(result.profile) {
            let (body, _) = CADFileLoader.shapeToBodyAndMetadata(
                profileShape, id: "profile-2d", color: SIMD4(1.0, 0.9, 0.2, 1.0)
            )
            if let body { bodies.append(body) }
        }

        return Curve2DGallery.GalleryResult(
            bodies: bodies,
            description: "\(result.metadata.name) — " +
                "H=\(result.dimensions.totalHeight)mm " +
                "W=\(result.dimensions.baseWidth)mm"
        )
    }
}
```

---

## 5. Development Cycle Summary

```
┌─────────────────────────────────────────────────────┐
│  1. PROTOTYPE                                       │
│     Edit Sources/Script/main.swift                  │
│     swift run Script                                │
│     ↕ viewport auto-reloads (ScriptWatcher)         │
│     Iterate until geometry is correct               │
├─────────────────────────────────────────────────────┤
│  2. VALIDATE                                        │
│     Check output.step in FreeCAD/ezdxf              │
│     Verify dimensions via console output            │
│     Add HLR views for 2D inspection                 │
│     Add LengthDimension/RadiusDimension checks      │
├─────────────────────────────────────────────────────┤
│  3. EXTRACT                                         │
│     Move geometry code → Sources/MyLibrary/         │
│     Return result struct (Wire, Shape, dimensions)  │
│     Script becomes thin: import lib, add to ctx     │
├─────────────────────────────────────────────────────┤
│  4. INTEGRATE                                       │
│     App imports MyLibrary                           │
│     Calls same build() function                     │
│     Converts Shape → ViewportBody for display       │
│     Or adds as gallery function in demo app         │
└─────────────────────────────────────────────────────┘
```

---

## 6. Output Files Reference

After `swift run Script`, output is at `~/.occtswift-scripts/output/`:

| File | Format | Purpose |
|------|--------|---------|
| `body-N.brep` | OCCT BREP | Individual body (loaded by viewport watcher) |
| `output.step` | STEP AP214 | Combined geometry for external tools |
| `manifest.json` | JSON | Body descriptors, metadata, trigger file |

### Manifest JSON Structure

```json
{
  "version": 1,
  "timestamp": "2026-03-20T12:00:00Z",
  "description": "JIS 60kg rail profile",
  "metadata": {
    "name": "JIS 60kg Rail",
    "revision": "2",
    "dateCreated": "2026-03-18T00:00:00Z",
    "dateModified": "2026-03-20T12:00:00Z",
    "source": "JIS E 1101:2012",
    "tags": ["rail", "profile", "JIS"],
    "notes": "Built from standard dimensions table"
  },
  "bodies": [
    {
      "id": "profile",
      "file": "body-0.brep",
      "format": "brep",
      "color": [1.0, 0.9, 0.2, 1.0],
      "name": "Cross-section"
    },
    {
      "id": "rail",
      "file": "body-1.brep",
      "format": "brep",
      "color": [0.7, 0.7, 0.75, 1.0],
      "name": "50mm straight rail"
    }
  ]
}
```
