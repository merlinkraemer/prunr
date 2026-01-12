# Project Issues Log

Enhancements discovered during execution. Not critical - address in future phases.

## Open Issues

### ISS-038: Auto-Scan Should Not Show Loading Overlay
Auto-scanning triggered by FSEvents should happen completely in the background without showing the loading overlay popup. Currently, auto-scans display the same loading indicator as manual scans, which interrupts the user if the popup is open.

**Status:** Closed
**Priority:** Medium
**Related:** MenuBarManager.swift (isAutoScanning flag), MenuBarView.swift (loading overlay)
**Phase Mapping:** Phase 8.1-01 (Urgent UX Fixes)
**Updates:**
- 2026-01-12: Modified MenuBarView.swift overlay condition from `if manager.isLoading` to `if manager.isLoading && !manager.isAutoScanning`
- 2026-01-12: Auto-scans now run in background without blocking overlay
- 2026-01-12: Committed as 1f3e31a

---

### ISS-010: Verify Boundaries with Test Data
Need to test boundary detection logic and add boundary icons to settings view with appropriate icons and colors.

**Status:** In Progress - Test data created, manual verification pending
**Priority:** Medium
**Related:** BoundaryConfig, SettingsView
**Phase Mapping:** Phase 8-03 (UI Polish & Verification) - Plan 3: Verification Testing
**Updates:**
- 2026-01-12: Enhanced generateTestData() with 7 test projects covering all boundary types
- 2026-01-12: Test data includes .git, node_modules, .venv, target, build, DerivedData, .swiftpm, Pods, vendor, .cache
- 2026-01-12: Ready for manual verification per Phase 8 Plan 3

---

### ISS-011: Verify Drilling Down with Test Data
Need to test the drill-down functionality to ensure it works correctly when users click on folders in the growth list.

**Status:** In Progress - Ready for manual verification
**Priority:** Medium
**Related:** BaselineService.drillDown()
**Phase Mapping:** Phase 8-03 (UI Polish & Verification) - Plan 3: Verification Testing
**Updates:**
- 2026-01-12: Comprehensive test data created for drill-down testing
- 2026-01-12: Ready for manual verification per Phase 8 Plan 3

---

### ISS-012: App Performance Optimization
App needs to be faster and more snappy overall. Potential areas:
- Scan performance
- UI responsiveness
- Database query optimization

**Status:** Open
**Priority:** Medium
**Related:** ScanService, DatabaseManager
**Phase Mapping:** Phase 8-02 (Performance Optimization)

---

### ISS-013: Menubar Popup Click Issue
Sometimes clicking the menubar icon doesn't open the popup. Need to investigate and fix.

**Status:** Open
**Priority:** Low
**Related:** MenuBarManager
**Phase Mapping:** Phase 8-04 (Low Priority Fixes) - optional

---

### ISS-032: GB Meter Not Auto-Updating in Menu Bar
The GB meter in the menu bar is not updating fast enough when storage space changes. This is a critical issue as users need to see current storage usage in real-time.

**Status:** Closed
**Priority:** High
**Related:** MenuBarManager.swift, DriveBarView.swift
**Phase Mapping:** Phase 8.1-01 (Cache interval), Phase 8.2-02 (Background timer)
**Updates:**
- 2026-01-12: Reduced cache interval from 5s to 2s for more frequent updates
- 2026-01-12: Committed as d8d2d5d
- 2026-01-12: Implemented 2-second background timer for continuous updates in Phase 8.2-02
- 2026-01-12: GB meter now updates automatically every 2 seconds without manual scans

---

### ISS-033: Scanning Lacks Progress Indicator
Scanning still has no progress indicator in percent or progress bar format. Users have no feedback on scan progress for long-running scans.

**Status:** Open
**Priority:** High
**Related:** MenuBarView.swift, ScanService.swift
**Phase Mapping:** Phase 8-01 (Scan Reliability & UX)

---

### ISS-034: Monitor Path Click Opens Wrong Settings Page
Clicking the monitor path opens settings but doesn't navigate to the path configuration page. It should open directly to the path settings.

**Status:** Open
**Priority:** Medium
**Related:** MenuBarView.swift, SettingsView.swift
**Phase Mapping:** Phase 8-03 (UI Polish & Verification)

