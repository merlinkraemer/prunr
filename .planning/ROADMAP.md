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
- [x] **Phase 6: Popup HIG Redesign** - (Not Planned)
- [x] **Phase 7: Category-Based Growth View** - Category grouping with drill-down
- [x] **Phase 7.1: Layout Fixes** - Big file nesting, slide-in navigation, visual polish
- [x] **Phase 8.1: Urgent UX Fixes** - GB meter cache interval, drill-down header, animation verification
- [x] **Phase 8.2: UI Improvements & Real-time Updates** - GB meter real-time updates, navigation fixes, push animation, scan modal improvements
- [ ] **Phase 8: Polish & Issue Resolution** - Scan reliability, performance, verification

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

### Phase 7.1: Layout Fixes (INSERTED)

**Goal:** Fix category view layout, drill-down navigation, and visual polish
**Depends on:** Phase 7
**Research:** Unlikely (UI refinements specified)
**Plans:** 0 plans

**Deliverables:**
- Big files show as children in main view (max 3 + 1 "more" if needed)
- Drill-down layout redesign with proper visual hierarchy
- Slide-in navigation from right (push main view left like Finder)
- Distinct colors for category icons
- Main layout stability for variable-width "x items" text

---

### Phase 8.1: Urgent UX Fixes (INSERTED)

**Goal:** Fix critical UI/UX issues affecting core functionality before proceeding to comprehensive Phase 8 polish
**Depends on:** Phase 7.1
**Research:** Unlikely (issues are well-documented)
**Plans:** 0 plans

**Deliverables:**
- **ISS-032:** GB meter real-time updates in menu bar (reduce cache interval or trigger on FSEvents)
- **ISS-037:** Header replacement on drill-down (detail view header replaces main view header)
- **ISS-036:** Verify slide-in vs push animation (may already be resolved per ISS-030)
- **ISS-038:** Auto-scan should not show blocking overlay (one-line fix: exclude auto-scans from loading overlay)

**Issues Addressed:** ISS-032 (High), ISS-037 (Medium), ISS-036 (Medium - verification), ISS-038 (Medium - quick fix)

**Details:**
This urgent phase addresses the highest-priority UX issues that impact core functionality. These issues are marked High priority or affect critical user interactions and should be resolved before the comprehensive Phase 8 polish work.

---

### Phase 8.2: UI Improvements & Real-time Updates (INSERTED)

**Goal:** Fix critical navigation architecture, animations, real-time GB meter updates, and UI polish issues
**Depends on:** Phase 8.1
**Research:** Unlikely (solutions identified in ISS-036, ISS-039, ISS-040, ISS-042)
**Plans:** 4 plans

Plans:
- [x] 08.2-01: Navigation Architecture & Storage Bar (ISS-039)
- [x] 08.2-02: GB Meter Real-time Updates (ISS-042, ISS-032)
- [ ] 08.2-03: Scanning Progress & Settings Navigation (ISS-033, ISS-034)
- [ ] 08.2-04: Push Animation Implementation (ISS-036, ISS-040)

**Deliverables:**
- **ISS-039:** Navigation architecture overhaul - storage bar must remain visible during drill-down (High priority)
- **ISS-036/ISS-040:** Push animation implementation - replace slide-in with proper push that moves both views simultaneously (High priority)
- **ISS-042:** GB meter real-time updates - explicit menu bar sync after scans and 2s timer for continuous updates (High priority)
- **ISS-033:** Scanning progress indicator - progress bar/percentage for long-running scans (High priority)
- **ISS-034:** Monitor path click navigation - open settings directly to Paths tab (Medium priority)
- **ISS-027:** Header visual clarity improvements - better labels, separation, icons (Low priority)

**Issues Addressed:** ISS-039 (High), ISS-036/ISS-040 (High), ISS-042 (High), ISS-033 (High), ISS-034 (Medium), ISS-027 (Low)

**Details:**
This phase addresses critical UI and navigation issues with detailed solutions already documented in ISSUES.md. Focus areas:

