# CLAUDE.md

## Project Overview

OCCTSwiftScripts is a script harness for rapid OCCTSwift geometry iteration. It writes BREP files + a JSON manifest to `~/.occtswift-scripts/output/`, which the OCCTSwiftViewport demo app watches and auto-loads.

## Build & Run

```bash
swift build          # First build ~30s, incremental ~1-2s
swift run Script     # Runs Sources/Script/main.swift
```

## Structure

- `Sources/ScriptHarness/` — library with `ScriptContext` and manifest types
- `Sources/Script/main.swift` — user-editable geometry script

## Dependencies

- OCCTSwift (local path: `../OCCTSwift`)

## Key Design Decisions

- **BREP format** for output (~1ms write vs ~50ms for STEP)
- **Manifest-last write order**: all BREPs written first, `manifest.json` last (trigger file)
- **Clean on init**: `ScriptContext` clears previous output to avoid stale geometry
- **macOS only**: script workflow targets CLI usage