---

### ISS-035: Test Data Creation Locks Popup
Creating test data still blocks the popup from opening while processing. The UI should remain responsive during test data generation.

**Status:** Open
**Priority:** Medium
**Related:** MenuBarManager.swift
**Phase Mapping:** Phase 8-01 (Scan Reliability & UX)
**Note:** ISS-028 was closed for same issue with Task.detached fix. Verify if still occurring.

---

### ISS-036: Animation Still Slide-In Instead of Push
The drill-down navigation still uses slide-in animation that overlaps content instead of pushing animation that moves content aside.

**Status:** Open - Solution identified (see ISS-040 for implementation details)
**Priority:** High
**Related:** CategoryGrowthListView.swift
**Phase Mapping:** Phase 8.1 (Urgent UX Fixes)
**Research findings:**
- **Root cause:** ZStack with offsets causes both views to exist simultaneously, creating overlap
- **Solution:** Use conditional rendering with `.transition(.asymmetric())` so only one view exists at a time
- **Implementation:**
  ```swift
  ZStack {
      if selectedCategory == nil {
          categoryListView
              .transition(.asymmetric(
                  insertion: .move(edge: .leading),
                  removal: .move(edge: .leading)
              ))
      } else {
          categoryDetailView
              .transition(.asymmetric(
                  insertion: .move(edge: .trailing),
                  removal: .move(edge: .leading)  // Back button exits opposite direction
              ))
      }
  }
  .animation(.easeInOut(duration: 0.3), value: selectedCategory)
  ```
**Note:** ISS-030 was closed but animation still overlapping. See ISS-040 for detailed research.

---

### ISS-037: Header Should Replace on Drill-Down
The monitoring path should be the header for the main view. When the drill-down view opens, the header with back button should replace the monitor path header (not appear separately).

**Status:** Closed - Partial fix (see ISS-039 for architectural overhaul)
**Priority:** Medium
**Related:** MenuBarView.swift, CategoryGrowthListView.swift
**Phase Mapping:** Phase 8.1-01 (Urgent UX Fixes)
**Updates:**
- 2026-01-12: Added isDrilledDown state to MenuBarManager
- 2026-01-12: MenuBarView conditionally hides main header during drill-down
- 2026-01-12: CategoryGrowthListView updates state on drill-down/back
- 2026-01-12: Committed as aef37f4
- 2026-01-12: Note: Storage bar should remain visible (see ISS-039)

---

### ISS-021: Header Section Improvements
The combined header section (drive bar + monitored path) needs UX improvements for better information hierarchy and clarity.

**Potential improvements:**
- Better visual hierarchy between drive stats and path info
- Clearer separation or grouping of related information
- Optimize path size display formatting
- Consider loading states for path size calculation
- Review spacing and alignment

**Status:** Closed
**Priority:** Medium
**Related:** MenuBarView.swift, MenuBarManager.swift
**Phase Mapping:** Phase 7.1-01
**Updates:**
- 2026-01-12: Implemented all header improvements
  - Increased spacing from 12pt to 16pt between sections
  - Added subtle separator line (1pt with 0.1 opacity)
  - Added loading state: "Calculating..." with mini ProgressView
  - Clear visual hierarchy: drive bar (primary) vs path info (secondary)

---

### ISS-022: Scanning Indicator UX Improvements
Two scanning indicator issues need to be addressed:

**Issue 1: Quick scans flash too briefly**
When scans complete very quickly (like auto-scan updates), the scanning indicator just flashes briefly instead of displaying long enough to be perceived. This creates a distracting flash effect.

**Solution:** Implement minimum display duration (e.g., 500ms-1s) for scanning indicator. If scan completes before minimum duration, keep indicator visible until minimum time has elapsed.

**Issue 2: Long scans lack progress feedback**
When scanning larger directories, users have no indication of progress - just a spinning indicator with no context about how much work remains or what's being scanned.

**Solution:**
- Show progress bar for scans that take longer than a threshold (e.g., >2 seconds)
- Display currently scanned file/folder path
- Show file count or percentage progress
- Already partially implemented: MenuBarView.swift shows `scanProgress` and `filesScanned`, but needs better progress calculation and display

