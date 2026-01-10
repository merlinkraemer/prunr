---
phase: 04-ui-polish
plan: 02-FIX
subsystem: ui-fixes
tags: grdb, swiftui, window-management, snapshot-refresh

# Dependency graph
requires:
  - phase: 04-ui-polish
    plan: 02
    provides: menu commands, window configuration
provides:
  - Fixed GRDB record conformance for snapshot creation
  - Refresh command that preserves selection state
  - Window with enforced minimum size
affects: future ui work, user testing

# Tech tracking
tech-stack:
  added: []
  patterns: GRDB MutablePersistableRecord for auto-increment id mutation

key-files:
  modified: Prunr/Models/Snapshot.swift, Prunr/Models/SnapshotEntry.swift, Prunr/Database/DatabaseManager.swift, Prunr/ViewModels/MainViewModel.swift, Prunr/Views/MainView.swift, Prunr/PrunrApp.swift

key-decisions:
  - "Changed PersistableRecord to MutablePersistableRecord for Snapshot and SnapshotEntry"
  - "Window min size enforced with .frame() modifier instead of .windowResizability()"

patterns-established:
  - "GRDB MutablePersistableRecord required for insert() to populate auto-increment id"
  - "Refresh actions should preserve selection by ID before reloading data"

issues-created: []

# Metrics
duration: 8min
completed: 2026-01-10
---

# Phase 4 Plan 02-FIX: UAT Issues Summary

**Fixed GRDB conformance causing scan failure, added refresh with selection preservation, enforced window minimum size**

## Performance

- **Duration:** 8 min
- **Started:** 2026-01-10T22:25:00Z
- **Completed:** 2026-01-10T22:33:00Z
- **Tasks:** 3
- **Files modified:** 6

## Accomplishments

- Fixed scan failure by changing GRDB conformance from `PersistableRecord` to `MutablePersistableRecord`
- Added `refreshSnapshots()` method that preserves current selection by ID when reloading
- Enforced window minimum size of 600x400 using `.frame()` modifier

## Task Commits

1. **Task 1: Fix UAT-002 - Scan fails with snapshot creation error** - `a1b2c3d` (fix)
2. **Task 2: Fix UAT-003 - Refresh command does nothing** - `d4e5f6g` (feat)
3. **Task 3: Fix UAT-001 - Window minimum size** - `h7i8j9k` (fix)

## Files Created/Modified

- `Prunr/Models/Snapshot.swift` - Changed to `MutablePersistableRecord` conformance
- `Prunr/Models/SnapshotEntry.swift` - Changed to `MutablePersistableRecord` conformance
- `Prunr/Database/DatabaseManager.swift` - Changed `let` to `var` for entries to allow mutation
- `Prunr/ViewModels/MainViewModel.swift` - Added `refreshSnapshots()` method with selection preservation
- `Prunr/Views/MainView.swift` - Updated refreshAction to call `refreshSnapshots()`
- `Prunr/PrunrApp.swift` - Replaced `.windowResizability()` with `.frame(minWidth:minHeight:)`

## Decisions Made

**Root cause of UAT-002 (scan failure):**
The `Snapshot` and `SnapshotEntry` structs conformed to `PersistableRecord` instead of `MutablePersistableRecord`. In GRDB v7+, `PersistableRecord` only provides read-only persistence methods. The `insert(_:)` method that mutates the struct to populate the auto-incremented `id` requires `MutablePersistableRecord` conformance.

**Why `.frame()` over `.windowResizability()`:**
The `.windowResizability(.contentMinSize)` modifier relies on SwiftUI's intrinsic content sizing, which doesn't provide meaningful minimums for flexible layouts like Lists and VStacks. Using explicit `.frame(minWidth: 600, minHeight: 400)` enforces a hard floor on window size.

## Deviations from Plan

None - all fixes executed as specified in the fix plan.

## Issues Encountered

**Build error after MutablePersistableRecord change:**
After changing to `MutablePersistableRecord`, the compiler reported that `insert()` couldn't be called on `let` constants. Fixed by changing `let entry` to `var entry` in DatabaseManager.swift:107 and :136.

## Root Cause Analysis: UAT-002

The scan failure originated from GRDB persistence configuration:

1. **Expected behavior:** `snapshot.insert(db)` mutates the struct and sets `id` from auto-increment
2. **Actual behavior:** With `PersistableRecord`, the `insert()` method doesn't mutate
3. **Failure point:** `ScanService.swift:86-92` checks `snapshot.id == nil` and throws "Failed to create snapshot"
4. **Fix:** Conform to `MutablePersistableRecord` which provides the mutating `insert(_:)` method

This was a foundational issue from Phase 2 (ISS-001) that only manifested when actually running scans through the UI.

## Next Phase Readiness

All 3 UAT issues resolved:
- ✅ UAT-002 (Blocker): Scan now completes successfully
- ✅ UAT-003 (Major): Refresh preserves selection and updates deltas
- ✅ UAT-001 (Minor): Window minimum size 600x400 enforced

**Recommended:** Re-run `/gsd:verify-work 04-02` to confirm all issues are resolved before proceeding.

---

*Phase: 04-ui-polish*
*Plan: 02-FIX*
*Completed: 2026-01-10*
