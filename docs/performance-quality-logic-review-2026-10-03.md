# Performance, code quality, and system logic review

**Date:** 2026-10-03
**Status:** findings only. Nothing in this note has been implemented.
**Scope:** `Prunr/` and `PrunrTests/`. Vendored GRDB (`LocalPackages/`) and the marketing site are out of scope.
**Method:** static reading of the current tree. Line numbers refer to that tree. This is not a runtime profile.

24 verified findings: 10 high, 14 medium. No critical issue still open.

The June CPU loop is closed. Failed full scans back off from `lastFullScanAttemptAt`, capped at 30 minutes (`MenuBarManager.swift` `failedFullScanMaximumBackoff`). Launch cleanup no longer deletes a fresh `.scanning` row: incomplete snapshots younger than 15 minutes are left alone, and cleanup waits until the app is idle (`DatabaseCleanupService.swift`). Those bugs stay in `docs/cpu-leak-analysis-2026-06-15.md` and `docs/scan-hardening-review-2026-08-21.md`. They are not re-listed here.

## Short version

The scan stack is careful. The headline growth number is not.

Three bugs sit on the path the menu uses every day:

1. A reconciliation can count the same bytes twice in the growth journal (`L1`).
2. A crash in the window after a scan is marked complete and before the working set is rebuilt causes the next launch to delete that snapshot (`L2`).
3. A failed incremental refresh drops the paths it was supposed to retry (`L3`).

Every home-folder rescan also does two expensive things the product does not need: it loads every changed path into memory only to sum by category (`P1`), and it writes the tree a second time when copying the snapshot into the working set (`P2`).

Scan policy, cache generations, and the panel all live in `MenuBarManager` (3,668 lines). `performSilentReconciliation` has no tests.

## What already holds

- Incomplete snapshots stay out of comparisons. `fetchRecentSnapshots` / `fetchAllSnapshots` filter `lifecycle == complete`.
- A consumer-side cancel or database error deletes the in-flight snapshot before it can be published. `throwIfCancelled` runs again before `markSnapshotComplete` (`ScanService.swift`).
- The working set is rebuilt only after `createBaseline` returns (`BaselineService.createBaseline`, `alsoWriteWorkingSet: false` then `rebuildWorkingSet`).
- FSEvents batches that overflow, drop events, or are directory-heavy mark the root dirty instead of applying a partial path list.
- Failed full scans do not tight-loop. Backoff is exponential up to 30 minutes.

One fragile contract: when the FTS producer breaks early it calls `continuation.finish()` with no error (`FileScanner.swift` around the end of the scan loop). Publish stays correct only because `ScanService` checks the cancellation token afterward. A later edit that removes that check would persist a truncated scan as complete.

## System logic

### L1 — High — Growth journal double-counts the minute after a snapshot

`BaselineService.swift:153–172`, `DatabaseManager.swift:604–614` and `2263–2266`, `GrowthJournalService.swift:145–148`

A full scan deletes journal buckets with `bucketStart` strictly after the previous snapshot time, then inserts the authoritative delta with an additive upsert (`deltaBytes = deltaBytes + excluded.deltaBytes`). Buckets are floored to the minute, so realtime deltas in the remainder of the previous snapshot’s minute have `bucketStart <=` that timestamp and survive. The new snapshot delta includes those same bytes again.

The 7-day growth number can stay high after a reconciliation. A compile or download in the seconds after a scan is the expensive case, and the extra bytes remain until that bucket ages out.

Reclaim every bucket at or after `floor(previous snapshot)`, then write the authoritative total into its own bucket without adding it to leftover provisional bytes.

### L2 — High — Launch cleanup deletes a finished snapshot it should publish

`DatabaseCleanupService.swift:201–221`, `BaselineService.swift:116–135`, `ScanService.swift:478`

`cleanupAbandonedSnapshots` deletes `lifecycle = complete` rows whose `createdAt` is newer than the working set. `rebuildWorkingSet` stamps the working set with that same `createdAt`, so a healthy publish does not match. A crash after `markSnapshotComplete` and before the rebuild does match, and the handler deletes the snapshot instead of finishing the rebuild.

A completed home-directory scan can vanish on the next launch. The menu keeps the previous working set, and the time already spent scanning is lost.

When a complete snapshot is newer than its working set, call `rebuildWorkingSet`. Delete only incomplete rows older than the 15-minute grace period.

### L3 — High — A failed incremental refresh drops the paths it was supposed to retry

`MenuBarManager.swift:3240–3292`, `RecentChangeService.swift:110–127`