**Implementation approach:**
- Track scan start timestamp
- For quick scans: minimum display duration (500ms-1s)
- For long scans: switch to progress bar mode after 2s threshold
- Update ScanService to report granular progress (current file, total files, percentage)
- Apply to both manual "Scan Now" and auto-scan indicators

**Status:** Partially Closed
**Priority:** Medium
**Related:** MenuBarManager.swift (isLoading, isAutoScanning, scanProgress, filesScanned), MenuBarView.swift (scanning indicators), ScanService.swift (progress reporting)
**Phase Mapping:** Phase 8-01 (Scan Reliability & UX) - for remaining progress bar implementation
**Updates:**
- 2026-01-12: Fixed progress callback to use @MainActor for UI updates
- 2026-01-12: Fixed "Scan Now" button to wait for isLoading to complete before showing Done
- 2026-01-12: Progress now shows files scanned and current path after 2 seconds

---

### ISS-027: Header Visual Clarity Improvements
The folder path monitoring header needs visual overhaul to be more intuitive about what each element represents.

**Current issues:**
- Not immediately clear what the top section (drive bar) represents
- Path section could be more clearly labeled
- Overall hierarchy could be more intuitive

**Potential improvements:**
- Add section labels or hints
- Better visual separation between disk space and monitored path
- Consider icons or tooltips
- Group related information more clearly

**Status:** Open
**Priority:** Low
**Related:** MenuBarView.swift, DriveBarView.swift
**Phase Mapping:** Phase 8-03 (UI Polish & Verification)
**Updates:**
- 2026-01-12: Added clickable path row with chevron indicator to open settings
- 2026-01-12: Increased popup height from 420 to 480 for more space

---

### ISS-023: Slow Popup Opening
Sometimes the popup opens slowly with noticeable lag. Need to investigate performance bottlenecks during popup initialization and display.

**Status:** Open
**Priority:** Medium
**Related:** MenuBarManager.swift, MenuBarView.swift
**Phase Mapping:** Phase 8-02 (Performance Optimization)

---

### ISS-024: Settings Window Focus Issue
Settings window doesn't always properly focus when opened. Window may appear but not be frontmost or receive keyboard focus.

**Status:** Open
**Priority:** Low
**Related:** SettingsView.swift, MenuBarManager.swift
**Phase Mapping:** Phase 8-04 (Low Priority Fixes) - optional

---

### ISS-025: Multi-Monitor Popup Position Issue
When using multiple monitors, the popup sometimes jumps to the second monitor when focus changes, instead of staying near the menubar icon on the primary display.

**Status:** Open
**Priority:** Low
**Related:** MenuBarManager.swift, window positioning logic
**Phase Mapping:** Phase 8-04 (Low Priority Fixes) - optional

---

### ISS-026: Stop Button Doesn't Work Reliably
The stop scan button doesn't consistently stop ongoing scans. Need to investigate scan cancellation logic and ensure proper state management.

**Status:** Open
**Priority:** Medium
**Related:** ScanService.swift, MenuBarManager.swift
**Phase Mapping:** Phase 8-01 (Scan Reliability & UX)

---

### ISS-039: Navigation Architecture Needs Overhaul
The drill-down navigation architecture needs a complete redesign to properly separate the two views and maintain persistent storage bar.

**Current problems:**
- Storage bar (DriveBarView) disappears during drill-down
- Two views are not properly separated as distinct pages
- Header replacement approach is incorrect architectural pattern

**Correct architecture:**
- **Storage bar:** Should ALWAYS remain visible at the top (never hidden)
- **Page 1:** Monitor path header + category list view
- **Page 2:** Back button header + drill-down detail view
- Two complete pages that swap positions, not partial view replacement

**Implementation approach:**
- Storage bar should be outside the page navigation system
- Create proper page container with two full-page views
- Use proper SwiftUI navigation patterns (NavigationStack or custom container)
- Push animation should move entire pages, not individual components

**Status:** Open
**Priority:** High
**Related:** MenuBarView.swift, CategoryGrowthListView.swift, DriveBarView.swift
**Phase Mapping:** Phase 8.1 (Urgent UX Fixes) - requires architectural change

