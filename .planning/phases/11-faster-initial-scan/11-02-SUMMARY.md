---
phase: 11-faster-initial-scan
plan: "02"
subsystem: scan
tags: [swift, actors, taskgroup, concurrency, progress, ui, categories]

# Dependency graph
requires:
  - phase: 11-faster-initial-scan
    plan: "01"
    provides: bulk DB inserts, inline working-set population during scan, alsoWriteWorkingSet flag
provides:
  - Concurrent parallel scanning for multiple independent tracked paths via withThrowingTaskGroup
  - Live category fill-in during scan (categories appear and grow every ~2s before scan finishes)
  - isScanning as computed Bool backed by activeScanCount counter (allows parallel scans)
  - categoryTotals field in ScanProgress for live UI updates
affects: [12-optional-initial-scan, ui-scan-progress, performance-regression-tests]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Counter-based scan lock: activeScanCount Int replacing isScanning Bool — allows N concurrent scans, isScanning = activeScanCount > 0"
    - "TaskGroup parallelism: withThrowingTaskGroup for independent tracked paths, single-path fast path avoids group overhead"
    - "Category live fill: ScanService sends categoryTotals snapshot every ~2s in ScanProgress, MenuBarManager merges into stableCategories"
    - "Shared isCancelled flag: single flag stops ALL concurrent scan loops; resetCancellationForNewBatch() called once before group starts"

key-files:
  created: []
  modified:
    - Prunr/Services/ScanService.swift
    - Prunr/Services/MenuBarManager.swift
    - Prunr/Services/BaselineService.swift

key-decisions:
  - "Use activeScanCount counter not a mutex — allows parallel scans for independent paths without a per-path lock"
  - "Single-path fast path in createBaselines() avoids TaskGroup overhead for the common case (one tracked path)"
  - "categoryTotals nil on most progress updates (only set every ~2s) — avoids copying the dict on every 250ms progress callback"
  - "partialScanCategoryTotals uses max() merge so monotonically-growing totals from parallel paths don't overwrite each other"
  - "Task 4 (skip delta on first scan) was already correctly implemented — if let previousSnapshotId guard skips calculateDeltas and journal recording on first scan"

patterns-established:
  - "resetCancellationForNewBatch: called once before scan group starts, not inside each scan() — prevents second scan resetting cancellation of a parallel first scan"
  - "applyPartialCategoryTotals: separate method that merges partial totals and updates stableCategories live during scan"

requirements-completed: []

# Metrics
duration: 12min
completed: 2026-03-14
---

# Phase 11 Plan 02: Parallel Path Scanning + Live Category Fill-In Summary

**Concurrent TaskGroup scanning for independent tracked paths with live category fill-in every 2 seconds — categories appear and grow in real-time while the scan runs**

## Performance

- **Duration:** ~12 min
- **Started:** 2026-03-14T06:43:10Z
- **Completed:** 2026-03-14T06:55:30Z
- **Tasks:** 4
- **Files modified:** 3

## Accomplishments

- Replaced `isScanning: Bool` singleton lock with `activeScanCount: Int` counter, enabling N concurrent `scan()` calls without any one blocking another
- `MenuBarManager.createBaselines()` now uses `withThrowingTaskGroup` to scan multiple independent tracked paths in parallel — walls them off with a single-path fast path that avoids group overhead for the common case
- Added `categoryTotals: [GrowthCategory: Int64]?` to `ScanProgress` — ScanService sends a snapshot of accumulated category sizes every ~2 seconds alongside the existing progress callback
- `applyAggregateScanProgress` in MenuBarManager detects category snapshots and calls `applyPartialCategoryTotals()`, which merges partial totals and immediately updates `stableCategories` — user sees categories appear and grow live during scan
- Confirmed Task 4 was already correctly implemented: `if let previousSnapshotId` guard in `BaselineService.createBaseline()` skips `calculateDeltas` and `growthJournalService.recordDeltas` on first scan

## Task Commits

1. **Tasks 1+2: ScanService parallel lock + category totals in ScanProgress** - `5cc30b2` (feat)
2. **Tasks 1+3: MenuBarManager TaskGroup + live category fill-in UI** - `c3044eb` (feat)
3. **Task 4: Verify first-scan delta skip, add explanatory comment** - `68b6071` (chore)

## Files Created/Modified

- `Prunr/Services/ScanService.swift` — `activeScanCount` counter, `isScanning` computed property, `cancelScan()` simplified, `resetCancellationForNewBatch()` exposed, singleton lock removed from `scan()`, `categoryTotals` field added to `ScanProgress`, `lastCategoryUpdate` tracking, periodic category snapshots in progress loop
- `Prunr/Services/MenuBarManager.swift` — `createBaselines()` with `withThrowingTaskGroup`, `partialScanCategoryTotals` property, `applyPartialCategoryTotals()` method, reset at scan start/end
- `Prunr/Services/BaselineService.swift` — clarifying comment on first-scan delta skip

## Decisions Made

- **activeScanCount counter**: A plain counter (increment on enter, decrement in defer) is simpler and more correct than tryLock/release semantics. The `@MainActor` isolation makes it thread-safe without additional synchronization.
- **Single-path fast path**: `guard trackedPaths.count > 1` avoids task group overhead for the vast majority of users who have a single tracked path. The group is only created when genuinely needed.
- **categoryTotals nil on non-snapshot updates**: The `[GrowthCategory: Int64]` dict is only copied into `ScanProgress` every ~2s. On the other 250ms-throttled updates (which fire much more frequently), `categoryTotals` is `nil` — avoids a dict copy per update.
- **max() merge for parallel paths**: When merging partial totals from parallel scans, `max(existing, new)` ensures a fast-finishing path doesn't zero out a slower path's accumulated total.
- **Task 4 already implemented**: No code changes required — the existing `if let previousSnapshotId` guard correctly skips delta calculation and journal recording on first scan.

## Deviations from Plan

None — plan executed exactly as written. Task 4 was verified as already complete.

## Issues Encountered

None beyond expected design decisions (counter vs. boolean, nil-on-most-updates for efficiency).

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Parallel scanning foundation is in place for Phase 12 (optional initial scan)
- Live category fill-in is active for all scans — both initial and rescan
- `resetCancellationForNewBatch()` is now public API on ScanService for Phase 12 to use if it triggers scans directly
- No regressions — single-path case uses the fast path, matching prior behavior exactly

## Self-Check: PASSED

All files verified present. Commits 5cc30b2, c3044eb, 68b6071 verified in git log.

---
*Phase: 11-faster-initial-scan*
*Completed: 2026-03-14*
