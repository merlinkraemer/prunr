---
phase: 11-faster-initial-scan
plan: "01"
subsystem: database
tags: [sqlite, grdb, performance, batch-inserts, scan, working-set]

# Dependency graph
requires:
  - phase: 10-live-tracking-engine
    provides: workingSetEntry, pathClassification, FSEvents live tracking infrastructure
provides:
  - Bulk multi-row SQL inserts for snapshotEntry, workingSetEntry, pathClassification
  - Inline working-set population during scan (eliminates post-scan rebuildWorkingSet pass)
  - Exact-match path lookups (no COLLATE NOCASE overhead)
  - 15000-entry outer batch size in ScanService
affects: [12-optional-initial-scan, performance-regression-tests]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Multi-row VALUES inserts: chunk to 500 rows per SQL statement to amortize parse/prepare overhead"
    - "Inline working-set co-write: pass alsoWriteWorkingSet=true to scan(), write entries in same DB transaction"
    - "In-memory category totals written at end of scan — avoids SQL GROUP BY over 2.2M rows"
    - "Pre-clear working set before scan, then ON CONFLICT upsert during batches"

key-files:
  created: []
  modified:
    - Prunr/Database/DatabaseManager.swift
    - Prunr/Services/ScanService.swift
    - Prunr/Services/BaselineService.swift

key-decisions:
  - "Use chunked 500-row multi-row VALUES for upsertPathClassifications, addEntriesCore, and replaceWorkingSetCategoryTotals"
  - "Remove COLLATE NOCASE from fetchPathIds and getOrCreatePathId — normalizePath guarantees consistent casing on insert"
  - "addEntriesWithWorkingSet writes workingSetEntry rows inline (same dbPool.write transaction) — eliminates separate rebuildWorkingSet SQL pass"
  - "BaselineService pre-clears workingSetEntry before scan (clearWorkingSetEntries), then ON CONFLICT upsert during batches — handles both first and repeat scans"
  - "Working-set category totals written from in-memory categoryTotals dict via replaceWorkingSetCategoryTotals, not SQL GROUP BY"
  - "batchSize increased from 5000 to 15000 in ScanService — fewer transactions per scan"

patterns-established:
  - "alsoWriteWorkingSet pattern: ScanService accepts flag to co-write working set during scan without separate DB pass"
  - "addEntriesCore private implementation shared by addEntries and addEntriesWithWorkingSet"

requirements-completed: []

# Metrics
duration: 7min
completed: 2026-03-14
---

# Phase 11 Plan 01: Optimize DB Write Path Summary

**Multi-row bulk inserts for snapshotEntry/workingSetEntry/pathClassification, exact-match path lookups, and inline working-set population during scan — eliminating the post-scan 2.2M-row rebuildWorkingSet copy**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-03-14T06:33:23Z
- **Completed:** 2026-03-14T06:39:31Z
- **Tasks:** 5
- **Files modified:** 3

## Accomplishments

- Replaced per-row prepared-statement loops with chunked 500-row multi-row VALUES inserts in `upsertPathClassifications`, `addEntriesCore`, and `replaceWorkingSetCategoryTotals`
- Removed `COLLATE NOCASE` from `fetchPathIds` and `getOrCreatePathId` — path normalization on insert makes exact-match correct and eliminates per-row collation overhead
- Added `addEntriesWithWorkingSet` that co-writes `workingSetEntry` rows in the same `dbPool.write` transaction as `snapshotEntry`, removing the separate `rebuildWorkingSet` SQL pass
- `BaselineService.createBaseline` now passes `alsoWriteWorkingSet: true` to `scan()` and pre-clears the working set before starting (instead of calling `rebuildWorkingSet` afterward)
- Working-set category totals populated from the already-accumulated in-memory `categoryTotals` dict via `replaceWorkingSetCategoryTotals` — avoids a SQL GROUP BY over 2.2M rows
- `ScanService.batchSize` increased from 5000 to 15000 for fewer total transactions

## Task Commits

All 5 tasks committed together as a single coherent unit:

1. **Tasks 1-5: DB write path optimization** - `c3c3ac7` (perf)

## Files Created/Modified

- `Prunr/Database/DatabaseManager.swift` — `upsertPathClassifications` bulk insert, `addEntries`/`addEntriesWithWorkingSet`/`addEntriesCore` refactor, `fetchPathIds` exact-match, `getOrCreatePathId` exact-match, `clearWorkingSetEntries`, `replaceWorkingSetCategoryTotals`
- `Prunr/Services/ScanService.swift` — `alsoWriteWorkingSet` parameter on `scan()` and `scanBody()`, batchSize 15000, yield every 1 batch
- `Prunr/Services/BaselineService.swift` — removed `rebuildWorkingSet` call, added `clearWorkingSetEntries` pre-scan, `alsoWriteWorkingSet: true` on scan

## Decisions Made

- **Multi-row chunk size of 500**: Well within SQLite's `SQLITE_LIMIT_VARIABLE_NUMBER` (32766 on macOS) for both 3-col (1500 params) and 4-col (2000 params) tables
- **Pre-clear before scan instead of DELETE inside per-batch transaction**: The `addEntriesWithWorkingSet` is called multiple times per scan; doing DELETE once before the first batch avoids wiping rows inserted by previous batches. Uses `ON CONFLICT DO UPDATE` for idempotent upserts
- **Keep `rebuildWorkingSet` defined**: Left in codebase for potential future use (e.g., repair tools) but removed from the hot scan path

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Pre-clear working set before inline scan instead of inside addEntriesCore**
- **Found during:** Task 5 implementation
- **Issue:** If DELETE ran inside each `addEntriesWithWorkingSet` call, subsequent batch calls would wipe rows inserted by the previous batch (since scan calls it once per 15000-entry outer batch)
- **Fix:** Added `clearWorkingSetEntries` method called once before scan starts in `BaselineService.createBaseline`; `addEntriesCore` uses `ON CONFLICT DO UPDATE` for idempotent upserts
- **Files modified:** DatabaseManager.swift, BaselineService.swift
- **Committed in:** c3c3ac7

---

**Total deviations:** 1 auto-fixed (1 bug — logic error in batch-delete placement)
**Impact on plan:** Fix was necessary for correctness. No scope creep.

## Issues Encountered

None beyond the batch-clear ordering issue documented above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- DB write path is now highly optimized for large (2.2M file) scans
- Phase 12 (optional initial scan) can build on this foundation
- No regressions introduced — `rebuildWorkingSet` still exists for repair scenarios

## Self-Check: PASSED

All source files verified present. Commit c3c3ac7 verified in git log.

---
*Phase: 11-faster-initial-scan*
*Completed: 2026-03-14*
