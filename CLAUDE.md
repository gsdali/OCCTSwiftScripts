# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OCCTSwiftScripts is a script harness for rapid OCCTSwift geometry iteration — the OCCTSwift equivalent of CadQuery or OpenSCAD. Edit `Sources/Script/main.swift`, run it, and see results in the OCCTSwiftViewport demo app which watches for output via kqueue.

See `docs/SCRIPT_WORKFLOW.md` for the end-to-end workflow guide (writing scripts, gallery views, promoting code into an app library).

## Build & Run

```bash
swift build              # First build ~30s, incremental ~1-2s
swift run Script         # Build & execute Sources/Script/main.swift
swift run OCCTRunner …   # Run an arbitrary external .swift file (see below)
```

No tests exist. No linter is configured.

## Architecture

**Three targets** (see `Package.swift`):

- **ScriptHarness** (library product) — `ScriptContext` accumulates geometry, writes BREP files immediately on `add()`, then writes `manifest.json` on `emit()`. Also exposed as an SPM library product so external projects can `import ScriptHarness`.
- **Script** (executable) — `main.swift` is the user-editable script. Imports both `ScriptHarness` and `OCCTSwift` directly.
- **OCCTRunner** (executable) — CLI that runs an arbitrary `.swift` file as a script. It maintains a cached SPM workspace under `~/.occtswift-scripts/runner-cache/workspace/`, copies the user's source into it, builds and runs. Supports `--format brep,step,graph-json,graph-sqlite` and `--output <dir>`. When graph formats are requested it injects a `ctx.addGraphsForAllShapes(...)` call before `emit()`; when `step` is omitted it rewrites `ScriptContext()` to disable STEP export.

**Output pipeline**: `ScriptContext.add()` writes each body as a `.brep` file → `emit()` optionally writes a combined `output.step` → `emit()` writes `manifest.json` last (trigger file for the viewport's kqueue watcher). If any topology graphs were added, per-graph `graph-N.json` (and optionally `graph-N.sqlite`) files are also written before the manifest.

**Output location**: iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) if available, otherwise `~/.occtswift-scripts/output/`. Previous output is cleaned on `ScriptContext` init.

## Key Conventions

- **Swift 6 strict concurrency**: all targets use `.swiftLanguageMode(.v6)`. `ScriptContext` is `Sendable` using a private `LockedArray` (NSLock-based).
- **Colors** are `[Float]` RGBA arrays (0-1 range), with predefined constants on `ScriptContext.Colors` (e.g., `.steel`, `.brass`, `.copper`).
- **Geometry types accepted by `add()`**: `Shape` (solids/shells/compounds/faces), `Wire` (profiles/sketches), `Edge`. Wire and Edge are converted to Shape internally via `Shape.fromWire`/`Shape.fromEdge`.
- **BREP over STEP**: BREP is the primary format (~1ms vs ~50ms for STEP). STEP export is optional (`ScriptContext(exportSTEP: false)` to disable).
- **Manifest-last write order**: all BREPs first, then graph exports, then STEP, then `manifest.json` — the watcher triggers on manifest arrival, so any earlier failure leaves no manifest and the viewport keeps the previous frame.
- **Optional manifest metadata**: pass `ManifestMetadata(name:revision:dateCreated:…)` to `ScriptContext` to embed part/project metadata in the manifest.
- **TopologyGraph export**: `ctx.addGraph(graph, …)` writes `graph-N.json` (BREPGraph v1 schema) and optionally `graph-N.sqlite` (per-kind tables, adjacency, analysis views) via `BREPGraphJSONExporter` / `BREPGraphSQLiteExporter`. `ctx.addGraphsForAllShapes(sqlite:)` is a convenience that builds a `TopologyGraph` per added shape.

## Dependencies

- **OCCTSwift** — resolved via SPM from `https://github.com/gsdali/OCCTSwift.git` (>= 0.136.0 — required for `TopologyGraph` / BREPGraph support). Provides ~400+ methods for parametric CAD: primitives, booleans, fillets, sweeps, curves, surfaces, file I/O, etc.
- **macOS 15+**, **Swift 6.0+**