1. **Navigation Architecture (ISS-039):** Complete redesign to separate storage bar (always visible) from page navigation system
2. **Push Animation (ISS-036/ISS-040):** Implement conditional rendering with `.transition(.asymmetric())` to eliminate overlap
3. **Real-time GB Meter (ISS-042):** Add explicit menu bar updates via `updateMenuBarDisplay()` and 2s background timer
4. **Progress Indicators (ISS-033):** Show progress bar with percentage for scans longer than 2 seconds
5. **Settings Navigation (ISS-034):** One-line fix to navigate to Paths tab when clicking monitor path
6. **Header Polish (ISS-027):** Add section labels, better visual separation, optional icons/tooltips

---

### Phase 8.3: Critical Issues from Root Issues Doc (INSERTED)

**Goal:** Fix critical navigation and visual consistency issues discovered during testing (ISS-045, ISS-046, ISS-047)
**Depends on:** Phase 8.2
**Research:** Unlikely (issues are well-documented in ISSUES.md)
**Plans:** 1 plan

Plans:
- [x] 08.3-01: Critical Navigation & Visual Fixes (ISS-045, ISS-046, ISS-047)

**Deliverables:**
- **ISS-045:** Back button changes header but doesn't navigate back (High priority)
- **ISS-046:** Headers not same size between views (Medium priority)
- **ISS-047:** Footer separator has empty space above it (Low priority)

**Issues Addressed:** ISS-045 (High), ISS-046 (Medium), ISS-047 (Low)

**Details:**
This phase addresses critical navigation and visual consistency issues that affect the drill-down user experience. ISS-045 is particularly critical as it blocks users from navigating back from the drill-down view, while ISS-046 and ISS-047 address visual polish and consistency.

---

### Phase 8: Polish & Issue Resolution

**Goal:** Address scan reliability, performance optimization, UI polish, and verification testing for issues ISS-010 through ISS-026
**Depends on:** Phase 8.2
**Research:** Unlikely (issues are well-documented)
**Plans:** 4 plans

Plans:
- [ ] 08-01: Scan Reliability & UX (ISS-026, ISS-022)
- [ ] 08-02: Performance Optimization (ISS-012, ISS-023)
- [ ] 08-03: UI Polish & Verification (ISS-021, ISS-010, ISS-011)
- [ ] 08-04: Low Priority Fixes (ISS-013, ISS-024, ISS-025) - optional

**Deliverables:**
- **Urgent Issues:**
  - ISS-026: Fix stop scan button reliability
  - ISS-022: Scanning indicator UX improvements (minimum display duration + progress feedback)
  - ISS-033: Scanning lacks progress indicator (progress bar/percentage for long scans)
  - ISS-035: Verify test data creation non-blocking (may already be resolved per ISS-028)
- **Performance Optimization:**
  - ISS-012: App performance optimization (scan, UI, database)
  - ISS-023: Slow popup opening investigation and fixes
- **UI Polish:**
  - ISS-021: Header section improvements (visual hierarchy, clarity) - COMPLETED
  - ISS-034: Monitor path click opens wrong settings page (navigate to Paths tab)
  - ISS-027: Header visual clarity improvements
- **Verification Testing:**
  - ISS-010: Verify boundaries with test data
  - ISS-011: Verify drilling down with test data
- **Low Priority Fixes:**
  - ISS-013: Menubar popup click issue
  - ISS-024: Settings window focus issue
  - ISS-025: Multi-monitor popup position issue

**Details:**
Comprehensive polish phase addressing all open issues from ISSUES.md. Prioritizes scan reliability and UX improvements, followed by performance optimization and systematic verification testing.

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
| 7.1. Layout Fixes | 2/2 | Complete | 2026-01-12 |
| 8.1. Urgent UX Fixes | 1/1 | Complete | 2026-01-12 |
| 8.2. UI Improvements & Real-time Updates | 4/4 | Complete | 2026-01-12 |
| 8.3. Critical Issues from Root Issues Doc | 1/1 | Complete | 2026-01-12 |
| 8. Polish & Issue Resolution | 0/4 | Planning | — |

**MVP Status:** 🎉 MVP complete (Phase 1-5). Phase 6-7.1 are post-MVP enhancements.

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
