# Perf on real data, prepared 2026-10-31 (box prep, Q10)

Goal: find the hot paths, have one test run at the next Mac open print the numbers, make only clear low-risk fixes. No Swift compiler on dev, so nothing here was compiled or timed in Swift. All SQL timings below are Python `sqlite3` on dev against a copy of `prunr-data/prunr-2026-10-30.db` (the slim snapshot, 33 MB, migrations to v25). They show plans and relative cost, not app timings.

## What the snapshot holds

| Table | Rows | Note |
|-------|------|------|
| growthJournalBucket | 2,742 | 2,600 scan, 142 watch, 906 units, one tracked path, 15 Oct to 29 Oct |
| workingSetPlaceChild | 40,466 | 3,095 places; one place (`~/Library/Preferences`) has 21,582 children |
| workingSetTopEntry | 25,166 | with `paths` (25,166 rows after slimming) |
| workingSetGroupTotal | 1,020 | |
| snapshot | 9 | |
| growthJournalDetail | none | v26 not in the snapshot; the plan work below created the table in a scratch copy |

The real DB is 2.7 GB because of `snapshotEntry`, `workingSetEntry` and `paths` (millions of rows), which the slim snapshot drops. Feed and place-page reads never touch them unless the drilldown index is `building`.

## Hot paths (ranked)

1. **Opening a big place: `fetchPlaceChanges` read every child.** It called `mergedPlaceChildren` (no LIMIT) only to sum bytes and look up at most about 50 names. On the 21,582-child place: 344 ms in SQLite alone, plus a Swift `lowercased()` dictionary and sort over all rows. The page opens `fetchPlaceContents` (LIMIT 51, 0.9 ms) and `fetchPlaceChanges` together, so the second one dominated. Fixed (see below).
2. **Feed rebuild on a large journal.** `fetchJournalSlots` plus `EpisodeBuilder.build`; the 200k-bucket fixture takes about 2.4 s, off the main thread (accepted). On the real snapshot the SQL side is small: 2,698 slots from 2,742 buckets, 45 ms in Python, dominated by `strftime` per row and the temp b-tree for GROUP BY. Plan uses `idx_growthJournalBucket_identity (trackedPathId, bucketStart)`. Nothing to fix; the cost scales with bucket count, so the real number at Mac open is what matters.
3. **Multi tracked path place read.** `fetchPlaceContents` with more than one tracked path does `GROUP BY name ORDER BY totalBytes` over every child (temp b-tree for GROUP BY and ORDER BY): 210 ms on the 21k place versus 0.9 ms with one path. Only hit when the user tracks two or more paths. Not fixed (would need a different query shape; see "Left alone").

Also measured and fine: watcher write path (`applyWorkingSetChanges`: group, top-entry, place-child upserts, detail upsert) is per-group indexed statements with cached statements, no N+1 (stats and fileCount lookups are per touched group, not per change); `fetchPlaceChanges` detail query seeks `sqlite_autoindex_growthJournalDetail_1 (trackedPathId, unitRoot, bucketStart range)`; `MIN(bucketStart)` over detail is a covering-index seek, also with two ids.

## EXPLAIN findings

Format: query, plan, rows, time (Python).

