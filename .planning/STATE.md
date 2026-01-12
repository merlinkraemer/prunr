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
- Phase 7.1: Layout Fixes (2/2 plans complete) - Category list with nested big files, distinct icon colors, stable layout, slide-in navigation, polished drill-down

Last activity: 2026-01-12 — Completed 7.1-02: Slide-in navigation + drill-down polish.

Progress: ██████████ 100% MVP | Post-MVP: Phase 7.1 complete

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
| 07-03 | Complete replacement (no toggle) per CONTEXT.md | Folder list becomes category list, no hybrid view |
| 07-03 | Color-coded severity for categories | Green <1GB, Orange 1-5GB, Red >=5GB |
| 07-03 | CategoryGrowthListView expandable hierarchy | Categories expand, big items nested, small items collapsed |
| 07-03 | Deferred category-specific drill-down | Focus on UI/UX first, drill-down later |
| 07-04 | Implemented category drill-down UX | Click category → show detail view with all items |
| 07-04 | Added allItems to CategoryGrowthItem | Enables drill-down to show all category items |
| 07-04 | Path normalization with tilde expansion | Accurate ~/ path matching for categorization |
| 07-04 | Test data creates category-matching paths | Library/Caches, node_modules, .Trash patterns |
| 07-04 | 105MB big file in test data | Tests >=100MB threshold for big file display |
| 07-04 | Drill-down navigation pattern | Back button returns to category list |
| 7.1-01 | Show max 3 big files inline in category list | Prevents overwhelming list while surfacing large items |
| 7.1-01 | Distinct category colors for icons | Uses GrowthCategory.color instead of severity colors |
| 7.1-01 | Fixed 60pt width for item count text | Prevents layout jitter when counts change |
| 7.1-01 | 32pt indentation for nested big items | Creates clear visual hierarchy |
| 7.1-01 | Visual separator between category groups | Thin gray line (1pt, 15% opacity) |
| 7.1-02 | Finder-style slide-in navigation | ZStack with offset animations (80% push left, slide from right) |
| 7.1-02 | 300ms easeInOut animation timing | Natural Finder-like feel for transitions |
| 7.1-02 | Background dimming during drill-down | 10% black overlay focuses attention on detail view |
| 7.1-02 | Navigation bar styling for detail header | Bottom border, shadow, larger font for visual hierarchy |
| 7.1-02 | Fixed header with scrollable content | Header stays at top, items scroll beneath |

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
- 2026-01-12: Phase 7.1 inserted after Phase 7: Layout Fixes (URGENT) — Big file nesting, drill-down redesign, slide-in navigation, icon colors, layout stability

**Archived (2026-01-11):** Full-window app plans moved to `.planning/phases/_archived-full-window-app/`:
- 01-foundation, 02-scanner-storage, 03-delta-engine, 05-frontend-redesign

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-01-12
MVP Status: Complete (all 5 phases finished)
Phase 7.1: Complete (2/2 plans) - Category list layout fixes with slide-in navigation
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
