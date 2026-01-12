# Roadmap: Prunr MVP (Menu Bar)

## Overview

Prunr is a lightweight macOS menu bar utility that answers "What ate my disk space?" by tracking what grew since you last checked.

**How It Works:**
1. **BASELINE** → Store folder sizes on first launch/reset
2. **WATCH** → FSEvents monitors paths for changes (2-5s debounce)
3. **SCAN** → Targeted rescans of changed folders only
4. **DRILL-DOWN** → Find deepest meaningful folder (stops at node_modules, .git, etc.)
5. **SHOW** → Menu bar displays growth list with culprit folders

## Domain Expertise

- macOS app development (SwiftUI, AppKit)
- FSEvents framework for file system monitoring
- GRDB/SQLite for data persistence
- NSStatusItem for menu bar apps

## Phases

- [x] **Phase 1: Menu Bar Foundation** - NSStatusItem, no Dock icon, basic popover
- [x] **Phase 2: FSEvents Monitoring + Permissions** - File system watcher with Full Disk Access handling
- [x] **Phase 3: Baseline & Growth Tracking** - Single baseline + smart drill-down algorithm
- [x] **Phase 4: Menu Bar UI** - Drive bar + growth list popover
- [x] **Phase 5: Settings & Polish** - Configurable paths, threshold, boundaries

## Phase Details

### Phase 1: Menu Bar Foundation
**Goal**: Menu bar-only app (no Dock icon, no window on launch)
**Depends on**: Nothing (first phase)
**Research**: Unlikely (standard NSStatusItem patterns)
**Plans**: TBD

**Deliverables:**
- NSStatusItem with free space display
- Click to show popover
- LSUIElement = true (no Dock icon)
- Placeholder popover view

---

### Phase 2: FSEvents Monitoring + Permissions
**Goal**: Background file system watcher with Full Disk Access handling
**Depends on**: Phase 1
**Research**: Unlikely (FSEvents is well-documented)
**Plans**: TBD

**Deliverables:**
- BoundaryConfig with known boundary folders
- FSEventsWatcher actor with debounce
- FSEventsService for lifecycle management
- Full Disk Access detection and prompt

---

### Phase 3: Baseline & Growth Tracking
**Goal**: Single baseline snapshot + growth list with smart drill-down
**Depends on**: Phase 2
**Research**: Unlikely (reuses existing scanner/database)
**Plans**: TBD

**Deliverables:**
- BaselineService with create/reset/getGrowthList
- Drill-down algorithm (70% threshold, stop at boundaries)
- Targeted folder scan in ScanService
- Simplified database schema for single baseline

---

### Phase 4: Menu Bar UI
**Goal**: Popover with drive bar + growth list
**Depends on**: Phase 3
**Research**: Unlikely (SwiftUI patterns)
**Plans**: TBD

**Deliverables:**
- DriveBarView with visual used/free bar
- GrowthListView with clickable items
- MenuBarViewModel for state management
- Reset/Settings/Quit buttons

---

### Phase 5: Settings & Polish
**Goal**: Configurable paths, threshold, boundaries, permissions prompt
**Depends on**: Phase 4
**Research**: Unlikely (standard SwiftUI)
**Plans**: TBD

**Deliverables:**
- SettingsView with paths/threshold/boundaries
- SettingsWindow for modal presentation
- UserDefaults persistence (SettingsStore)
- Animations, empty states, FDA onboarding

---

### Phase 6: Popup HIG Redesign
**Goal**: Redesign main popup layout according to Apple HIG standards
**Depends on**: Phase 5
**Research**: Required (macOS HIG patterns documented)
**Plans**: 0 plans

**Deliverables:**
- Main file list redesign with proper spacing/typography
- Settings pages following HIG preferences patterns
- Path boundaries UI with standard list/table views
- About section following HIG about window pattern
- Apply documented spacing: 20pt margins, 12-24pt spacing, proper row heights

---

### Phase 7: Category-Based Growth View
**Goal**: Transform growth list from folder-based to category-based grouping
**Depends on**: Phase 5
**Research**: Unlikely (spec defined in documentation/grouping_feature_spec.md)
**Plans**: 0 plans

**Deliverables:**
- GrowthCategory enum with 10 categories (Homebrew, node_modules, Downloads, etc.)
- CategoryDetectionService for pattern-based categorization
- CategoryGrowthItem model for category display data
- CategoryGrowthListView with expandable categories
- Big file nesting (>100MB threshold, hardcoded)
- View mode toggle (Folders/Categories) in MenuBarView
- Category growth aggregation in BaselineService

**Source:** documentation/grouping_feature_spec.md

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Menu Bar Foundation | 1/1 | Complete | 2026-01-11 |
| 2. FSEvents + Permissions | 2/2 | Complete | 2026-01-11 |
| 3. Baseline & Growth | 1/1 | Complete | 2026-01-11 |
| 4. Menu Bar UI | 2/2 (incl. fix) | Complete | 2026-01-11 |
| 5. Settings & Polish | 1/1 | Complete | 2026-01-11 |
| 6. Popup HIG Redesign | 0/0 | Not Planned | — |
| 7. Category Growth View | 4/4 | Complete | 2026-01-12 |

**MVP Status:** 🎉 MVP complete (Phase 1-5). Phase 6-7 are post-MVP enhancements.

## Key Differentiators

| Feature | DaisyDisk | CleanMyMac | Prunr MVP |
|---------|-----------|------------|-----------|
| Shows | Current sizes | Junk detection | Growth over time |
| Question answered | What's big? | What's safe to clean? | What grew? |
| History | No | No | Single baseline |
| Real-time | No | No | FSEvents-triggered |
| UI | Full window | Full window | Menu bar only |
| Drill-down | Manual folders | Categories | Smart boundaries |

## Legacy (Pre-MVP)

See `OLD_ROADMAP.md` for the original full-window app plan that this MVP replaces.