| Query (Swift source) | Plan | Rows, ms |
|----------------------|------|----------|
| `fetchJournalSlots` | SEARCH growthJournalBucket USING INDEX idx_growthJournalBucket_identity (trackedPathId=? AND bucketStart>?); TEMP B-TREE FOR GROUP BY | 2,698, 45 |
| `fetchOldestCompleteSnapshotDate` | SEARCH snapshot (idx_snapshot_trackedPathId) | 1, 0.1 |
| `fetchRecordedFreeSpace` | SCAN snapshot; TEMP B-TREE FOR ORDER BY | 9 rows, 0.1 (tiny table, fine) |
| `fetchPlaceContents` one path | SEARCH workingSetPlaceChild USING INDEX idx_workingSetPlaceChild_size (trackedPathId=? AND unitRoot=?), ordered by the index, LIMIT 51 | 51, 0.9 |
| `fetchPlaceContents` two paths | same index, then TEMP B-TREE FOR GROUP BY and FOR ORDER BY | 51, 210 |
| `mergedPlaceChildren` (before fix, in `fetchPlaceChanges`) | SEARCH ... idx_workingSetPlaceChild_size (trackedPathId=? AND unitRoot=?), no LIMIT | 21,582, 344 |
| `fetchPlaceChanges` sum (after fix) | SEARCH ... USING COVERING INDEX idx_workingSetPlaceChild_size | 1, 10 |
| `fetchPlaceChanges` name lookups (after fix) | SEARCH ... USING INDEX sqlite_autoindex_workingSetPlaceChild_1 (trackedPathId=? AND unitRoot=? AND name=?) | 60 names, 2 |
| `MIN(bucketStart)` on growthJournalDetail | SEARCH ... USING COVERING INDEX idx_growthJournalDetail_trackedPath_time (trackedPathId=?) | 0.2 |
| detail deltas for a place and span | SEARCH ... USING INDEX sqlite_autoindex_growthJournalDetail_1 (trackedPathId, unitRoot, bucketStart range); TEMP B-TREE FOR GROUP BY | 43 ms on a synthetic 2.3M-row detail table |
| `fetchJournalDetailTotals` (per full scan, 1 day span) | SEARCH ... idx_growthJournalDetail_trackedPath_time (trackedPathId, bucketStart range); TEMP B-TREE FOR GROUP BY | 625 ms on the synthetic 2.3M-row table (a worst case, far above the real bound of about 30 days times top 20 children per place per bucket) |
| `pruneGrowthJournalBuckets` | SEARCH ... idx_growthJournalBucket_trackedPath_time (ANY(trackedPathId) AND bucketStart<?), a skip-scan, because sqlite_stat1 exists | fine |
| prune of growthJournalDetail without statistics | **SCAN growthJournalDetail** (full table) | see below |
| prune of growthJournalDetail after ANALYZE | SEARCH ... idx_growthJournalDetail_trackedPath_time (ANY(trackedPathId) AND bucketStart<?) | fine |
| `fetchDrilldownTopFiles` | SEARCH t USING COVERING INDEX idx_workingSetTopEntry_group_size; SEARCH p USING INTEGER PRIMARY KEY | 0.1 |
| watcher statements (top-entry stats, delete by path, place-child delete) | all index seeks on the PKs or `idx_workingSetTopEntry_group_size` | single row |

Findings to know about, none fixed:

- **Detail prune scans until statistics exist.** `DELETE FROM growthJournalDetail WHERE bucketStart < ?` has no leading `trackedPathId`, so with no `sqlite_stat1` row it is a full scan. `optimizeQueryPlanner` runs `PRAGMA optimize = 0x10002` at startup, which analyzes a table that has no statistics yet; after that it skip-scans like the bucket table. If the real run shows the prune slow right after the v26 upgrade, that is why; it self-heals after the first optimize on a non-empty table. A `bucketStart`-only index would add a write cost on every watcher event, so it is not worth it.
- **`growthJournalBucket` has four indexes and one is redundant.** `idx_growthJournalBucket_trackedPath_time (trackedPathId, bucketStart)` is a prefix of `idx_growthJournalBucket_identity` and the planner already picks the identity index for every feed query. Dropping it saves one index write per bucket upsert (0.18 MB here). Schema change, left for a decision.
- **Multi tracked path `fetchPlaceContents`** (above). Single tracked path is the normal case.
- **`fetchPlaceContents` while the index is `building`** reads the whole `workingSetEntry` range of the place and resolves each path in Swift; the existing `DRILLDOWN_INDEX_MEASURE onDemand` lines cover it.

## Fix made

`perf: read place children by name in fetchPlaceChanges` (commit `f6d642c`). `fetchPlaceChanges` now sums `totalBytes` in SQL and looks up only the names that changed, in chunks of 400. Results are meant to be identical: `currentBytes` is the sum over all children, each listed child gets its size now by case-insensitive name, and the `building` path keeps the full merged read. **Not compiled on dev**; the `GrowthJournalDetailTests` place-page tests (`testPlaceChangesListSpanDeltasRemovedChildrenAndFallBackBeforeRecording`, `testSmallChangesFoldIntoOtherChanges`) are the check. If they fail or it does not build, revert that one commit; nothing else depends on it.

## Left alone, on purpose

- Redundant bucket index and any `bucketStart` detail index (schema, small win).
- Two tracked path `fetchPlaceContents` query shape.
- Feed rebuild itself (accepted, off main).
- Scan persistence: 500-row multi-row INSERT chunks, one transaction each, `fetchPathIds` per chunk; no obvious waste, only the Mac number tells.
- VACUUM: skipped at startup by design (`DatabaseManager` comment); `DatabaseCleanupService` vacuums only after reclaiming rows when `shouldVacuumNow`, and `compactDatabaseNow` forces it. Not measurable on dev; the 2.7 GB file makes a VACUUM take minutes, which is why it stays out of startup.

