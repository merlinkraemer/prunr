# Scan Architecture Code Review — 2026-03-09

Full review of the scanning/syncing architecture across ScanService, FileScanner, MenuBarManager, BaselineService, RecentChangeService, FSEventsWatcher, DatabaseCleanupService, DiskSpaceService, GrowthJournalService, PermissionsService, and DatabaseManager.

---

## P0 — Critical Bugs

### 1. FSEventsWatcher use-after-free
**File:** `FSEventsWatcher.swift:93`
`Unmanaged.passUnretained(self)` in the C callback means if the watcher is deallocated while the stream is live, the callback accesses freed memory. Should use `passRetained` + release on cleanup. Related: the `deinit` (line 217) tries to clean up but the callback Task (line 123) might still be executing when deinit runs.

### 2. Timer memory leaks in MenuBarManager
**File:** `MenuBarManager.swift:1539, 1497`
`updateTimer` (15s interval) and `activityPulseTimer` (0.9s interval) are never invalidated — `deinit` at line 1996 is empty. They fire indefinitely after the object should be dead.

### 3. Fire-and-forget loadInventory from recent-change overflow
**File:** `MenuBarManager.swift:1910-1912`
When `refreshChangedPaths()` returns `.needsFullScan`, a bare `Task { await loadInventory() }` is spawned with no concurrency control, no `isAutoScanning` flag set, and no error handling. Can run concurrently with a user-initiated or auto scan.

### 4. hasPendingRecentChanges stuck true
**File:** `MenuBarManager.swift:1863, 1893-1894`
Set to `true` on FSEvents, but if `performRecentChangeRefresh()` exits early (e.g. `isLoading` is true), the flag is never reset. UI shows stale "changes detected" indefinitely.

### 5. DiskSpaceService hardcoded to home volume
**File:** `DiskSpaceService.swift:8-9`
`statfs()` always runs against the home directory. If the tracked path is on an external drive, all disk space calculations are wrong.

---

## P1 — High-Severity Issues

### 6. Dual scan state flags diverge
**File:** `ScanService.swift:22, 25`
`@MainActor var isScanning` and `private var scanInProgress` track the same thing from different isolation domains. They can get out of sync.

### 7. Cancellation after DB commit
**File:** `ScanService.swift:279-296`
`Task.isCancelled` is checked *after* `db.addEntries()` commits a batch. Partial scan data lands in the database before cancellation is detected. Should check before DB operations.

### 8. All FileScanner errors silently swallowed
**File:** `FileScanner.swift:71-73, 178-180`
The `errorHandler` returns `true` for every error without logging. `processFile()` catches all errors and returns `nil`. No audit trail of what was skipped or why.

### 9. Fallback auto-scan timer is non-functional
**File:** `MenuBarManager.swift:1539-1544, 1929`
Timer calls `scheduleAutomaticScan(resetDebounce: false)`, which returns immediately if `autoScanTask != nil`. After the first debounced scan schedules, the fallback effectively never fires again.

### 10. No mutual exclusion between scan paths
**File:** `MenuBarManager.swift:713-764, 1909, 1956`
Three independent triggers — `loadInventory()`, `loadInventoryFromLatestSnapshot()`, and the overflow `Task { await loadInventory() }` — can all run concurrently. The `isLoading` guard is checked but not atomically set.

### 11. O(n²) top-N tracking in BaselineService
**File:** `BaselineService.swift:566-570`
Uses `topEntries.indices.min(by:)` per insertion — linear scan each time. For 1000+ items this is ~500K comparisons. Should use a min-heap.

### 12. N+1 query in addEntries path lookup
**File:** `DatabaseManager.swift:444-454`
Batch-fetches path IDs, then falls back to individual `getOrCreatePathId()` for misses inside the batch loop.

### 13. Category filtering in Swift instead of SQL
**File:** `DatabaseManager.swift:1246-1290, 1304-1334, 1364-1408`
`fetchGrowthContributors()`, `fetchGrowthTotalsBySubcategory()`, and `fetchSnapshotDiffContributors()` fetch all rows then filter by category in a Swift loop. Should push predicates into SQL with LIMIT.

### 14. Missing index on LIKE query
**File:** `DatabaseManager.swift:900-918`
`replaceWorkingSetSubtree()` uses `p.path LIKE ?` without a supporting index on the paths table — full table scan on every recent-change refresh.

---

## P2 — Medium Issues

### 15. Debounce reset logic inverted
**File:** `MenuBarManager.swift:1926-1930`
FSEvents calls `scheduleAutomaticScan(resetDebounce: false)`, meaning subsequent events during a debounce window are ignored rather than extending it.

### 16. Startup grace period doesn't gate recent-change path
**File:** `MenuBarManager.swift:1923-1925`
Grace period only blocks `scheduleAutomaticScan()`. FSEvents can still trigger `scheduleRecentChangeRefresh()` → `loadInventoryFromLatestSnapshot()` during the first 20 seconds.

### 17. Scan progress properties reset non-atomically
**File:** `MenuBarManager.swift:696-705`
Eight `@Published` properties reset one-by-one, causing intermediate UI states and potential flicker.

### 18. Sync DB functions blocking threads
**File:** `DatabaseManager.swift:638-649, 805`
`writeCategorySnapshot()` and `fetchCategorySnapshots()` are synchronous (`dbPool.write`/`dbPool.read`) while similar operations are async.

