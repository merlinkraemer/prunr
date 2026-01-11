# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-10)

**Core value:** When storage suddenly drops, users can immediately see what consumed it.
**Current focus:** Phase 5 — Settings & Polish (Complete)

## Current Position

Phase: 5 of 5 (Settings & Polish)
Plan: Completed
Status: All features implemented, verified, and polished.
Last activity: 2026-01-11 — Context menu enhancement and state sync fixes.

Progress: ██████████ 100% (Ready for final review)

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
| 05-xx | Nested growth aggregation | Ensures subfolder growth is visible at top level |
| 05-xx | Default paths limited to Test Data | Improves focus for development testing |
| 05-xx | Context menu 'Create Test Data' | Simplifies testing workflow |

### Deferred Issues

None.

### Roadmap Evolution

- 2026-01-11: Implemented Phase 5 Settings — SettingsStore, 5-tab SettingsView, Debug tab
- 2026-01-11: Added scan progress display with stop button
- 2026-01-11: Added paths save button with baseline invalidation
- 2026-01-11: Popup now shows "Create Baseline" when none exists
- 2026-01-11: Changed popup to check baseline only (no auto-scan) with "Scan Now" button
- 2026-01-11: Refactored MenuBarManager to handle state and auto-scan on FSEvents
- 2026-01-11: Fixed "No Changes" bug by aggregating nested file growth into parent directories
- 2026-01-11: Fixed popup state handling and updated default paths
- 2026-01-11: Added "Create Test Data" to right-click menu and shared logic

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-01-11
Stopped at: Phase 5 Complete
Resume file: None

## Key Files Changed (This Session)

- `SettingsStore.swift` — Enable/disable paths and boundaries with persistence
- `SettingsView.swift` — 5 tabs, paths save button, debug test data creation
- `MenuBarView.swift` — Uses MenuBarManager, manual scan, monitored path, popover close
- `MenuBarManager.swift` — Singleton, context menu, test data logic, popover delegate
- `BaselineService.swift` — Nested growth aggregation
- `TrackedPath.swift` — Default paths update

## Recent Commits

- `a7e9c34` — Fix: Popup state sync, Default paths to TestData only
- `0c7f6d3` — Fix: Aggregate nested growth in BaselineService, Add monitored path to UI
- `efbca50` — Checkpoint: Update state and cleanup

## Legacy Code Reference

Legacy full-window app code moved to:
- `Prunr/Legacy/PrunrApp_Legacy.swift` — Original @main app entry point (@main removed)