---

### ISS-040: Push Animation Still Overlapping
The drill-down animation still shows overlapping instead of proper push behavior where both views move simultaneously.

**Current behavior:**
- Detail view slides in from right
- Main list appears to stay in place or fade
- Views overlap during transition
- Not a true "push" like iOS navigation

**Expected behavior:**
- Main list should visibly push LEFT and off-screen
- Detail view should slide IN from the right
- Both views move at the same time (synchronized)
- Similar to iOS UINavigationController push animation or Finder column view

**Research completed:**
- **Root cause:** ZStack with offset approach creates overlap because both views exist in same ZStack layer simultaneously
- **Why NavigationStack isn't the answer:** macOS doesn't have iOS-style NavigationController push animations. NavigationStack on macOS defaults to sidebar/split view, not horizontal push animation.
- **Solution:** Conditional rendering with `.transition(.asymmetric())` ensures only ONE view renders at a time

**Implementation:**
```swift
struct CategoryGrowthListView: View {
    @State private var selectedCategory: CategoryGrowthItem?

    var body: some View {
        ZStack {
            if selectedCategory == nil {
                categoryListView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
            } else {
                categoryDetailView
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
                    .overlay(alignment: .topLeading) {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .padding(12)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedCategory)
    }

    func goBack() {
        withAnimation(.easeInOut(duration: 0.3)) {
            selectedCategory = nil
        }
    }
}
```

**Why this works:**
- Only ONE view renders at a time - no overlap
- List exits left while detail enters right - synchronized push effect
- No transparency fighting - SwiftUI handles transition timing
- Native macOS animation feel - smooth, coordinated motion
- Back button triggers reverse animation automatically (detail exits left, list re-enters from left)

**Status:** Open - Solution identified, ready for implementation
**Priority:** High
**Related:** CategoryGrowthListView.swift (lines 16-44 animation logic)
**Phase Mapping:** Phase 8.1 (Urgent UX Fixes)

---

### ISS-041: Test Data Creation Still Blocks UI
Creating test data from context menu still completely locks the popup from opening, despite using Task.detached. The UI freezes during the entire test data generation process.

**Current behavior:**
- Right-click → "Create Test Data"
- Try to open popup → completely frozen/unresponsive
- Must wait for entire test data generation to complete
- UI thread appears blocked despite Task.detached(priority: .utility)

**Expected behavior:**
- Test data generation runs completely in background
- Popup opens immediately and remains responsive
- No UI blocking whatsoever
- Progress notification when complete (optional)

**Investigation needed:**
- Why Task.detached still blocks UI
- Whether FileManager operations are blocking main thread
- Need truly asynchronous file creation that doesn't block UI
- Consider showing toast notification instead of silent background operation

**Status:** Open
**Priority:** Medium
**Related:** MenuBarManager.swift (generateTestData method around line 749)
**Phase Mapping:** Phase 8-01 (Scan Reliability & UX)
**Note:** ISS-028 was closed with Task.detached fix but issue persists

---

### ISS-042: GB Meter Not Updating After Scans
The GB meter in the menu bar and the drive bar inside the popup do not update after scans complete, even when clicking "Scan Now" manually. Storage display remains stale despite actual storage changes.

**Current behavior:**
- Initial app launch shows correct GB amount
- Create/delete large files
- Click "Scan Now" or trigger auto-scan
- GB meter in menu bar: NO UPDATE
- Drive bar in popup: NO UPDATE
- Only updates on app restart or unknown trigger

**Expected behavior:**
- After any scan (manual or auto), GB meter updates to reflect current storage
- Within 2-3 seconds of storage changes
- Drive bar in popup updates simultaneously
- Real-time feedback on storage changes

**Research completed:**
- **Root cause:** `@Observable` updates SwiftUI views automatically, but NOT AppKit controls (NSStatusItem.button). The menu bar icon is pure AppKit and doesn't auto-sync.
- **Why DriveBarView updates but menu bar doesn't:** DriveBarView is SwiftUI (reacts to @Observable), NSStatusItem.button.title is AppKit (requires explicit update)

