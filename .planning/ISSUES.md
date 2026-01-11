# Project Issues Log

Enhancements discovered during execution. Not critical - address in future phases.

## Open Issues

### ISS-010: Verify Boundaries with Test Data
Need to test boundary detection logic and add boundary icons to settings view with appropriate icons and colors.

**Status:** Open
**Priority:** Medium
**Related:** BoundaryConfig, SettingsView

---

### ISS-011: Verify Drilling Down with Test Data
Need to test the drill-down functionality to ensure it works correctly when users click on folders in the growth list.

**Status:** Open
**Priority:** Medium
**Related:** BaselineService.drillDown()

---

### ISS-012: App Performance Optimization
App needs to be faster and more snappy overall. Potential areas:
- Scan performance
- UI responsiveness
- Database query optimization

**Status:** Open
**Priority:** Medium
**Related:** ScanService, DatabaseManager

---

### ISS-013: Menubar Popup Click Issue
Sometimes clicking the menubar icon doesn't open the popup. Need to investigate and fix.

**Status:** Open
**Priority:** Low
**Related:** MenuBarManager

---

### ISS-020: Growth List Not Aggregating by Parent Folder
When duplicate files are added to the same folder, the growth list shows each file separately instead of aggregating by parent directory. Users expect to see the parent folder with combined growth amounts.

**Example:** Adding two files to `~/dev/test_data` should show one entry for the parent folder with total growth, not two separate entries for each file.

**Status:** Open
**Priority:** High
**Related:** BaselineService.getGrowthList()

---

## Closed Issues

### ISS-001: Scan fails with "failed to create snapshot"
**Closed:** 2026-01-11 - Pre-refactor issue, no longer applicable

### ISS-002: Stop Scan Button Not Showing
**Closed:** 2026-01-11 - Pre-refactor issue, no longer applicable

### ISS-003: Show All Files When No Changes Found
**Closed:** 2026-01-11 - Pre-refactor issue, no longer applicable after UI changes

### ISS-004: Snapshot Comparison Dropdown
**Closed:** 2026-01-11 - Integrated ComparisonPicker into MenuBarView (time-based comparison logic deferred)

### ISS-005: Improve Size Bars UI
**Closed:** 2026-01-11 - Pre-refactor issue, no longer applicable after UI changes

### ISS-006: Drive Capacity Bar Redesign
**Closed:** 2026-01-11 (v1) - Redesigned with solid blue color, background track, and percentage indicator

### ISS-007: Move Quit to Settings
**Closed:** 2026-01-11 - Created SettingsView, moved Quit button from MenuBarView

### ISS-008: Right-Click Menu with Actions
**Closed:** 2026-01-11 - Implemented right-click context menu on menu bar icon with Settings, Reset Baseline, Quit

### ISS-009: Redesign Popups as macOS-Style Lists
**Closed:** 2026-01-11 - Redesigned footer as native macOS list row with chevron indicator

---

### ISS-014: Auto-scanning Not Working
**Closed:** 2026-01-11 - Fixed FSEvents implementation:
- Changed `CFRunLoopGetCurrent()` to `CFRunLoopGetMain()` for proper runloop scheduling
- Fixed C string parsing: `eventPaths` is `char**`, not `CFString**`
- Reduced debounce from 3s to 1s for near-realtime response
- Added extensive logging for debugging

### ISS-015: No Visual Feedback for Scanning
**Closed:** 2026-01-11 - Added visual feedback:
- "Scanning..." indicator next to "What Grew" header in popup
- No clutter in menu bar icon

### ISS-016: Growth Display Shows Raw Bytes Instead of MB/GB
**Closed:** 2026-01-11 - Fixed byte formatting in GrowthListView:
- Added KB display for values < 1 MB
- Shows proper units (KB, MB, GB, TB)

### ISS-017: Scan Now Button Missing
**Closed:** 2026-01-11 - Added "Scan Now" button to footer:
- Positioned above Reset Baseline
- Magnifying glass icon
- Shows "Done!" checkmark on completion

### ISS-018: Drive Bar Visual Overhaul
**Closed:** 2026-01-11 (v2) - Complete visual redesign:
- Color-coded by usage: Green (<70%) → Orange (<90%) → Red (≥90%)
- Drive icon that changes color based on usage
- Simplified label: "XXX GB free" + percentage badge
- Gradient fill on bar

### ISS-019: Growth List Visual Overhaul
**Closed:** 2026-01-11 - Complete visual redesign:
- File/folder name prominent (not full path)
- Parent path shown smaller below
- Color-coded icons by growth severity
- Arrow indicator (↗) for growth
- Smooth hover animations
- Better empty state with icon
