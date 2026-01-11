---
phase: 01-menubar-foundation
plan: 01
subsystem: menubar-app
tags: [swiftui, appkit, nsstatusitem, nspopover, lsuielement]

# Dependency graph
requires:
provides:
  - Menu bar-only app foundation (no Dock icon)
  - NSStatusItem with free space display
  - NSPopover with placeholder content
affects: [02-fsevents-monitoring, 03-baseline-growth, 04-menubar-ui, 05-settings-polish]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Pattern 1: Menu bar apps use LSUIElement + NSStatusItem for Dock-less operation
    - Pattern 2: NSPopover with .transient behavior for auto-close on outside click
    - Pattern 3: @MainActor + @Observable for AppKit/SwiftUI interoperability

key-files:
  created: [Prunr/Services/MenuBarManager.swift, Prunr/Views/MenuBarView.swift, Prunr/Services/DiskSpaceService.swift, Prunr/PrunrMenuBar.swift, Prunr/Legacy/PrunrApp_Legacy.swift]
  modified: [Prunr.xcodeproj/project.pbxproj, Prunr/Views/DetailColumn.swift]

key-decisions:
  - "Used LSUIElement = YES for Dock-less operation (menu bar only app)"
  - "Chose .transient popover behavior for automatic close on outside click"
  - "Simplified GB display (no decimals) for compact menu bar"
  - "Preserved legacy app code in Legacy/ directory for reference"

patterns-established:
  - "Pattern: @MainActor required for NSStatusItem/NSPopover (AppKit UI must be on main thread)"
  - "Pattern: @Observable for SwiftUI compatibility with AppKit classes"
  - "Pattern: Strong reference to NSStatusItem required (NSStatusBar does NOT retain)"

issues-created: []

# Metrics
duration: 18min
completed: 2026-01-11
---

# Phase 1 Plan 01: Menu Bar Foundation Summary

**Transformed Prunr from full-window app to menu bar-only utility with NSStatusItem, popover, and free space display.**

## Performance

- **Duration:** 18 min
- **Started:** 2026-01-11T19:30:00Z
- **Completed:** 2026-01-11T19:48:00Z
- **Tasks:** 3
- **Files modified:** 6

## Accomplishments

- Configured LSUIElement for Dock-less operation (menu bar only app)
- Created MenuBarManager with NSStatusItem and NSPopover management
- Built MenuBarView with placeholder content, header, and footer buttons
- Created DiskSpaceService for free space queries
- Created PrunrMenuBar.swift as new @main entry point
- Preserved legacy app code in Legacy/ directory

## Task Commits

Each task was committed atomically:

1. **Task 1: Configure LSUIElement and create MenuBarManager** - `941e976` (feat)
2. **Task 2: Create MenuBarView placeholder and PrunrMenuBar entry** - `f036c66` (feat)
3. **Task 3: Add free space display to menu bar button** - `26f59e2` (feat)

**Plan metadata:** `(pending - docs commit)`

_Note: No TDD tasks in this plan_

## Files Created/Modified

- `Prunr.xcodeproj/project.pbxproj` - LSUIElement configuration, new files added
- `Prunr/Services/MenuBarManager.swift` - NSStatusItem/NSPopover management with @MainActor
- `Prunr/Views/MenuBarView.swift` - Placeholder popover content with header, body, footer
- `Prunr/Services/DiskSpaceService.swift` - Free space queries using FileManager resource values
- `Prunr/PrunrMenuBar.swift` - New @main app entry point with empty scene
- `Prunr/Legacy/PrunrApp_Legacy.swift` - Preserved old full-window app (removed @main)
- `Prunr/Views/DetailColumn.swift` - Fixed DeltaCategory switch exhaustiveness

## Decisions Made

- **LSUIElement = YES**: Prevents app from appearing in Dock - essential for menu bar utility
- **.transient popover behavior**: Auto-closes when clicking outside - better UX for menu bar
- **Home directory volume**: Used for free space queries - most relevant for users
- **Simplified GB format**: Dropped decimal places (e.g., "50 GB" not "50.2 GB") - compact display
- **Preserved legacy code**: Kept old app in Legacy/ directory - retained for reference

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed DeltaCategory switch exhaustiveness**

- **Found during:** Task 1 (build verification)
- **Issue:** DetailColumn.swift had switch statement with missing cases (homebrew, docker, npm, media)
- **Fix:** Added all missing cases with appropriate colors (.brown, .cyan, .green, .pink)
- **Files modified:** Prunr/Views/DetailColumn.swift
- **Verification:** Build succeeded after fix
- **Committed in:** `941e976` (part of Task 1 commit)

**2. [Rule 3 - Blocking] Restored missing view files for build**

- **Found during:** Task 1 (build verification)
- **Issue:** SizeBarView.swift and CategoryDetailView.swift were missing (deleted in earlier session)
- **Fix:** Copied files from LegacyViews/ to Views/ directory
- **Files modified:** Prunr/Views/SizeBarView.swift, Prunr/Views/CategoryDetailView.swift
- **Verification:** Build succeeded after restore
- **Committed in:** `941e976` (part of Task 1 commit)

**3. [Rule 3 - Blocking] Fixed Int to Int64 type conversion**

- **Found during:** Task 3 (DiskSpaceService compilation)
- **Issue:** `volumeTotalCapacity` returns Int, but function returns Int64
- **Fix:** Added explicit `Int64()` cast
- **Files modified:** Prunr/Services/DiskSpaceService.swift
- **Verification:** Build succeeded after fix
- **Committed in:** `26f59e2` (part of Task 3 commit)

### Deferred Enhancements

None

---

**Total deviations:** 3 auto-fixed (1 bug, 2 blocking), 0 deferred
**Impact on plan:** All auto-fixes were necessary for build to succeed. No scope creep.

## Issues Encountered

- Build failed initially due to deleted view files (SizeBarView, CategoryDetailView) - restored from LegacyViews
- Build failed due to missing DeltaCategory cases in DetailColumn - added missing cases
- Build failed due to Int/Int64 mismatch in DiskSpaceService - added explicit cast

All issues were resolved automatically per deviation rules.

## Next Phase Readiness

- Menu bar app foundation complete with NSStatusItem, popover, and free space display
- App launches without Dock icon (LSUIElement configured)
- Ready for **Phase 02: FSEvents Monitoring + Permissions**

---

*Phase: 01-menubar-foundation*
*Completed: 2026-01-11*