`performRecentChangeRefresh` clears `pendingRecentChangePaths` before calling `RecentChangeService`. Per-target errors are logged and swallowed. If nothing merged, the service returns `.noChanges`, and the caller ignores that case.

The footer can leave “changes detected” while the working set and journal stay stale until some later event happens to mention those paths again.

On any target failure, put the paths back or return `.needsFullScan`. Treat an empty merge after errors as failure, not as no changes.

### L4 — Medium — One failed root still leaves the other roots on a new snapshot

`MenuBarManager.swift:1201–1209`, `ScanService.swift:485–497`

`createBaselines` scans independent roots in a throwing task group. The first error cancels the rest, but each `createBaseline` commits its snapshot and rebuilds its working set before returning. `ScanService` rolls back only the root that threw.

A multi-root scan can fail overall while some folders already show post-scan totals and others stay on the previous generation.

Publish per-root success and failure. Do not present a mixed generation as one aborted scan.

### L5 — Medium — Unexplained disk gap mixes free space from one volume with every root

`BaselineService.swift:1274–1309`

`getDiskAccounting` keeps `freeSpaceDelta` from the first successful path and adds `explainedDelta` across every tracked path. `unexplainedDelta` is `abs(freeSpaceDelta + explainedDelta)`.

Tracking a home folder and an external volume produces an unexplained gap that does not describe either disk.

Compute the gap per volume, and only show it for the volume the footer is talking about.

### L6 — Medium — Check Growth will not flush a dirty root

`MenuBarManager.swift:1585–1605`, `3207–3211`, `3300–3308`

`checkGrowth` calls `performRecentChangeRefresh(allowFullRefresh: false)`. If the watcher has already marked the tree dirty, that path only reschedules or holds the refresh for the cooldown. It never starts the authoritative scan.

The control the user reaches for after a big change can return without updating the number, while a full refresh is already known to be required.

Let an explicit check bypass the cooldown, or say in the footer that a full rescan is waiting.

### L7 — Medium — Hard links are summed once per path

`FileScanner.swift:139–141`, `215`, `263–267`

Traversal uses `FTS_PHYSICAL`, so each directory entry is a file. `diskUsageBytes` reads `st_blocks` for that entry. Nothing dedupes `(st_dev, st_ino)`.

Backups, cloned build artifacts, and other hard-linked trees report more allocated bytes than the volume did.

Dedupe inodes within a scan, or label the total as the sum of paths rather than disk used.

### L8 — Medium — Large skipped trees never show up as partial coverage

`FileScanner.swift:307–308`, `364–394`

Symlinks are not followed (`FTS_SL` / `FTS_SLNONE`). Photos libraries, Mail, Trash, and iCloud fragments are `FTS_SKIP`. The stream still ends normally and the snapshot is marked complete, with no skipped-root record.

Most FTS errors do abort. `abortError(forFTSErrno:)` continues only for `ENOENT` and `ESTALE`. Permission and other systematic errors fail the scan. The coverage hole is the intentional skip list, not a swallowed `EACCES`.

A home scan looks authoritative while some of the largest stores on the disk were never read.

Persist the skip list on the snapshot and show it next to the total.

## Performance

### P1 — High — Every rescan materializes the full path diff, then throws it away

`DatabaseManager.swift:2883–2930`, `BaselineService.swift:159–167`

`calculateDeltas` runs a union of two snapshots and `fetchAll`s every changed path, including the path string, ordered by absolute change. `BaselineService` then walks that array only to sum bytes by category and subcategory.

A home-folder reconciliation pays a full snapshot diff plus a large Swift allocation for a handful of category totals.

Aggregate in SQL through `pathClassification`. Keep the row-level diff for a drilldown that asks for it.

### P2 — High — A successful scan writes the tree twice

`BaselineService.swift:116–135`, `DatabaseManager.swift:1683–1726`

`createBaseline` scans with `alsoWriteWorkingSet: false`, then `rebuildWorkingSet` deletes the live working set and `INSERT…SELECT`s every `snapshotEntry` row, plus a `GROUP BY` for category totals. The inline working-set write path already exists and is unused here.

After a multi-million-file scan, SQLite writes the same corpus again before the menu can trust the new totals.

Use the inline working-set write on the production baseline path, or chunk the copy so it is not a second full-table transaction.

### P3 — High — The Caches drilldown loads every cache row and re-sorts per file

`DatabaseManager.swift:1153–1250`

`fetchCacheApplicationGroups` reads every cache-classified path for the snapshot. `makeCacheApplicationGroups` appends each row to that app’s top list, sorts with `localizedStandardCompare`, and drops the tail. There is no `LIMIT` in the SQL.