**Solution: Explicit Menu Bar Updates**
```swift
@MainActor
@Observable
final class MenuBarManager: NSObject {
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var statusItem: NSStatusItem?

    // CRITICAL: This must be called whenever storage changes
    func updateFreeSpace() {
        let free = DiskSpaceService.shared.getFreeSpace()
        let total = DiskSpaceService.shared.getTotalSpace()

        self.freeBytes = free
        self.totalBytes = total
        self.usedBytes = total - free

        // ← NEW: Explicitly sync menu bar
        updateMenuBarDisplay()
    }

    // CRITICAL: New method for AppKit synchronization
    private func updateMenuBarDisplay() {
        let gb = Double(freeBytes) / 1_000_000_000
        statusItem?.button?.title = "\(String(format: "%.1f", gb)) GB"
    }

    // CRITICAL: Call this after scans complete
    func loadCategoryGrowthList() async {
        isLoading = true
        // ... scanning logic ...
        isLoading = false

        // NEW: Trigger storage update after scan
        updateFreeSpace()  // ← This line was missing!
    }

    // CRITICAL: New: For auto-updates every 2 seconds
    func startRealtimeUpdates() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateFreeSpace()
        }
    }
}
```

**Recommended Architecture: Hybrid Update System**
- 1. App launch: `updateFreeSpace()` → menu bar shows GB
- 2. Timer tick (every 2s): `updateFreeSpace()` → menu bar and popup stay in sync
- 3. FSEvents trigger: `loadCategoryGrowthList()` → scan completes → `updateFreeSpace()` called
- 4. Popup closes/opens: Updates still happening in background, menu bar always current

**Note on Menu Bar Convention:** Apps like Stats display system drive free space in menu bar (universal, always relevant) and path-specific analysis in popover. Keep this convention:
- Menu bar: System drive free space
- Popover: Monitored path growth analysis

**Status:** Closed
**Priority:** High
**Related:** MenuBarManager.swift (updateFreeSpaceIfNeeded, updateFreeSpace, startRealtimeUpdates), DriveBarView.swift
**Phase Mapping:** Phase 8.2-02 (GB Meter Real-time Updates)
**Updates:**
- 2026-01-12: Implemented explicit menu bar sync after scans (updateFreeSpace() called in loadCategoryGrowthList, loadGrowthList, createBaseline)
- 2026-01-12: Implemented 2-second background timer for continuous GB meter updates (startRealtimeUpdates with Timer.scheduledTimer)
- 2026-01-12: Fixed Main actor isolation for updateTimer property (nonisolated(unsafe))
- 2026-01-12: Committed as 00a97b0, 005d99b, 9cf9866

---

### ISS-028: Test Data Blocks Popup Opening
Creating test data from context menu blocks the popup from opening until generation completes.

**Status:** Closed
**Priority:** Medium
**Related:** MenuBarManager.swift
**Updates:**
- 2026-01-12: Changed generateTestData() to use Task.detached(priority: .utility) for non-blocking execution

---

### ISS-029: Finder Not Focused on Reveal
Clicking items to reveal in Finder doesn't bring Finder to front - it opens in background.

**Status:** Closed
**Priority:** Medium
**Related:** MenuBarManager.swift
**Updates:**
- 2026-01-12: Updated revealInFinder() to activate Finder after revealing file

---

### ISS-030: Slide-In Animation Overlaps Instead of Pushing
Drill-down animation uses overlapping transition instead of pushing the category list aside.

**Status:** Closed
**Priority:** Medium
**Related:** CategoryGrowthListView.swift
**Updates:**
- 2026-01-12: Fixed animation to use simultaneous offset for both views (removed .transition modifier)

---

### ISS-031: Scan Now Shows Done While Loading Active
"Scan Now" button shows "Done!" while the loading popup overlay is still visible.

**Status:** Closed
**Priority:** Medium
**Related:** MenuBarView.swift
**Updates:**
- 2026-01-12: Added while loop to wait for manager.isLoading to complete before showing Done

---

## Closed Issues

### ISS-020: Growth List Not Aggregating by Parent Folder
**Closed:** 2026-01-12 - Resolved during Phase 7 work. BaselineService.buildGrowthList() now aggregates growth by direct child component (lines 296-318). Growth is correctly aggregated at parent folder level instead of showing individual files.

---

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
