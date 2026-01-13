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
- [x] **Phase 8.3: Critical Issues from Root Issues Doc** - Back button navigation, header consistency, footer spacing
- [x] **Phase 8.4: New Issues from Issues Doc** - Drilldown blank screen, baseline creation, scan popup layout, header spacing
- [x] **Phase 8: Polish & Issue Resolution** - Scan reliability, performance, verification

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

### Phase 8.4: New Issues from Issues Doc (INSERTED)

**Goal:** Fix new critical issues discovered during testing including drilldown blank screen, baseline creation bug, scan popup layout, and header spacing
**Depends on:** Phase 8.3
**Research:** Unlikely (issues are well-documented in ISSUES.md)
**Plans:** 0 plans

Plans:
- [ ] TBD (run /gsd:plan-phase 8.4 to break down)

**Deliverables:**
- **ISS-043:** Drilldown view shows blank screen - clicking category fades out but detail view never appears (High priority)
- **ISS-048:** Create baseline doesn't work anymore - baseline creation functionality is broken (High priority)
- **ISS-044:** Scan popup modal layout issues - modal resizes during scan, no progress bar, poor layout (High priority)
- **ISS-049:** Headers too tall with excess spacing - excessive vertical spacing wastes popup space (Medium priority)
- **ISS-050:** Scanning popup flashes on quick scans - needs minimum display duration (Medium priority)
- **ISS-034:** Monitor path click opens wrong settings page - should navigate to Paths tab (Medium priority)
- **ISS-051:** Multiple monitoring paths not indicated in header - no way to see/switch paths (Medium priority)

**Issues Addressed:** ISS-043 (High), ISS-048 (High), ISS-044 (High), ISS-049 (Medium), ISS-050 (Medium), ISS-034 (Medium), ISS-051 (Medium)

**Details:**
This phase addresses new issues discovered during testing. The High priority issues (ISS-043 drilldown blank screen, ISS-048 baseline creation broken, ISS-044 scan popup layout) are critical blockers that prevent core functionality from working. Medium priority issues (ISS-049, ISS-050, ISS-034, ISS-051) address UX polish and quality-of-life improvements.

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
| 8.4. New Issues from Issues Doc | 1/1 | Complete | 2026-01-13 |
| 8. Polish & Issue Resolution | 4/4 | Complete | 2026-01-13 |

### Phase 9: Visual Improvements
**Goal**: Comprehensive visual polish including monospace fonts, static columns, header redesign, spacing consistency, simplified footer buttons, and dropdown integration
**Depends on**: Phase 8.4
**Research**: Unlikely (design patterns well-documented)
**Plans**: 6 plans

Plans:
- [ ] 09-01: Monospace Font Implementation (ISS-051)
- [ ] 09-02: Static Column Sizing (ISS-052)
- [ ] 09-03: Header Redesign (ISS-053)
- [ ] 09-04: Spacing Consistency (ISS-054)
- [ ] 09-05: Footer Button Simplification (ISS-055)
- [ ] 09-06: Multiple Paths Dropdown Integration (ISS-056)

**Deliverables**:
- **ISS-051**: Monospace font for all numeric values to prevent visual jumps when numbers change length
- **ISS-052**: Fixed-width columns for item counts and size differences in main and drill-down views
- **ISS-053**: Complete main view header redesign with cohesive design
- **ISS-054**: Consistent spacing across all views
- **ISS-055**: Simplified icon-only footer buttons with macOS 26 design
- **ISS-056**: Multiple paths dropdown properly integrated with header design

**Issues Addressed**: ISS-051 (Medium), ISS-052 (Medium), ISS-053 (High), ISS-054 (Medium), ISS-055 (Medium), ISS-056 (Medium)

**Details**:
This phase focuses on visual polish and UI consistency improvements to make the application more professional and polished. The header redesign (ISS-053) is high priority as it affects the overall user experience. Other tasks address specific visual inconsistencies and layout issues discovered during testing.

---

### Phase 9.1: UI Layout Fixes (INSERTED)

**Goal:** Fix layout overflow, alignment, footer redesign, and big file visual overhaul discovered during Phase 9 implementation
**Depends on:** Phase 9
**Research:** Unlikely (issues are well-documented)
**Plans:** 2 plans

Plans:
- [x] 9.1-01: Layout & Header Fixes (ISS-057, ISS-058, header updates)
- [ ] 9.1-02: Footer & Big File Visual Overhaul (ISS-059, ISS-060)

**Deliverables:**
- **ISS-057:** Column layout overflow - category and drill-down view pages wider than window, overflowing to sides (High priority)
- **ISS-058:** Alignment issues - file names and category names not left-aligned in grid layout (Medium priority)
- **ISS-059:** Footer redesign - convert to horizontal icon-only layout with macOS styling (High priority)
- **ISS-060:** Big file children visual overhaul - redesign nested big files in category view (Medium priority)
- Remove GB indicator from monitor path header
- Update bar header to show "X GB free of Y GB" format

