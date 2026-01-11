# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-10)

**Core value:** When storage suddenly drops, users can immediately see what consumed it.
**Current focus:** Phase 5 — Settings & Polish (in progress)

## Current Position

Phase: 5 of 5 (Settings & Polish)
Plan: In progress
Status: Settings feature with scan progress implemented
Last activity: 2026-01-11 — Implemented auto-sacn on file change

Progress: █████████▓ 95% (Settings + scan progress + auto-scan)

## Performance Metrics

**Velocity:**
- 01-01: 18 min (3 tasks)
- 02-01: 8 min (3 tasks)
- 02-02: 25 min (3 tasks)

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
| 02-01 | Test FDA by accessing /Library | macOS has no direct API for permission status |
| 02-02 | 3-second debounce for FSEvents | Balances responsiveness with spam prevention |
| 05-xx | macOS design guide: 6pt radius, 5pt inset, 28pt rows | Native feel per user research |
| 05-xx | Checkbox toggles for paths/boundaries | Simpler UX than separate enable/disable |
| 05-xx | Paths Save button resets baseline | Ensures fresh baseline after config changes |
| 05-xx | Scan progress with stop button | User can cancel slow scans |
| 05-xx | Manual scan trigger on open | Prevents "stuck" feeling, gives user control |
| 05-xx | Auto-scan on file changes | Updates popup seamlessly in background |

### Deferred Issues

None.

### Roadmap Evolution

- 2026-01-11: Implemented Phase 5 Settings — SettingsStore, 5-tab SettingsView, Debug tab
- 2026-01-11: Added scan progress display with stop button
- 2026-01-11: Added paths save button with baseline invalidation
- 2026-01-11: Popup now shows "Create Baseline" when none exists
- 2026-01-11: Changed popup to check baseline only (no auto-scan) with "Scan Now" button
- 2026-01-11: Refactored MenuBarManager to handle state and auto-scan on FSEvents

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-01-11
Stopped at: Phase 5 Settings — Polish & Workflow refinements
Resume file: None

## Key Files Changed (This Session)

- `SettingsStore.swift` — Enable/disable paths and boundaries with persistence
- `SettingsView.swift` — 5 tabs, paths save button, debug test data creation
- `MenuBarView.swift` — Uses MenuBarManager, manual scan buttons
- `MenuBarManager.swift` — State management, auto-scan logic, disk space tracking
- `MenuBarViewModel.swift` — Deprecated/Removed

## Recent Commits

- `63e1cfd` — Refactor: Move logic to MenuBarManager, implement auto-scan on file change
- `3059d85` — UI Polish: Manual scan trigger, no auto-scan on open, scan progress display
- `247dbe7` — Settings paths save button, scan progress, stop button, baseline recheck

## Legacy Code Reference

Legacy full-window app code moved to:
- `Prunr/Legacy/PrunrApp_Legacy.swift` — Original @main app entry point (@main removed)

**Reusable components** (kept):
- `DatabaseManager.swift` — SQLite/GRDB layer
- `FileScanner.swift` — File system scanning
- `ScanService.swift` — Scan orchestration with progress callbacks
- `BaselineService.swift` — Baseline management
- All `Models/` — Data structures
