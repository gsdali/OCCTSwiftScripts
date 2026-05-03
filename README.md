# OCCTSwiftScripts

A script harness for rapid iteration on [OCCTSwift](https://github.com/gsdali/OCCTSwift) parametric geometry. Edit a Swift script using the **full OCCTSwift API**, run it, and see results instantly in the [OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport) demo app.

This is the OCCTSwift equivalent of CadQuery or OpenSCAD — write parametric, constraint-based CAD code and get visual + file feedback immediately.

## Quick Start

```bash
# Build (first time ~30s, incremental ~1-2s)
swift build

# Edit Sources/Script/main.swift with your geometry code, then:
swift run Script
```

In the OCCTSwiftViewport demo app (macOS): sidebar > **File & Tools > Script Watcher** > toggle on. Geometry auto-reloads on each run.

## occtkit CLI

A single multi-call binary bundles all the headless verbs. After install (or via `swift run occtkit ...` from a checkout) you can run any of them by name.

```bash
# install to /usr/local/bin (creates symlinks: graph-validate, drawing-export, ...)
make install                 # or: make install PREFIX=$HOME/.local

# one-shot use
graph-validate body.brep
graph-compact in.brep out.brep
graph-query graph.sqlite
graph-ml part.brep --uv-samples 16 --edge-samples 32 > part.json
feature-recognize bracket.brep
dxf-export bracket.brep bracket.dxf --view 0,0,1
echo '{"shape":"part.brep","output":"sheet.dxf","sheet":{"size":"a3","orientation":"landscape","projection":"third","scale":"auto"},"title":{"title":"Part"},"views":[{"name":"front"},{"name":"top"},{"name":"right"}]}' | drawing-export
echo '{"outputDir":"/tmp/out","outputName":"shaft","features":[{"kind":"revolve","id":"shaft","profile_points_2d":[[0,0],[10,0],[10,40],[0,40]],"axis_origin":[0,0,0],"axis_direction":[0,0,1],"angle_deg":360}]}' | reconstruct
occtkit run my_script.swift --format brep,graph-sqlite

# service mode: read JSONL `{"args":[...]}` requests on stdin, get one JSONL
# envelope per request — `{"ok":true|false,"exit":N,"stdout":"...","stderr":"...","error":"..."?}`.
# The subcommand's own stdout/stderr (and inherited child-process output) are
# captured *into* the envelope, not leaked.
printf '{"args":["a.brep"]}\n{"args":["b.brep"]}\n' | occtkit graph-validate --serve

# uninstall
make uninstall
```

Subcommands (26 verbs as of v0.8.1):

| Domain | Verbs |
|---|---|
| Script host | `run` |
| Topology graph | `graph-validate`, `graph-compact`, `graph-dedup`, `graph-query`, `graph-ml` |
| Drawings & export | `dxf-export`, `drawing-export` |
| Composition | `compose-sheet-metal`, `reconstruct` |
| Construction | `transform`, `boolean`, `pattern` |
| Introspection | `metrics`, `query-topology`, `measure-distance`, `feature-recognize` |
| I/O | `load-brep`, `import` |
| Engineering analysis | `check-thickness`, `analyze-clearance`, `heal` |
| Mesh | `mesh`, `simplify-mesh` |
| Render | `render-preview` |
| XCAF | `inspect-assembly`, `set-metadata` |

`occtkit --help` lists them with one-line summaries. Each verb accepts both flag-form and JSON-form (stdin or file path) input, plus a generic `--serve` mode that reads JSONL `{"args":[...]}` requests and emits JSONL envelopes — used by OCCTMCP and any other JSON-driven consumer.

> **Note**: 2D constraint solving (previously the `solve-sketch` verb) has been removed from occtkit to keep this project free of closed-source dependencies. Downstream consumers that need constraint-based sketch solving should wire up their own solver (e.g., via a separate CLI) and call it outside occtkit.

**`drawing-export`** produces a complete ISO 128-30 multi-view technical drawing as DXF R12: ISO 5457 sheet border + centring marks, ISO 7200 title block (with material / weight / revision / sheet number / etc.), ISO 5456-2 first/third-angle projection symbol, HLR orthographic views, section views (auto-hatched per ISO 128-50), cutting-plane lines + labels (ISO 128-40), auto-centerlines (revolution axes) + auto-centermarks (circular features), ISO 6410 cosmetic threads, ISO 1302 surface-finish symbols, ISO 1101 GD&T feature-control frames, detail views, and user-specified linear/radial/diameter/angular dimensions. ISO 5455 standard scales auto-snap. Reads a JSON spec on stdin or from an argv path. See `Sources/occtkit/Drawing/Spec.swift` for the full schema. Implementation orchestrates OCCTSwift v0.147+ primitives — see CLAUDE.md for the exact API set.

**`reconstruct`** builds a BREP from a JSON `[FeatureSpec]` payload via OCCTSwift's `FeatureReconstructor`. Request schema `{outputDir, outputName?, features:[…]}` where each feature has `kind` (`revolve`/`extrude`/`hole`/`thread`/`fillet`/`chamfer`) and snake_case fields. Closes #3.

For `occtkit run`: by default the cached SPM workspace under `~/.occtswift-scripts/runner-cache/workspace/` references this package via a path dep auto-detected from the running binary; override with `OCCTKIT_SCRIPTS_PATH=/path/to/OCCTSwiftScripts` or fall back to the published remote tag.

### Deprecated standalone targets

Each verb also has a per-target standalone executable (`GraphValidate`, `OCCTRunner`, etc.). These are **deprecated** and print a notice to stderr on startup. They will be removed in a future release; migrate to the equivalent `occtkit <verb>` subcommand at your convenience.

## What You Can Do

The script has access to the **entire OCCTSwift API** (~400+ methods):

| Category | Examples |
|----------|---------|
| **Primitives** | `Shape.box`, `.cylinder`, `.sphere`, `.cone`, `.torus`, `.wedge` |
| **Sketches** | `Wire.rectangle`, `.circle`, `.polygon`, `.ellipse`, `.arc`, `.helix` |
| **Extrude/Revolve** | `Shape.extrude(profile:direction:length:)`, `.revolve(axis:angle:profile:)` |
| **Sweep/Loft** | `Shape.sweep(profile:along:)`, `.loft(profiles:)`, `.pipeShell(...)` |
| **Booleans** | `.union(with:)`, `.subtracting(_:)`, `.intersection(with:)`, `.split(by:)` |
| **Fillets/Chamfers** | `.filleted(radius:)`, `.chamfered(distance:)`, `.blendedEdges(...)` |
| **Holes/Features** | `.drilled(at:direction:radius:depth:)`, `.withPocket(...)`, `.withBoss(...)` |
| **Offset/Shell** | `.offset(by:)`, `.shelled(thickness:)` |
| **Transforms** | `.translated(by:)`, `.rotated(axis:angle:)`, `.scaled(by:)`, `.mirrored(...)` |
| **Patterns** | `.linearPattern(direction:spacing:count:)`, `.circularPattern(...)` |
| **Analysis** | `.volume`, `.surfaceArea`, `.centerOfMass`, `.bounds`, `.distance(to:)` |
| **Healing** | `.healed()`, `.fixed(tolerance:)`, `.unified(...)`, `.simplified(...)` |
| **Curves** | `Curve2D`, `Curve3D` — bezier, bspline, approximate, intersect |
| **Surfaces** | `Surface.plane`, `.bezier`, `.bspline`, `.pipe`, `.revolution`, `.extrusion` |
| **2D Solvers** | `Curve2D.GccAna` — tangent circles/lines, constraint solvers |
| **File I/O** | `Shape.load(from:)`, `.loadSTEP`, `.loadBREP`, `Document` (XDE assembly) |
| **GD&T** | `Document.dimensions`, `.geomTolerances`, `.datums` |

## How It Works

```
Sources/Script/main.swift    ──swift run──>  ~/.occtswift-scripts/output/
                                                ├─ manifest.json   (trigger file)
                                                ├─ body-0.brep     (wire sketch)
                                                ├─ body-1.brep     (filleted solid)
                                                ├─ body-2.brep     (bolt assembly)
                                                └─ output.step     (combined, for external tools)
                                                        │
                                              kqueue watcher (demo app)
                                                        │
                                                  viewport displays
```

1. `ScriptContext` writes each body as a `.brep` file (~1ms each)
2. `emit()` writes a combined `output.step` for external tool interop (ezdxf, FreeCAD, etc.)
3. `emit()` writes `manifest.json` last — the file watcher triggers on this

## API Reference

### Adding Geometry

```swift
let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// Solid shapes
try ctx.add(shape, id: "part", color: C.steel, name: "Bracket")

// Wire profiles / sketches (displayed as wireframe)
try ctx.add(wire, id: "sketch", color: C.yellow)

// Single edges
try ctx.add(edge, id: "axis", color: C.red)

// Multiple shapes as compound
try ctx.addCompound([shape1, shape2], id: "assembly", color: C.gray)
```

### ScriptContext.add (Shape)

| Parameter | Type | Description |
|-----------|------|-------------|
| `shape` | `Shape` | Any OCCTSwift shape (solid, shell, compound, face) |
| `id` | `String?` | Body identifier (default: `"body-N"`) |
| `color` | `[Float]?` | RGBA as `[r, g, b, a]` (0-1 range) |
| `name` | `String?` | Display name |
| `roughness` | `Float?` | PBR roughness (reserved) |
| `metallic` | `Float?` | PBR metallic (reserved) |

### ScriptContext.add (Wire)

Same parameters as Shape (minus roughness/metallic). Wire is converted to a Shape internally — BREP preserves wire topology, displayed as wireframe edges.

### ScriptContext.add (Edge)

Same as Wire — single edge converted and preserved.

### ScriptContext.emit

```swift
try ctx.emit(description: "My parametric design")
```

Writes `manifest.json` (viewport trigger) and `output.step` (external tools). Call **last**.

### Predefined Colors

```swift
let C = ScriptContext.Colors.self
// C.red, C.green, C.blue, C.yellow, C.orange, C.purple,
// C.cyan, C.white, C.gray, C.steel, C.brass, C.copper
```

### Disabling STEP Export

```swift
let ctx = ScriptContext(exportSTEP: false)  // BREP only, faster
```

## Example: Parametric Bracket

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// 1. Sketch L-shaped profile
let profile = Wire.polygon([
    SIMD2(0, 0), SIMD2(40, 0), SIMD2(40, 5),
    SIMD2(5, 5), SIMD2(5, 25), SIMD2(0, 25),
])!
try ctx.add(profile, id: "sketch", color: C.yellow)

// 2. Extrude → fillet → drill
let solid = Shape.extrude(profile: profile, direction: SIMD3(0, 0, 1), length: 20)!
let filleted = solid.filleted(radius: 1.5) ?? solid
let bracket = filleted.drilled(at: SIMD3(20, 2.5, 10), direction: SIMD3(0, 1, 0), radius: 3, depth: 10) ?? filleted
try ctx.add(bracket, id: "bracket", color: C.steel)

// 3. Pattern bolt holes
let hole2 = bracket.drilled(at: SIMD3(30, 2.5, 10), direction: SIMD3(0, 1, 0), radius: 3, depth: 10) ?? bracket
try ctx.add(hole2, id: "final", color: C.steel)

try ctx.emit(description: "Parametric L-bracket")
```

## Output Directory

`~/.occtswift-scripts/output/` — cleaned on each run.

- **BREP files**: loaded by viewport app, preserves exact B-Rep topology
- **output.step**: combined geometry for external tools (FreeCAD, ezdxf, STEPUtils, etc.)
- **manifest.json**: body metadata (IDs, colors, names)

## Use as an SPM library

`ScriptHarness` and `DrawingComposer` are exposed as library products for in-process consumers:

```swift
.package(url: "https://github.com/gsdali/OCCTSwiftScripts.git", from: "0.8.1"),
```

```swift
.product(name: "ScriptHarness", package: "OCCTSwiftScripts"),
.product(name: "DrawingComposer", package: "OCCTSwiftScripts"),
```

The `occtkit` executable is a separate target — install via the `Makefile` above when you want the command-line surface.

## Requirements

- macOS 15+
- Swift 6.0+
- [OCCTSwift](https://github.com/gsdali/OCCTSwift) `>= 0.165.0` (resolved transitively via SPM; xcframework rebuilt against OCCT 8.0.0 beta1, will move to OCCT 8.0.0 GA in v0.9.0)
- [OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport) `>= 0.55.0` (transitive; powers `render-preview`)
- [OCCTSwiftTools](https://github.com/gsdali/OCCTSwiftTools) `>= 0.4.1` (transitive; bridge layer used by `render-preview` for Shape→ViewportBody conversion — split out of OCCTSwiftViewport at v0.55.0)
- [OCCTSwiftMesh](https://github.com/gsdali/OCCTSwiftMesh) `>= 0.1.0` (transitive; powers `simplify-mesh`)
