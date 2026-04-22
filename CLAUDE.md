# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OCCTSwiftScripts is a script harness for rapid OCCTSwift geometry iteration — the OCCTSwift equivalent of CadQuery or OpenSCAD — plus a headless CLI (`occtkit`) bundling reusable verbs (graph-validate, solve-sketch, etc.) for downstream consumers (OCCTDesignLoop, OCCTMCP, Python pipelines).

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
- **occtkit** (executable product) — multi-call umbrella binary. Dispatches by `argv[0]` basename (busybox-style symlinks installed by the Makefile) or by first positional arg (`occtkit graph-validate ...`). Each verb lives in `Sources/occtkit/Commands/<Verb>.swift` conforming to the `Subcommand` protocol in `Sources/occtkit/Subcommand.swift`. Verbs: `run` (script-host, replaces standalone OCCTRunner), `graph-validate`, `graph-compact`, `graph-dedup`, `graph-query`, `graph-ml`, `feature-recognize`, `solve-sketch`, `dxf-export`. **This is the recommended surface going forward.**
- **Standalone targets (DEPRECATED — preserved for downstream compatibility)** — `OCCTRunner`, `GraphValidate`, `GraphCompact`, `GraphDedup`, `GraphQuery`, `GraphML`, `FeatureRecognize`, `SolveSketch`. Each `main.swift` prints a deprecation notice to stderr on startup but otherwise functions identically. They will be removed in a future release; consumers should migrate to the umbrella subcommands.

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

- **OCCTSwift** — `https://github.com/gsdali/OCCTSwift.git` (>= 0.140.0; tracks the engineering-drawings stack: axes, dimensions, DXF export, thread features, GD&T write path). Provides ~400+ methods for parametric CAD.
- **swiftGCS** — `https://github.com/gsdali/swiftGCS.git` (>= 0.1.1; required for `solve-sketch`).
- **macOS 15+**, **Swift 6.0+** (toolchain 6.3+ needed locally because the swiftGCS dep uses tools-version 6.3).
