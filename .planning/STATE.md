# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-10)

**Core value:** When storage suddenly drops, users can immediately see what consumed it.
**Current focus:** Phase 5 — Settings & Polish

## Current Position

Phase: 5 of 5 (Settings & Polish)
Plan: In progress
Status: Settings feature implemented
Last activity: 2026-01-11 — Implemented Settings with checkbox paths/boundaries, Debug tab

Progress: ████████░░ 80% (Settings + UI polish complete, verification pending)

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
| 01-01 | Preserve legacy code in Legacy/ directory | Retain for reference during refactor |
| 02-01 | Test FDA by accessing /Library | macOS has no direct API for permission status |
| 02-01 | System Settings via x-apple.systempreferences URL | Direct deep-link to Full Disk Access pane |
| 02-01 | Case-sensitive boundary matching | macOS APFS default |
| 02-02 | 3-second debounce for FSEvents | Balances responsiveness with spam prevention |
| 02-02 | FSEventStream with 0.5s latency | CoreServices API requirement |
| 02-02 | Actor isolation for FSEventsWatcher | Thread-safe stream management |
| 02-02 | Async startWatching for proper actor isolation | Swift concurrency requirement |
| 05-xx | macOS design guide: 6pt radius, 5pt inset, 28pt rows | Native feel per user research |
| 05-xx | Checkbox toggles for paths/boundaries | Simpler UX than separate enable/disable |
| 05-xx | Debug tab with varied test data | Easier testing with realistic folder structure |

### Deferred Issues

None.

### Roadmap Evolution

- 2026-01-11: Pivoted to menu bar MVP — archived original ROADMAP to OLD_ROADMAP.md
- 2026-01-11: Completed 01-01 (Menu Bar Foundation) — NSStatusItem, popover, free space display
- 2026-01-11: Completed 02-01 (Permissions + Boundaries) — FDA detection, BoundaryConfig
- 2026-01-11: Completed 02-02 (FSEvents Watcher) — FSEventStream with debounce
- 2026-01-11: Implemented Phase 5 Settings — SettingsStore, 5-tab SettingsView, Debug tab

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-01-11
Stopped at: Phase 5 Settings implementation — UI polish in progress
Resume file: None

## Key Files Changed (This Session)

- `SettingsStore.swift` — UserDefaults persistence for paths, boundaries, threshold, launch at login
- `SettingsView.swift` — 5 tabs (General, Paths, Boundaries, Debug, About)
- `MenuBarView.swift` — macOS design guide hover states
- `GrowthListView.swift` — macOS design guide hover states
- `TrackedPath.swift` — Added test_data to default paths
- `documentation/macos_design-guide.md` — User-provided design specs

## Legacy Code Reference

Legacy full-window app code moved to:
- `Prunr/Legacy/PrunrApp_Legacy.swift` — Original @main app entry point (@main removed)

**Reusable components** (kept):
- `DatabaseManager.swift` — SQLite/GRDB layer
- `FileScanner.swift` — File system scanning
- `ScanService.swift` — Scan orchestration (to be adapted)
- `DeltaService.swift` — Delta calculations (to be simplified)
- All `Models/` — Data structures
