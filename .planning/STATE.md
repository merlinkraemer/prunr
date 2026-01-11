# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-01-10)

**Core value:** When storage suddenly drops, users can immediately see what consumed it.
**Current focus:** Phase 7 — Category-Based Growth View (In Progress)

## Current Position

**MVP Status:** Complete (5/5 phases)
- Phase 1: Menu Bar Foundation ✓
- Phase 2: FSEvents + Permissions ✓
- Phase 3: Baseline & Growth ✓
- Phase 4: Menu Bar UI ✓ (incl. 04-02-FIX for UI issues)
- Phase 5: Settings & Polish ✓
- Phase 6: Popup HIG Redesign (Not Planned)
- Phase 7: Category-Based Growth View (2/4 plans complete)

Last activity: 2026-01-12 — Completed 07-02: Category Growth Aggregation.

Progress: ██████████ 100% MVP | Post-MVP: Phase 07 (2/4 plans)

**Phase Structure:**
- Active MVP phases: `01-menubar-foundation`, `02-fsevents-monitoring`, `03-baseline-growth-tracking`, `04-menubar-ui`, `05-settings-polish`
- Post-MVP phases: `06-popup-hig-redesign`, `07-category-growth-view`
- Archived: Old full-window app plans moved to `.planning/phases/_archived-full-window-app/`
- Note: Phase 05 (Settings & Polish) was implemented without formal GSD planning; retrospective PLAN.md and SUMMARY.md created 2026-01-11
- Note: Phase 07 plan created 2026-01-12 from documentation/grouping_feature_spec.md

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
| 07-01 | Category-based growth view as Phase 07 | Significant feature addition, transforms growth display |
| 07-01 | Create new GrowthCategory model | Clean slate, spec-driven design vs legacy DeltaCategory |
| 07-01 | Hardcode 100MB big file threshold | Simpler for v1, configurable later if needed |
| 07-01 | View mode toggle (Folders/Categories) | Users choose between folder and category views |
| 07-01 | Defer category-specific drill-down | Focus on aggregation/display first, drill-down later |
| 07-02 | getCategoryGrowthList() in BaselineService | Parallel API for category-based growth data |
| 07-02 | GrowthItem.isBigFile computed property | Reuses CategoryGrowthItem.bigFileThreshold for consistency |
| 07-02 | GrowthItem.category computed property | Lazy evaluation for category detection |

### Deferred Issues

None.

### Roadmap Evolution

**Menu Bar MVP (Current Roadmap):**
- 2026-01-11: Phase 1 (Menu Bar Foundation) — NSStatusItem, popover, LSUIElement
- 2026-01-11: Phase 2 (FSEvents + Permissions) — FSEventsWatcher, Full Disk Access handling, 3s debounce
- 2026-01-11: Phase 3 (Baseline & Growth) — BaselineService, drill-down algorithm
- 2026-01-11: Phase 4 (Menu Bar UI) — DriveBarView, GrowthListView, MenuBarViewModel
- 2026-01-11: Phase 4 (04-02-FIX) — UI polish: DriveBar redesign, Settings window, right-click menu, native list footer
- 2026-01-11: Phase 5 (Settings & Polish) — SettingsStore, 5-tab SettingsView, paths configuration, scan progress, test data creation, macOS design compliance
  - Retrospective PLAN.md/SUMMARY.md created 2026-01-11 to document completed work
- 2026-01-11: Phase 6 (Popup HIG Redesign) — Post-MVP phase for Apple HIG compliance (main list, settings, path boundaries, about section)
- 2026-01-12: Phase 7 (Category-Based Growth View) — Post-MVP phase for category-based grouping (GrowthCategory, CategoryDetectionService, CategoryGrowthListView)

**Archived (2026-01-11):** Full-window app plans moved to `.planning/phases/_archived-full-window-app/`:
- 01-foundation, 02-scanner-storage, 03-delta-engine, 05-frontend-redesign

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-01-12
MVP Status: Complete (all 5 phases finished)
Phase 07: 2/4 plans complete (07-01, 07-02), ready for 07-03
Resume file: None

## Key Files Changed (Final MVP)

**Core Services:**
- `FSEventsWatcher.swift` — File system monitoring with 3s debounce
- `FSEventsService.swift` — Lifecycle management for FSEvents
- `BaselineService.swift` — Baseline creation, growth calculation, nested aggregation
- `ScanService.swift` — Targeted folder scanning

**UI Components:**
- `PrunrMenuBar.swift` — NSStatusItem setup and popover presentation
- `MenuBarManager.swift` — Singleton for menu bar state, context menu, test data
- `MenuBarView.swift` — Main popover with drive bar, growth list, scan progress
- `DriveBarView.swift` — Visual capacity bar with percentage
- `GrowthListView.swift` — Scrollable list of growth items
- `SettingsView.swift` — 5-tab settings window (Paths, Boundaries, Threshold, Debug, About)

**Data Layer:**
- `SettingsStore.swift` — UserDefaults persistence for app settings
- `TrackedPath.swift` — Monitored path model with enable/disable
- `BoundaryConfig.swift` — Known boundary folder definitions

## Recent Commits

- `7ddca87` — Feat: 'Create Test Data' context menu, Fix Settings popup sync
- `a7e9c34` — Fix: Popup state sync, Default paths to TestData only
- `0c7f6d3` — Fix: Aggregate nested growth in BaselineService, Add monitored path to UI
- `efbca50` — Checkpoint: Update state and cleanup

**MVP Complete:** All 5 phases of menu bar app finished.

## Legacy Code Reference

Legacy full-window app code moved to:
- `Prunr/Legacy/PrunrApp_Legacy.swift` — Original @main app entry point (@main removed)
- `.planning/phases/_archived-full-window-app/` — Archived plans from old roadmap:
  - 01-foundation (Xcode project + GRDB)
  - 02-scanner-storage (Scanner + SQLite)
  - 03-delta-engine (Delta calculation)
  - 05-frontend-redesign (DaisyDisk-style full-window UI)
