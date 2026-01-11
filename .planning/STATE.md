# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-10)

**Core value:** When storage suddenly drops, users can immediately see what consumed it.
**Current focus:** Phase 1 — Menu Bar Foundation (MVP refactor)

## Current Position

Phase: 1 of 5 (Menu Bar Foundation)
Plan: 1 of TBD in current phase
Status: In progress
Last activity: 2026-01-11 — Completed 01-01-PLAN.md

Progress: ████░░░░░░ 20% (Menu bar foundation complete)

## Performance Metrics

**Velocity:** 18 min for first plan (3 tasks)

## Accumulated Context

### Decisions

| Phase | Decision | Rationale |
|-------|----------|-----------|
| MVP-00 | Pivot to menu bar-only app | Simpler UX, focused scope, faster to MVP |
| MVP-00 | Single baseline, no historical snapshots | Reduces complexity, sufficient for MVP |
| MVP-00 | FSEvents with 2-5s debounce | Real-time updates without spamming rescans |
| MVP-00 | Smart drill-down with 70% threshold | Surfaces actual culprit folder |
| MVP-00 | View-only (no cleanup) in MVP | "Reveal in Finder" only, defer delete operations |
| 01-01 | LSUIElement = YES for Dock-less operation | Menu bar apps should not appear in Dock |
| 01-01 | .transient popover behavior | Auto-closes on outside click for better UX |
| 01-01 | Simplified GB display (no decimals) | Compact format for menu bar |
| 01-01 | Preserve legacy code in Legacy/ directory | Retain for reference during refactor |

### Deferred Issues

None.

### Roadmap Evolution

- 2026-01-11: Pivoted to menu bar MVP — archived original ROADMAP to OLD_ROADMAP.md
- 2026-01-11: Completed 01-01 (Menu Bar Foundation) — NSStatusItem, popover, free space display

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-01-11
Stopped at: Completed 01-01-PLAN.md (Menu Bar Foundation)
Resume file: None

## Legacy Code Reference

Legacy full-window app code moved to:
- `Prunr/Legacy/PrunrApp_Legacy.swift` — Original @main app entry point (@main removed)

**Reusable components** (kept):
- `DatabaseManager.swift` — SQLite/GRDB layer
- `FileScanner.swift` — File system scanning
- `ScanService.swift` — Scan orchestration (to be adapted)
- `DeltaService.swift` — Delta calculations (to be simplified)
- All `Models/` — Data structures
