# Alpha Freshness Fixes

**Date:** 2026-05-12
**Status:** draft

## Problem

The live working-set freshness branch builds and the XCTest suite is green, but the current implementation still has alpha-blocking behavior gaps. Dirty-root batches can bypass exponential backoff, menu open can still trigger stale full reconciliation, Prunr-internal paths are not hard-excluded in every accounting path, the footer can hide pending dirty state, and the monitor freshness probe does not prove the configured tracked path or UI-facing category totals.

## Solution

Tighten the freshness architecture around a few invariants: dirty-root work has exactly one scheduler with backoff, panel open only reads existing current state, scheduled reconciliation is owned by a background coordinator instead of SwiftUI view appearance, Prunr internal paths are excluded at event and file accounting boundaries, and verification proves working-set plus category-total freshness for the configured tracked root.

## Out of scope

- New cleanup/deletion workflows.
- Adaptive reconciliation beyond the existing fixed interval presets.
- Default ignoring of developer caches, media imports, package installs, or agent workdirs.
- Whole-volume `/` live watching.
- Redesigning the menu UI beyond pending-state freshness text.

## Slices

### s1: Dirty-Root Backoff Invariant
- **outcome:** Dirty FSEvents batches always collapse into one delayed refresh with exponential backoff and never fall back to normal short debounce.
- **depends_on:** none
- **likely_files:** `Prunr/Services/MenuBarManager.swift`, `PrunrTests/PrunrSmokeTests.swift`
- **acceptance:**
  - [ ] A dirty batch schedules `scheduleDirtyRootRefresh()` and not `scheduleRecentChangeRefreshTask(after: currentRecentChangeDebounce)`.
  - [ ] Dirty work that fires while scan/inventory work is busy is re-armed with dirty backoff, not normal debounce.
  - [ ] Dirty events that arrive during `loadInventory()` completion are flushed through dirty backoff, not the `0.5s` post-scan path.
  - [ ] Tests cover repeated dirty batches and prove the delay increases up to the configured cap.

### s2: Internal Path Hard Exclusion
- **outcome:** Prunr-owned DB/WAL/SHM/state files cannot produce watcher dirty work or appear in scan accounting, even when the tracked root is the internal directory itself.
- **depends_on:** none
- **likely_files:** `Prunr/Services/FSEventsWatcher.swift`, `Prunr/Services/FileScanner.swift`, `Prunr/Services/PrunrInternalPaths.swift`, `PrunrTests/PrunrSmokeTests.swift`
- **acceptance:**
  - [ ] Internal-only FSEvents batches are dropped before directory-heavy classification can mark them dirty.
  - [ ] Directory-heavy classification uses external event counts, not raw internal/noise counts.
  - [ ] `FileScanner` skips internal files in the `FTS_F` path as well as internal directories.
  - [ ] Tests cover an internal-only directory burst and root-level internal files.

### s3: Reconciliation Off Panel Open
- **outcome:** Opening the menu never starts a full root reconciliation; stale reconciliation runs only from a background-owned trigger.
- **depends_on:** none
- **likely_files:** `Prunr/Views/MenuBarView.swift`, `Prunr/Services/MenuBarManager.swift`, `PrunrTests/PrunrSmokeTests.swift`
- **acceptance:**
  - [ ] `MenuBarView.task` does not call `reconcileIfStale()` or any full-scan reconciliation path.
  - [ ] `MenuBarManager` owns a reconciliation backstop trigger that can run after startup/baseline readiness without view appearance.
  - [ ] Opening and closing the panel when stale does not call `createBaselines`.
  - [ ] The 24h default and existing interval presets remain unchanged.

### s4: Fast Panel Open And Pending Freshness Text
- **outcome:** Panel open trusts current in-memory/working-set state and clearly shows pending dirty refresh state while background reconciliation is delayed.
- **depends_on:** s1, s3
- **likely_files:** `Prunr/Services/MenuBarManager.swift`, `Prunr/Views/MenuBarView.swift`, `PrunrTests/PrunrSmokeTests.swift`
- **acceptance:**
  - [ ] Panel open with displayable inventory does not re-run heavy `getInventoryWithTrends` just because a 5s TTL expired.
  - [ ] Explicit refresh, accept growth, completed scan, or real incremental update can still refresh inventory from DB.
  - [ ] Footer freshness text surfaces `pendingDirtyReason` or an equivalent pending-changes state.
  - [ ] Closing the panel during a refresh leaves loading and pending flags coherent.

### s5: Pure Accept-Growth Promotion
- **outcome:** Accept Growth remains a DB-local baseline promotion and does not touch filesystem metadata or start scans.
- **depends_on:** none
- **likely_files:** `Prunr/Services/BaselineService.swift`, `Prunr/Database/DatabaseManager.swift`, `Prunr/Services/MenuBarManager.swift`, `PrunrTests/PrunrSmokeTests.swift`
- **acceptance:**
  - [ ] `acceptGrowth(for:)` creates the new snapshot from `workingSetEntry` without filesystem calls.
  - [ ] Growth journal buckets for the accepted tracked path are cleared.
  - [ ] UI growth indicators clear optimistically and stay clear after DB reload.
  - [ ] No full scan or reconciliation task starts as part of Accept Growth.

### s6: Alpha Freshness Verification
- **outcome:** The monitor and tests prove the alpha-critical freshness path: file creation under the configured tracked root updates working-set and category totals without scan loops.
- **depends_on:** s1, s2, s3, s4, s5
- **likely_files:** `scripts/monitor.mjs`, `docs/test-checklist.md`, `PrunrTests/PrunrSmokeTests.swift`
- **acceptance:**
  - [ ] `npm run monitor -- --freshness-probe` derives its default probe directory from the configured tracked root or fails loudly with context.
  - [ ] The probe verifies both `workingSetEntry` and `workingSetCategoryTotal` changed for the same tracked path.
  - [ ] Probe cleanup does not mask a failed freshness result.
  - [ ] Final alpha gate includes `make build`, `make test`, freshness probe, and a short monitor run showing low idle CPU/RSS and no repeated full-scan loop.

## Dependency graph

```text
s1 -> s4, s6
s2 -> s6
s3 -> s4, s6
s4 -> s6
s5 -> s6
s6 -> (none)
```

## Parallel batches

- **Batch 1** (independent): s1, s2, s3, s5
- **Batch 2** (after s1 and s3): s4
- **Batch 3** (after s1, s2, s3, s4, and s5): s6

## Notes

- Current `make build` and `make test` are green: 51 tests passed on 2026-05-11.
- The green suite does not cover the dirty-root reschedule paths that bypass backoff.
- `reconcileIfStale()` currently has one call site in `MenuBarView.task`, which contradicts the PRD requirement that reconciliation not run on menu open.
- Treat `PrunrInternalPaths` as the source of truth, but enforce it at both directory and file accounting boundaries.
- The monitor probe should prove the same data the UI reads: current working set plus category totals for the active tracked path.