### 19. Unreliable FDA detection
**File:** `PermissionsService.swift:31`
`hasFullDiskAccess` uses `FileManager.fileExists()` on `/Library` which is not equivalent to an FDA check. A separate `checkFullDiskAccess()` method uses TCC.db and is more reliable, but isn't used consistently. Two different checks for the same thing (line 31 vs line 95).

### 20. GrowthItem objects created then discarded
**File:** `ScanService.swift:200-238`
Every file creates a temporary `GrowthItem` with `percentOfParent: 0`, later thrown away and recreated in `finalized()`. For 1M files, that's millions of unnecessary allocations.

### 21. Incomplete pagination — re-scans all entries per page
**File:** `BaselineService.swift:688-723`
`loadMoreSubcategoryFiles` calls `collectSnapshotEntries` which re-scans ALL entries every time, then drops/skips to get the page. Should use database offset/limit.

### 22. Snapshot aggregation race condition
**File:** `DatabaseCleanupService.swift:517-530`
If `buildSnapshotSummary` throws halfway through, partial results stored via `replaceCategorySnapshots`. Not transactional.

### 23. Incorrect freelist calculation
**File:** `DatabaseCleanupService.swift:219`
`reclaimedBytes = max(0, before.dbBytes - after.dbBytes) + after.freelistBytes` double-counts potential space — freelist is internal fragmentation that VACUUM addresses.

### 24. Unbounded SQL IN clause
**File:** `DatabaseManager.swift:1191-1214`
No limit on paths passed to `IN` clause. 5000+ paths generates massive SQL. Should batch by 1000-2000.

### 25. Contradictory snapshot validation
**File:** `BaselineService.swift:309-312`
Checks `previousEntryCount > 100` then allows `minExpectedPrevious = currentEntryCount / 2`. The two thresholds can contradict each other.

### 26. pendingRecentChangePaths can grow unbounded
**File:** `MenuBarManager.swift:1880`
Each FSEvents callback unions new paths. If debounced task is slow, the Set grows without limit during high file activity.

### 27. Disk pressure not re-evaluated on FSEvents
**File:** `MenuBarManager.swift:1465, 1883`
`isUnderDiskPressure` only updates during `updateFreeSpace()`. FSEvents callbacks use the stale value for debounce interval selection.

### 28. Infinite loop risk in ancestor traversal
**File:** `RecentChangeService.swift:99-114`
While loop traverses up the path tree. Safety check at line 108 helps but is fragile — if path standardization differs between iterations, the break could be missed.

### 29. FSEvents silent stream creation failure
**File:** `FSEventsWatcher.swift:132-134`
If `FSEventStreamCreate` fails, function silently returns. `isRunning` is never set, no error logged. Same for `FSEventStreamStart` failure (lines 147-152).

---

## P3 — Low / Cleanup

### 30. Dead code: `lastFileEventAt`
**File:** `MenuBarManager.swift:255`
Set but never read anywhere.

### 31. Dead code: `categoryItems`
**File:** `MenuBarManager.swift:92`
Repeatedly reset to `[]` but never populated. Has TODO comment about removal.

### 32. Deprecated method still present
**File:** `MenuBarManager.swift:766-770`
`loadCategoryGrowthList()` marked `@available(*, deprecated)` — should be removed.

### 33. Debug prints in production
**File:** `DatabaseManager.swift:397, 476, 484-487`
`[DEBUG]` print statements left in `createSnapshot()` and `fetchAllSnapshots()`.

### 34. 3 dead methods in DatabaseManager
**File:** `DatabaseManager.swift:402-417, 605-618, 620-629`
`addEntry()`, `sumEntrySizes()`, `checkpointWalTruncate()` — unused.

### 35. print() instead of OSLog throughout
**Files:** `FileScanner.swift:106, 116, 162, 172`, `ScanService.swift:94`
All logging uses `print()` instead of structured OSLog. No log levels, can't filter in Instruments.

### 36. Orphaned paths accumulate
**File:** `DatabaseManager.swift:77-78`
`snapshotEntry` cascades on snapshot delete, but orphaned path IDs in the `paths` table are never cleaned up.

### 37. COLLATE NOCASE inconsistencies
**File:** `DatabaseManager.swift:1184, 1203`
Different syntax and placement across queries. Table definition (v7 vs v10 migration) may not match.

### 38. Duplicate backfill functions
**File:** `DatabaseCleanupService.swift:339-365`
`backfillRecentCategorySnapshots` and `backfillRecentSubcategorySnapshots` are 95% identical.

### 39. Busy-wait polling in cleanup
**File:** `DatabaseCleanupService.swift:314`
`waitForAppToBeIdle()` polls every 5 seconds instead of using notifications.

### 40. DiskSpaceService repeated syscalls
**File:** `DiskSpaceService.swift:26-40`
`getTotalSpace()` and `getFreeSpace()` each call `statfs()` separately. Should cache or combine.

---

## Architectural Recommendation

The biggest structural concern is **lack of a single scan coordinator**. Three independent triggers (manual, auto-scan, recent-change) can all invoke scanning concurrently with no shared lock or state machine. A centralized `ScanCoordinator` actor that serializes all scan requests would fix P0 #3, P1 #10, and simplify the debounce/gating logic considerably.
