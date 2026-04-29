# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OCCTSwiftScripts is a script harness for rapid OCCTSwift geometry iteration — the OCCTSwift equivalent of CadQuery or OpenSCAD — plus a headless CLI (`occtkit`) bundling reusable verbs (graph-validate, drawing-export, etc.) for downstream consumers (OCCTMCP, Python pipelines).

**Open-source boundary**: LGPL-2.1, depends only on open-source Swift packages (OCCTSwift). No closed-source transitive deps; constraint-solving (previously `solve-sketch`) was removed when the swiftGCS dep was dropped — downstream closed-source consumers wire their own solver.

See `docs/SCRIPT_WORKFLOW.md` for the script iteration workflow.

## Build & Run

```bash
swift build                                  # First build ~30s, incremental ~1-2s
swift run Script                             # Build & execute Sources/Script/main.swift
swift run occtkit <subcommand> [args...]     # Run any verb directly from the build tree
make install [PREFIX=...]                    # Release build + install occtkit + verb symlinks to $PREFIX/bin
```

No tests exist. No linter is configured.

## Architecture

**Targets** (see `Package.swift`):

- **ScriptHarness** (library product) — `ScriptContext` accumulates geometry, writes BREP files immediately on `add()`, then writes `manifest.json` on `emit()`. Also exposed as an SPM library product so external projects can `import ScriptHarness`. Includes `BREPGraphJSONExporter`, `BREPGraphSQLiteExporter`, and `GraphIO` (shared helpers used by every `occtkit` command and every standalone target — argv parsing, BREP load/write, graph→shape rebuild, JSON emission, all throwing on failure so the `--serve` loop can recover).
- **Script** (executable) — `Sources/Script/main.swift`, the user-editable iteration scratchpad. Imports `ScriptHarness` and `OCCTSwift` directly.
- **occtkit** (executable product) — multi-call umbrella binary. Dispatches by `argv[0]` basename (busybox-style symlinks installed by the Makefile) or by first positional arg (`occtkit graph-validate ...`). Each verb lives in `Sources/occtkit/Commands/<Verb>.swift` conforming to the `Subcommand` protocol in `Sources/occtkit/Subcommand.swift`. Verbs: `run` (script-host, replaces standalone OCCTRunner), `graph-validate`, `graph-compact`, `graph-dedup`, `graph-query`, `graph-ml`, `feature-recognize`, `dxf-export`, `drawing-export`, `reconstruct`, `compose-sheet-metal`, `transform`, `boolean`, `pattern`, `metrics`, `query-topology`, `measure-distance`. **This is the recommended surface going forward.**

**`drawing-export`** is the multi-view ISO technical drawing orchestrator. Its support code lives in `Sources/occtkit/Drawing/` (`Spec.swift`, `MultiViewLayout.swift`). The verb consumes a JSON spec and produces a single DXF R12 sheet by composing OCCTSwift v0.147+ primitives: `Sheet.render` (ISO 5457 border + ISO 7200 title block + ISO 5456-2 projection symbol), `Drawing.project` per view, `Drawing.bounds` for autoscale, `Drawing.transformed` + `DXFWriter.collectFromDrawing` for placement, `Shape.section2DView` (auto-hatched per ISO 128-50), `Drawing.addCuttingPlaneLine` (ISO 128-40), `Drawing.addAutoCentrelines` + `addAutoCentermarks`, `Drawing.addCosmeticThreadSide` (ISO 6410), `DrawingAnnotation.surfaceFinish` (ISO 1302), `DrawingAnnotation.featureControlFrame` (ISO 1101 GD&T), `Drawing.detailView`, and `DrawingScale.preferred` (ISO 5455 snapping). The previously-DIY'd Sheet/PaperSize/SectionExtraction/ViewPlacer files were removed in rc.6 once their upstream equivalents landed.