## The test at Mac open

`PrunrTests/PerfBaselineTests.swift` prints `PERF <name> <ms>` (best of N runs, plus `.median` lines). Run on the Mac with the slim snapshot in place (`~/dev/build/prunr-snap/slim.db`, or `PRUNR_REPLAY_DB`), for example `mac-queue add <dir> <ref> test Prunr`, then `grep '^PERF ' <log>` (each line goes to both stdout and NSLog). Run it only on an otherwise idle Mac; it seeds about 20k working-set rows and 29k detail rows per test.

Lines that are counts, not milliseconds: `real.feed.rows`, `real.feed.places`, `real.biggestPlace.children`.

| PERF line | What it times | Compare against |
|-----------|---------------|-----------------|
| `feed.fixture.changeFeed` | `changeFeed` on the 15-change fixture | a few ms; anything above 50 means the path regressed |
| `feed.200k.sqlSlots`, `feed.200k.episodeBuild`, `feed.200k.changeFeed` | the SQL read, the pure build, both with the oldest-snapshot lookup, on 200k buckets in 2 tracked paths | whole path about 2.4 s (accepted); the existing `CHANGE_FEED_MEASURE` line has the split to compare |
| `place.fetchPlaceContents.page1`, `.page2` | one page of a 20k-child place | under 50 (the existing assertion in `DrilldownIndexTests`); Python saw 0.9 ms |
| `place.fetchPlaceContents.twoTrackedPaths` | the group-by path | expect tens to hundreds of ms; Python saw 210 ms on 21k |
| `place.fetchPlaceChanges.1day`, `.7days`, `.beforeDetail` | place page change list with 30 days of detail (20 children per 30-minute bucket), then when the detail does not cover the span | should now be within a few ms of `fetchPlaceContents.page1` plus the detail query (low tens of ms); before the fix this carried the 344 ms-class read of all 20k children. `beforeDetail` skips the delta query but still sums |
| `place.fetchJournalDetailTotals.7days` | the per-full-scan residual read | tens of ms; the synthetic worst case in Python was 625 ms for a day on a 2.3M-row table |
| `place.pruneJournal.30d` | one prune after `optimizeQueryPlanner` | well under 100 ms; if it is far above that, the detail prune is scanning (see findings) |
| `watcher.burst200.singleFileEvents` and `.perEvent` | 200 `replaceWorkingSetFile` calls, each with place-child, top-entry and detail writes | per event should be about the existing `fileDelta` bound (under 5 ms); a burst of 200 under 1 s |
| `watcher.subtree1k` | `replaceWorkingSetSubtree` of 1,000 files | under 100 ms (existing `subtreeDelta1k` bound) |
| `scan.addEntriesWithWorkingSet.10k`, `.10k.again`, `scan.rebuildDrilldownIndex.20k` | one scan persistence batch (new rows, then the same rows again), then the index rebuild | the app writes 10,000 per batch; use the first-versus-second to see insert versus conflict-update cost |
| `startup.initialize.emptyDatabase` | opening a new DB and running v1 to v26 | tens of ms |
| `real.startup.initialize` | opening the real snapshot copy (runs v26, a table create) | tens of ms; the v26 step only creates a table, so the full 2.7 GB DB should open about as fast (try it with `PRUNR_REPLAY_DB` pointing at a full copy) |
| `real.startup.optimizeQueryPlanner` | `ANALYZE`/`optimize` on the copy | seconds at most on the slim file; the full 2.7 GB file will be far longer, which is the reason it is scheduled in the background |
| `real.feed.changeFeed`, `real.feed.sqlSlots` | the real feed | Python read of the slots was 45 ms; `changeFeed` should be about 100 to 300 ms |
| `real.places.contentsAllRows`, `real.places.changesAllRows` and their `.slowestRow` | every row's place page, as the replay harness does | `contents` per place about 1 ms; `changes` per place should be within a few ms of `contents` after the fix |
| `real.biggestPlace.fetchPlaceContents`, `.fetchPlaceChanges` | the 21k-child `~/Library/Preferences` place | contents about 1 ms; changes about 10 to 15 ms after the fix (SQL sum 10 ms in Python, was 344 ms before) |

Numbers in the right-hand column are expectations from the Python runs and the existing assertions, not Swift measurements. Treat the first Mac run as the baseline and paste it here.