Opening Caches & System gets slower as the cache corpus grows, and the cost is paid again on the working-set variant of the same query.

Store the cache-owner key at classification time and keep a bounded top-N in SQL. The scan already knows the owner.

### P4 — High — Each incremental batch reloads the whole inventory

`MenuBarManager.swift:3314–3326`

After a debounced FSEvents update, `loadInventoryFromLatestSnapshot` runs `getInventoryWithTrends` for every enabled path. Category totals were just written to `workingSetCategoryTotal`. The comment at the call site says this is deliberate, so the UI cannot drift from the database. The debounce is 1.5s, and the watcher follows the home folder.

Under compile or sync traffic the menu re-aggregates and republishes observable state about as often as the disk is noisy.

Apply the journal deltas already in hand to the on-screen categories. Re-aggregate when the snapshot id changes.

### P5 — Medium — The first open warms a breakdown for every visible category

`CategoryGrowthListView.swift:719–730`, `MenuBarManager.swift:1819–1830`

`preloadInitialSubcategoryBreakdownsIfNeeded` starts one task per visible category. Each task hits subcategory or working-set queries. A warmup flag stops it from repeating every open. The panel hosting view is kept across open and close, so this is not the old “rebuild the SwiftUI tree on every popover” bug.

The first popover after launch fans out a query per category before the user has drilled into any of them.

Warm the largest category, or the one under the pointer. Load the rest on drilldown.

### P6 — Medium — Every directory during a scan resolves standardizedFileURL

`FileScanner.swift:348–350`

`shouldSkipDirectory` builds a standardized file URL for each FTS directory node. That touches the filesystem on the hot traversal path, on top of the stat FTS already did.

Deep trees spend time in path normalization that the skip rules mostly do not need.

Match skip rules on the FTS path and the directory name. Standardize only when a rule is ambiguous.

### P7 — Medium — FSEvents classification runs on the main queue

`FSEventsWatcher.swift:196–240`

The stream is scheduled on `DispatchQueue.main`. The callback parses the batch, calls `standardizedFileURL` per path, decides dirty-root promotion, then hops to the main actor. The comment says delivery requires the main run loop. A dispatch queue does not.

A burst of file events does string and URL work on the same queue that draws the panel.

Classify on a background queue. Deliver one coalesced batch to the main actor.

### P8 — Medium — Cache-owner lookup is a leading-wildcard LIKE

`DatabaseManager.swift:1098–1099`

Cache drilldown pages filter paths with `LIKE '%/Library/Caches/…%' COLLATE NOCASE`. A leading percent sign cannot use the path index.

Paging a single app’s caches still scans the joined snapshot or working-set rows.

Filter on a cache-owner column written at ingest.

### P9 — Medium — Incremental targets are scanned and committed one at a time

`RecentChangeService.swift:83–113`

Up to 192 refresh targets are handled serially. A subtree target runs its own FTS scan, staging writes, and `replaceWorkingSetSubtree` transaction.

A burst of directory events becomes a queue of small scans instead of one staging session per tracked root.

Batch file stats into one write per root per debounce window. Keep the full-scan escalation when the batch is too wide.

## Code quality

### Q1 — High — MenuBarManager is the scan policy, the cache, and the panel

`MenuBarManager.swift` (3,668 lines), `PrunrMenuBar.swift`

One main-actor type owns the panel, inventory state, full scans, silent reconciliation, FSEvents debounce, cooldown math, and subcategory cache generations. Views read that flag surface directly. Two full-scan entry points, `loadInventory` and `performSilentReconciliation`, repeat progress and publish steps.

A cooldown or invalidation change has no single place to land, and the SwiftUI views have to know the ordering of the flags.

Move “when to scan, debounce, and publish” into one module. Leave `MenuBarManager` as the AppKit and observation adapter.

### Q2 — High — Snapshot queries and working-set queries are copied in pairs

`DatabaseManager.swift` (2,957 lines)

The database type holds migrations, snapshots, the working set, the journal, and classification. Several reads exist twice, differing mainly by table name: snapshot entries versus working-set entries, and the cache-application variants.

A join or classification fix has to be applied twice, and the copies drift.

One query implementation parameterized by storage mode. Keep the public reads small.

### Q3 — High — The reconciliation path that runs in production is untested

`PrunrTests/`, `MenuBarManager.performSilentReconciliation`