**`reconstruct`** is the JSON `[FeatureSpec]` → BREP verb. Wraps `FeatureReconstructor.buildJSON(_:inputBody:)` (OCCTSwift v0.147+; `inputBody:` added v0.152; `boolean` JSON decoder branch added v0.152.1). Request schema `{outputDir, outputName?, inputBrep?, features:[<entries>]}` where each entry has a `kind` discriminator (`revolve`/`extrude`/`hole`/`thread`/`fillet`/`chamfer`/`boolean`) and snake_case fields per OCCTSwift's private `FeatureEntry` decoder. When `inputBrep` is supplied, the kernel seeds `BuildContext.current` with it and registers it under `@input` in `namedShapes` — `hole`/`fillet`/`chamfer` cut/finish the input directly; additive features (`extrude`/`revolve`) get unioned onto it via `absorbAdditive`; explicit `{"kind":"boolean","op":"subtract","left":"@input","right":<id>}` entries express non-circular pocket cuts. Unknown `kind` strings with an `id` now surface as `unsupported` skips. Closes #3 and #13.

**`metrics` / `query-topology` / `measure-distance`** are the OCCTMCP-driven introspection verbs (closes #18). Pure read; input BREP(s) → JSON envelope on stdout, no file output. `metrics` wraps `Shape.volumeInertia` (volume + center-of-mass + principal moments/axes) + `Shape.surfaceArea` + `Shape.bounds`; `--metrics` flag selects a subset (default all). `query-topology` iterates `Shape.faces()` / `.edges()` / `.vertices()` and emits stable IDs (`face[N]` / `edge[N]` / `vertex[N]`) with surface/curve type classification, area/length, bounding box, and (face only) the unit normal at the UV midpoint; supports filter keys `surfaceType` / `curveType` / `minArea` / `maxArea` / `minLength` / `maxLength` / `normalDirection` + `normalTolerance`. `measure-distance` wraps `Shape.allDistanceSolutions(to:)` for shape-shape distance + optional contact list; v1 supports `point:x,y,z` refs but defers sub-entity refs (`face[N]` etc.) — callers identify contact provenance via `query-topology`. The same release also extends `graph-validate` with a `healthRecord` field (small-edge / free-edge / self-intersection counts via `Shape.analyze()`) and adds a unified `features:[]` array to `feature-recognize`'s response (alongside the existing `pockets`/`holes` arrays for backward compat).

**`transform` / `boolean` / `pattern`** are the OCCTMCP-driven construction verbs (closes #20). All three are pure functions — input BREP(s) → output BREP file(s) + JSON envelope on stdout, no scene/manifest involvement. Each accepts both flag form (matches the issue spec) and JSON form (stdin or file path) for `--serve` consumers; auto-detected by whether `--kind`/`--op`/`--output` flags are present. `transform` wraps `Shape.translated`/`.rotated`/`.scaled` (uniform only — non-uniform `--scale x,y,z` rejected); Euler XYZ decomposes into three sequential axis-angle rotations. `boolean` dispatches on `--op`, wraps `Shape.union`/`.subtracting`/`.intersection`/`.split`; split's array result is wrapped in `Shape.compound` so the verb always emits a single output BREP. `pattern` wraps `Shape.mirrored` / `.linearPattern` / `.circularPattern`; the linear/circular compound result is decomposed via `subShapes(ofType: input.shapeType)` and written as `pattern_N.brep` files (one per instance).

**`compose-sheet-metal`** is the JSON sheet-metal spec → BREP verb. Wraps `SheetMetal.Builder(thickness:).build(flanges:bends:)` (OCCTSwift v0.151+; v0.153 made bends step-aware via OCCTSwift#86). Request schema `{outputDir, outputName?, thickness, flanges:[{id, profile, origin, uAxis, vAxis?, normal}], bends?:[{from, to, radius}]}`. Kept separate from `reconstruct` because `SheetMetal` lives in its own upstream namespace — the split also reserves room for the planned reverse direction (bent BRep → flat cutting pattern). `SheetMetal.BuildError` is `CustomStringConvertible`, so the verb surfaces the upstream error description verbatim. The v0.151 `BuildError.filletFailed` warning on stepped seams (narrow tab on wider base, U-channel, Z-bracket) was resolved in v0.153 — the builder now splits the wider flange at the seam intersection before extruding. New v0.153 errors `seamsDoNotOverlap` / `nonRectangularStepFlange` cover the residual edge cases. Closes #10.
- **Standalone targets (DEPRECATED — preserved for downstream compatibility)** — `OCCTRunner`, `GraphValidate`, `GraphCompact`, `GraphDedup`, `GraphQuery`, `GraphML`, `FeatureRecognize`. Each `main.swift` prints a deprecation notice to stderr on startup but otherwise functions identically. They will be removed in a future release; consumers should migrate to the umbrella subcommands.

**`--serve` mode**: any occtkit subcommand accepts `--serve` to read JSONL requests on stdin (`{"args": [...]}` per line) and write JSONL **envelopes** on stdout — one envelope per request, success or failure: `{"ok": bool, "exit": int, "stdout": str, "stderr": str, "error": str?}`. The subcommand's own stdout/stderr (and any inherited child-process output, e.g. `swift build` invoked by `run`) are captured into the envelope's `stdout`/`stderr` fields via per-request FD redirection to temp files — they do *not* leak to occtkit's own stdout. EOF on stdin → exit 0. Implemented generically in `Sources/occtkit/main.swift` so every verb supports it identically. Closes #5.

**Output pipeline (Script / `occtkit run`)**: `ScriptContext.add()` writes each body as a `.brep` file → optional graph JSON/SQLite via `addGraphsForAllShapes()` → optional combined `output.step` → `manifest.json` last. Manifest-last write order means a partial failure leaves the previous frame visible in the viewport rather than a half-written manifest.

**Output location**: iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) if available, otherwise `~/.occtswift-scripts/output/`. Cleaned on `ScriptContext` init.

**`occtkit run` workspace** (`Sources/occtkit/Commands/Run.swift`): cached SPM workspace at `~/.occtswift-scripts/runner-cache/workspace/`. Resolves the ScriptHarness dep in this order: (1) `$OCCTKIT_SCRIPTS_PATH` if set, (2) auto-detected from the running binary's `argv[0]` (works for `swift run occtkit ...`), (3) fallback to remote `from: "0.2.0"`.

## Key Conventions

- **Swift 6 strict concurrency**: all targets use `.swiftLanguageMode(.v6)`. `ScriptContext` is `Sendable` via a private NSLock-based `LockedArray`.
- **Colors** are `[Float]` RGBA (0–1), with predefined constants on `ScriptContext.Colors` (e.g., `.steel`, `.brass`, `.copper`).
- **Geometry types accepted by `ScriptContext.add()`**: `Shape` (solids/shells/compounds/faces), `Wire`, `Edge` (the latter two are converted via `Shape.fromWire`/`Shape.fromEdge`).
- **BREP over STEP**: BREP is the primary format (~1ms vs ~50ms for STEP). STEP export is optional (`ScriptContext(exportSTEP: false)` to disable; `occtkit run --format` controls it via source rewriting).
- **TopologyGraph export**: `ctx.addGraph(_)` writes `graph-N.json` (BREPGraph v1) and optionally `graph-N.sqlite`. `ctx.addGraphsForAllShapes(sqlite:)` is a convenience for batch export.
- **occtkit verbs throw, never `exit()`** — required so `--serve` can recover and continue. Use `ScriptError.message(...)` (in `ScriptContext.swift`) for ad-hoc failures; `GraphIO` helpers throw on every failure path. Standalone wrappers catch + exit 1 in their own `main.swift`.
- **Adding a new verb** = one file in `Sources/occtkit/Commands/` plus one entry in `Registry.all` (`Sources/occtkit/Subcommand.swift`). Standalone targets should not gain new verbs; they exist only for legacy compatibility.

## Dependencies

- **OCCTSwift** — `https://github.com/gsdali/OCCTSwift.git` (>= 0.153.0; full ISO drawings stack — Sheet/TitleBlock/PaperSize/ProjectionSymbol/Section2D/Hatch/Drawing.transformed/AutoCentermarks/CuttingPlaneLine/CosmeticThread/SurfaceFinish/GDT/DetailView/DrawingScale, plus FeatureReconstructor for `reconstruct` and `Drawing.append(contentsOf:)` for the DrawingComposer. v0.151 adds the `SheetMetal` namespace used by `compose-sheet-metal`; v0.152 adds `FeatureReconstructor.buildJSON(_:inputBody:)` + the `inputBodySentinel` constant for chained composition; v0.152.1 adds the `boolean` JSON decoder branch + `unsupported` skip on unknown kinds; v0.153 makes `SheetMetal.Builder` bends step-aware). Provides ~400+ methods for parametric CAD.
- **macOS 15+**, **Swift 6.0+**.