**Issues Addressed:** ISS-057 (High), ISS-058 (Medium), ISS-059 (High), ISS-060 (Medium)

**Details:**
This urgent phase addresses layout and visual issues discovered during Phase 9 Visual Improvements implementation.

**Design Specifications:**

1. **Grid Alignment (ISS-057, ISS-058):**
   ```
   [folder] Other                    51 items | ↗ +1.9 GB
   [dots]   node_modules...           5 items | ↗ +189 MB
   [arrow]  Downloads                 3 items | ↗ +111 MB
   ```
   - Column 1: icon + category name (flexible width, left-aligned)
   - Column 2: item count (fixed or right-aligned)
   - Column 3: size delta (fixed or right-aligned)

2. **Header Redesign:**
   ```
   ┌─────────────────────────────────────────────────────────────┐
   │  💾 24 GB free of 465 GB  [███████████████░░░] 95%         │  ← FIXED
   ├─────────────────────────────────────────────────────────────┤
   │  Monitoring: [~/]                                          │  ← DEFAULT
   └─────────────────────────────────────────────────────────────┘
   ```
   - Multi-path: `[test_data] [prunr] [dev] ↓` — tags flow left, chevron expands
   - Drill-down: `← 📁 CategoryName size` — back arrow, icon, name, size

3. **Footer (ISS-059):**
   - Icons only, horizontally aligned
   - Minimalist design matching macOS 26 patterns

---

### Phase 9.2: UI & UX Quick Fixes (INSERTED)

**Goal:** Quick UI and UX fixes including reset baseline placement, tree view visuals, and app icon configuration
**Depends on:** Phase 9.1
**Research:** Unlikely (issues are well-documented)
**Plans:** 1 plan

Plans:
- [x] 9.2-01: UI & UX Quick Fixes (ISS-061, ISS-062, ISS-063)

**Deliverables:**
- **ISS-061:** Reset baseline moved from About tab to Paths settings page for better discoverability
- **ISS-062:** Tree view children visual redesign - removed background/border, now uses simple indent with subtle connector
- **ISS-063:** App icon configured from ci/logo/prunr-iOS-Default-1024x1024@1x.png

**Issues Addressed:** ISS-061 (Medium), ISS-062 (Medium), ISS-063 (Medium)

**Details:**
This phase addresses quick UI and UX fixes identified during testing:
1. Moved Reset Baseline button from About tab to Paths settings page where it logically belongs
2. Redesigned nested big file items to no longer look like mini cards - removed background, border, and hover states; now uses simple indentation with subtle gray connector lines
3. Added app icon from CI directory to the AppIcon asset catalog

---

### Phase 9.3: Performance & Speed Improvements (INSERTED)

**Goal:** General performance optimizations and speed improvements across the application
**Depends on:** Phase 9.2
**Research:** Unlikely (performance patterns well-documented)
**Plans:** 3 plans

Plans:
- [x] 9.3-01: Database & Scan Performance (ISS-012)
- [x] 9.3-02: UI Responsiveness (ISS-012)
- [ ] 9.3-03: Animation Performance (ISS-012)

**Deliverables:**
- **9.3-01:** Database batch inserts with prepared statements, composite index for delta queries
- **9.3-02:** UI caching with @State, stable .id() modifiers for better SwiftUI diffing
- **9.3-03:** Animation performance improvements (to be planned)

**Issues Addressed:** ISS-012 (Medium): App performance optimization - scan performance

**Details:**
This phase focuses on performance and speed improvements across the application:
1. Database optimizations (prepared statements, composite indexes)
2. UI responsiveness improvements
3. Animation performance optimizations

---

### Phase 9.4: Settings Redesign (INSERTED)

**Goal:** Redesign the Settings window with modern macOS 26 design patterns
**Depends on:** Phase 9.3
**Research:** Unlikely (design patterns well-documented)
**Plans:** 0 plans

Plans:
- [ ] TBD (run /gsd:plan-phase 9.4 to break down)

**Deliverables:**
- Modern settings window redesign
- Better organization and visual hierarchy
- Improved controls and interactions

**Issues Addressed:** TBD

**Details:**
This phase will redesign the Settings window to match modern macOS 26 design patterns with better visual hierarchy, improved controls, and more intuitive organization.

---

| 9. Visual Improvements | 0/6 | Planning | — |
| 9.1. UI Layout Fixes | 2/2 | Complete | 2026-01-13 |
| 9.2. UI & UX Quick Fixes | 1/1 | Complete | 2026-01-13 |
| 9.3. Performance & Speed Improvements | 2/3 | In progress | — |
| 9.4. Settings Redesign | 0/0 | Not Planned | — |

**MVP Status:** 🎉 MVP complete (Phase 1-5). Phase 6-9.2 are post-MVP enhancements.

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
