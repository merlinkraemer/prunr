# App performance review, 2026-11-02 (O21)

Code-level review of branch `drain/stack-2026-11-01` at 85ef096 (most complete code, green on Mac). Line numbers refer to that commit. Numbers are `PERF` lines from the Mac `test Prunr` run of 85ef096 (Debug, compare relative only) plus `perf-baseline-2026-11-02.md`. Read-only: no code changed. Estimates are marked "est"; nothing here was profiled on a live app.

## Summary

The quiet-system idle path is clean: `IdleCPUTests` passes (quiet temp dir, 30 s), the full-scan backoff and the 24 h dirty-root cooldown hold, and "/" is already clamped to home for the watcher. The remaining idle cost is a busy home folder: every watcher batch that survives the noise filter starts a full "present" pipeline (inventory, drilldown, disk accounting, change feed) every 1.5 s, whether or not the panel is open, and the FSEvents callback itself runs on the main thread. That is the most likely remaining source of steady background CPU (bug #2 class) and the first thing to fix.

## Top 10

| # | Sev | Where | Cost | Fix | Gain | Risk |
|---|-----|-------|------|-----|------|------|
| 1 | high | `MenuBarManager.swift:3073` `performRecentChangeRefresh`, 3207-3208, 1463, 2218-2232 | Each watcher refresh (fixed 1.5 s cadence under steady writes, `replacingExisting: false` at 3264) reloads inventory, drilldown groups, disk accounting, then the change feed and storage history, with the panel closed | Split persist from present: keep the working-set and journal write; when the panel is hidden only set a `presentationStale` flag and run the reload once on open | Closed-panel steady state drops to the DB write; est 70-90 % fewer reads under a noisy home | low-med |
| 2 | high | `FSEventsWatcher.swift:240`, `FSEventsNoiseFilter.swift:63`, `MenuBarManager.swift` `filteredRecentChangePaths` | Stream is scheduled on the main queue with FileEvents + NoDefer; per event a C-string copy, 9 string interpolations in the prefix check, URL standardization; the filter runs a second time on main | Own serial utility queue for the stream, classify there, hoist `"/" + prefix` to static constants, hop to main only for non-empty batches, drop the duplicate filter pass | No main-thread wake for ignored-only batches; est half the per-event cost | low |
| 3 | med | `MenuBarManager.swift:2615` `updatePathSize`, `DatabaseManager.swift:1052` | `SUM(sizeBytes)` over every `snapshotEntry` row of the latest snapshot per path, after each full scan (1119, 1443) and on first panel open (`MenuBarView.swift:410`). The result (`pathSizeBytesByID`, `monitoredPathSizeBytes`) is read by no view | Delete it, or sum `workingSetCategoryTotal` if a reader appears | Removes an O(files) read (est 0.3-2 s on a home-sized scope) | very low |
| 4 | med | `AppCatalog.swift:142`, 153, 162 | Main-actor scan of /Applications (depth 2, reads every Info.plist); the cache is dropped on every app launch system-wide, and `catalog()` runs inside every `refreshChangeFeed` (`MenuBarManager.swift:2250`) | On launch, add only the launched app (`NSRunningApplication.bundleURL`) to `located`; do the one full scan off main | Removes main-thread I/O bursts (est 50-300 ms each) | low |
| 5 | med | `RecentChangeService.swift:83-118` | One `dbPool.write` per target (up to 192) plus one for the journal deltas: one commit and WAL sync each. `watcher.burst200.singleFileEvents` 80 ms, 0.40 ms per event | Do lstat/enumeration first, then one write transaction for all targets and the deltas. Optionally `PRAGMA synchronous = NORMAL` in `prepareDatabase` (WAL-safe) | burst200 est 80 to 20-30 ms; far fewer fsyncs | low-med |
| 6 | med | `DatabaseManager.swift:228-229`, 390-396 | Redundant indexes on the two largest tables: `idx_snapshotEntry_snapshotId` is a prefix of `(snapshotId, pathId)`, `idx_workingSetEntry_trackedPath` a prefix of the unique `(trackedPathId, pathId)`. Every scanned file pays 2 extra B-tree inserts | Migration that drops both | est 10-20 % of `scan.addEntriesWithWorkingSet.10k` (131-146 ms), smaller DB file | low; schema, needs Merlin |
| 7 | med | `FileScanner.swift:337`, 360-366, 66-75 | Per file: an actor hop (`waitToProduce`), 3 `Date()` calls and 3 lock takes for progress/consumer-wait bookkeeping | Reserve capacity in chunks (`waitToProduce(count: 256)`), mark progress every N entries | est 10-30 % traversal CPU on millions of files (unmeasured: no real-scan PERF) | low |
| 8 | low-med | `DrilldownStore.swift:68`, `MenuBarManager.swift:2218`, hosting view kept at 2436 | `groupsByCategory` and `allCategories` are reassigned on every refresh even when equal; with the hosting view kept installed while hidden, the panel views are invalidated each cycle. `reload` also re-reads every loaded file category | Assign only when changed (as `refreshChangeFeed` already does); skip file re-reads when group rows are unchanged | Fewer SwiftUI updates and reads per cycle | low |
| 9 | low-med | `BaselineService.swift:614-662`, 587, 456 | Per path per refresh about 8 separate pool reads; `resolveGrowthComparisonSnapshots` runs twice; `getDiskAccounting` loads all snapshots (up to 500) to use 2 | One `dbPool.read` per path for the lot; `limit: 2` for disk accounting | Fewer round trips; small absolute win, multiplied by #1's cadence | low |
| 10 | low | `PrunrMenuBar.swift:39` | DB open, migrations and staging cleanup run synchronously on main in `applicationDidFinishLaunching`. `real.startup.initialize` 41 ms (includes the one-time v26 migration); a heavy migration on a large DB blocks launch | Create the status item first, run `initialize` detached, continue launch on completion | Launch never blocks on migrations | med (ordering of everything touching `DatabaseManager.shared`) |

## Notes by area

### 1. Idle

- Timers: `updateTimer` 60 s (`MenuBarManager.swift:2606`, no tolerance set) calls `updateFreeSpace`, which reads `volumeAvailableCapacityForImportantUsage` on main (can be slow) and writes three observed properties each tick. Fix: add tolerance (10-15 s), read off main, assign only on change. Low.
- `DiagnosticsReporter` samples CPU every 20 s with tolerance and flushes every 30 min: fine.
- Activity pulse timer (0.9 s) runs only while scanning: fine.
- Dirty-root path is well bounded (15 s doubling to 30 min, full rescan cooldown = max(30 min, scan interval >= 24 h)). The non-dirty path is not: see #1 and #2.
- Gap: `IdleCPUTests` uses a quiet temp dir. Add a noisy-idle variant (write a file in the tracked root every 500 ms for 30 s, panel hidden) that asserts CPU and counts `inventory-aggregation` ops. It is the acceptance test for #1.

### 2. Startup and panel open

- Panel open always calls `refreshChangeFeed` (`MenuBarView.swift:382-385`), even if no journal write happened since the last build: feed 30 ms on real data, 2.2 s at 200k buckets. Fix: keep a journal generation counter and skip when unchanged. Pairs with #1 (stale flag).
- First open `.task` runs `updatePathSize` (#3) and a quick inventory plus drilldown reload.
- Observation is `@Observable`, so tracking is per property; views read few churny properties. `sortedCategories` re-sorts an already sorted ~15-item array on each of 5 reads per body: negligible.
- `EpisodeBuilder.swift:678/813` builds a `DateFormatter` per row caption; cache per format. Low.

### 3. Scan

- Traversal is fts with bounded backpressure (20k outstanding, 10k batches); drilldown accumulator is bounded (top 400 candidates per group); `FileDateHistory` is bucketed. No whole-tree retention found.
- Per-file overhead: #7. Write amplification: every file goes to both `snapshotEntry` and `workingSetEntry` (#6 trims the index side; dropping the full snapshot payload would be larger but is a data/schema decision).
- Cancellation is checked per entry and per batch; the watchdog polls every 5 s only during a scan.

### 4. Watcher bursts

- Coalescing: FSEvents latency 1 s plus a 1.5 s debounce that does not slide (good for liveness, but sets the steady cadence in #1).
- Per-event DB work: #5. Over 192 targets or 25k paths escalates to a full refresh, gated by cooldown: fine.

### 5. Database

- Indexes cover the hot WHERE/ORDER BY (journal by trackedPath/time and unit/time, working set by trackedPath/pathId, drilldown top entries, place children). Only redundancy found: #6.
- N+1: #9 (per-path reads), #5 (per-target writes).
- Long writes: first prune after upgrade now 2.6 s total but `prune.first.longestWriterWait` 92.65 ms, so the chunking holds the writer briefly.
- WAL: GRDB pool, default `synchronous`, TRUNCATE checkpoint after cleanup and at most every 60 s via cleanup, VACUUM gated (12 h, >= 96 MB and >= 18 % free). Fine; `synchronous = NORMAL` is the one tuning worth trying (#5).
- 200k-bucket feed rebuild (2.2 s, half SQL, half `EpisodeBuilder`): incremental feed cache as in the baseline doc; low priority while real data is 30 ms.

### 6. Memory

- No retain cycles found. `FSEventsWatcher` balances `passRetained` in `stop`/`deinit`; timers and the watcher callback capture `[weak self]`. Some stored Tasks capture the manager strongly, harmless since it lives for the app's lifetime.
- Caches: `OwnerTokenCache` capped at 50k; `UnitIconResolver` and `AppCatalogProvider.located` are unbounded but keyed by unit or app (hundreds). No action.

## Suggested order

1. #1 + #2 together on one branch, with the noisy-idle test (non-UI, may land).
2. #3 and #4 (small, independent).
3. #5, then #8 and #9.
4. #6 needs Merlin (schema). #10 and #7 last.