About 118 test methods exercise `DatabaseManager`, `BaselineService`, and recent-change behavior well (`PrunrSmokeTests.swift` is most of them). `performSilentReconciliation` has no test references. Menu-bar tests cover presentation, clamping, and cache generation, not the cancel, permission, and failure matrix of a full scan.

The loop that used to spin a failed home scan at full CPU is exactly the kind of policy that still lives only inside `MenuBarManager`.

Test refresh outcomes through a narrow orchestration interface: cooldown, failure backoff, dirty promotion, and publish-or-rollback.

### Q4 — Medium — A second app still compiles next to the menu bar

`MainViewModel.swift`, `PathManager.swift`, `CategoryDetectionService.swift`, `DeltaService.swift`, `MenuBarManager.swift:2092` and `:3334`

`MainViewModel`, `PathManager`, and `CategoryDetectionService` have no production callers. `DeltaService` is only used by `MainViewModel`. `autoInitializeIfNeeded` and `accumulateGrowthStory` are defined on `MenuBarManager` and never called. Tests still drive `MainViewModel`.

Readers can follow a scan flow that the menu bar does not use, and fixes to the live path do not update the dead one.

Delete the unused types and retarget those tests at `BaselineService` and `SettingsStore`.

### Q5 — Medium — “Is this path inside the root?” is implemented in several places

`MenuBarManager.pathIsContained`, `SettingsStore`, `PermissionsService`, `RecentChangeService`, `GrowthCategory.isUnderDirectory`, `PrunrInternalPaths`

Containment, trailing-slash prefixes, and standardized URLs are reimplemented across the menu manager, settings, permissions, recent-change routing, and category classification.

A slash, symlink, or `/` versus home mistake has to be hunted across modules.

One path-scope helper used by the watcher, permissions, and incremental routing.

### Q6 — Medium — Sizes are shown in decimal units and thresholded in binary units

`FormattedBytes.swift`, `GrowthCategory.swift`, `GrowthJournalService.swift`, `MenuBarManager.swift` around `2630` and `2644`

`formattedBytes` steps by 1,000. The menu-bar title uses `1_000_000_000` for GB. `bigFileThreshold` is `100×1024²`, the journal floor is `1×1024²`, and disk pressure uses `40_000_000_000`. `GrowthItem` carries a second private formatter. A regression test treats `1024³` as a GB.

The same byte count can cross a threshold in one place and miss the label the UI shows.

One formatter and named constants for display base, floors, and pressure.

### Q7 — Medium — The two main views are bound to manager lifecycle flags

`MenuBarView.swift` (2,033 lines), `CategoryGrowthListView.swift` (1,387 lines)

Both views call load, permission, and drilldown methods on the manager and keep parallel onboarding state. Scan policy and layout live in the same edits.

A UI change is an easy way to disturb refresh behavior, and the views are hard to exercise without the full manager.

Pass a read-only inventory and activity model into the views. Keep mutation on the orchestration side.

## Where the code is heavy

| Module | Lines | Role in the running app |
| --- | ---: | --- |
| `MenuBarManager.swift` | 3,668 | Panel, scans, watcher policy, caches |
| `DatabaseManager.swift` | 2,957 | Schema, snapshots, working set, journal |
| `MenuBarView.swift` | 2,033 | Popover, bound to manager flags |
| `CategoryGrowthListView.swift` | 1,387 | Drilldown and warmup |
| `BaselineService.swift` | 1,384 | Baseline, inventory, disk accounting |
| `MainViewModel.swift` | 516 | Tests only. Not used at runtime |

Line counts from `wc -l` on 2026-10-03. `PrunrTests` has about 118 test methods, concentrated in `PrunrSmokeTests.swift`.

The scan and storage stack is the durable part: `FileScanner`, `ScanService`, `BaselineService`, and `RecentChangeService` have explicit invariants, and the smoke tests follow them. The cost of the next feature is `MenuBarManager` plus the paired SQL in `DatabaseManager`.

## Order to act

1. Fix journal reclaim so a reconciliation replaces provisional bytes instead of adding to them (`L1`).
2. On the next launch, rebuild a complete snapshot that never reached the working set. Do not delete it (`L2`).
3. Keep failed incremental paths queued (`L3`). This is the silent stale-menu bug.
4. Stop materializing full deltas and stop copying the snapshot into the working set a second time (`P1`, `P2`). That is the cost of every home-folder rescan.
5. Then narrow `MenuBarManager` enough that silent reconciliation and cooldown policy have a test (`Q1`, `Q3`). The cache drilldown (`P3`) can land with that, because the owner key belongs in classification, not in a Swift sort.
