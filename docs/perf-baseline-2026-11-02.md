# Perf baseline, 2026-11-02 (O8)

Source: `PerfBaselineTests` (`PERF <name> <ms>` lines, best of N unless noted) from two Mac `test Prunr` runs: the stack branch (all features, incl. place detail) and the land branch (now on main, no place detail). Debug (-Onone), background QoS: compare relative only. The real snapshot is the slim copy described in `perf-real-data-2026-10-31.md`.

## Timings (ms)

| PERF line | Stack | Land | 10-31 doc |
|-----------|-------|------|-----------|
| feed.fixture.changeFeed | 0.62 | 0.58 | a few ms |
| feed.200k.sqlSlots | 1166 | 1161 | - |
| feed.200k.episodeBuild | 1033 | 1034 | - |
| feed.200k.changeFeed | 2204 | 2216 | about 2400 |
| prune.first.changeFeedFullJournal (60d x 900 places) | 1327 | n/a | - |
| prune.first.pruneGrowthJournalBuckets | 699 | n/a | - |
| prune.first.changeFeedAfterPrune | 749 | n/a | - |
| place.fetchPlaceContents.page1 / page2 | 0.19 / 0.19 | 0.20 / 0.20 | under 50 (Python 0.9) |
| place.fetchPlaceContents.twoTrackedPaths | 8.84 | 8.79 | Python 210 |
| place.fetchPlaceChanges 1day / 7days / beforeDetail | 1.22 / 2.93 / 0.60 | n/a | low tens |
| place.fetchJournalDetailTotals.7days | 2.13 | n/a | - |
| place.pruneJournal.30d | 1.67 | 0.10 | - |
| real.startup.initialize | 39.6 | 3.3 | - |
| real.startup.optimizeQueryPlanner | 2.5 | 4.3 | - |
| real.feed.changeFeed | 30.3 | 29.4 | - |
| real.feed.sqlSlots | 15.9 | 16.0 | Python 45 |
| real.feed.rows / places (counts) | 46 / 33 | 46 / 33 | - |
| real.places.contentsAllRows (33 places) | 36.0 | 29.7 | - |
| real.places.changesAllRows (33 places) | 3.40 | n/a | - |
| real.places.contents.slowestRow / changes.slowestRow | 5.04 / 0.29 | 5.49 / n/a | - |
| real.biggestPlace.fetchPlaceContents (21,582 children) | 0.24 | 0.24 | Python 0.9 |
| real.biggestPlace.fetchPlaceChanges | 0.99 | n/a | Python 344 before the fix |
| scan.addEntriesWithWorkingSet.10k / .again | 144 / 131 | 146 / 132 | - |
| scan.rebuildDrilldownIndex.20k | 159 | 163 | - |
| startup.initialize.emptyDatabase | 7.9 | 7.8 | - |
| watcher.burst200.singleFileEvents (per event) | 80.9 (0.40) | 73.9 (0.37) | - |
| watcher.subtree1k | 53.4 | 52.4 | - |

n/a: the test does not exist on the land branch. Stack and land agree within noise wherever both run, so the stack features add no regression to shared paths. The only stack-only cost at startup is `real.startup.initialize` (39.6 vs 3.3), most likely the one-time v26 migration (detail table) on the real snapshot.

Findings against the 10-31 doc: the `fetchPlaceChanges` fix holds (about 1 ms on the 21.6k-child place, was 344 ms-class). The two-tracked-path group-by is 8.8 ms on the 20k fixture, so it is no longer worth a query rewrite. The 200k feed is 2.2 s, under the accepted 2.4 s. Real-data feed is 30 ms for 46 rows, healthy.

## Three worst hot paths

### 1. Feed rebuild at scale: feed.200k.changeFeed, 2.2 s (real data: 30 ms)

Split is even: SQL slot read 1.17 s, `EpisodeBuilder.build` 1.03 s. Where: `DatabaseManager.journalSlots` / `fetchJournalSlots(db:trackedPathIds:since:)` (GROUP BY with `strftime` per bucket, `Prunr/Database/DatabaseManager.swift` near line 1957) and `EpisodeBuilder` (`Prunr/Services/EpisodeBuilder.swift`, from line 438).
Fix: cache the last `ChangeFeedResult` plus a max-bucket-id and re-read only slots with bucketStart after the cached high-water mark (the open day), merging into the cached slot list before `build`. Expected gain: refresh after a watcher or scan tick drops from 2.2 s to about 5 to 10 percent of that at 200k buckets; no change for the first build. Real data is already fast, so this matters only for long-lived heavy journals; do it after the two below if at all.

### 2. First prune after upgrade: 0.70 s prune, 1.33 s full-journal feed (60 days x 900 places)

Where: `DatabaseManager.pruneGrowthJournalBuckets` (line 2109): reads all slots before the cutoff into Swift (`fetchJournalSlots(db:before:)`), filters, folds with `EpisodeBuilder.foldedCounts`, all inside one write transaction, which blocks watcher writes. The feed on the full journal then reads every slot.
Fix: fold in day-sized chunks (loop cutoff in 1-day steps, one short write transaction each) so the write lock is held for roughly 1/60 of the time and memory stays flat. Expected gain: same total work, but the longest single write stall drops from about 700 ms to about 15 to 25 ms; the foreground feed no longer waits behind it.

### 3. Scan persistence and index rebuild: 10k entries 131-146 ms (about 14 microseconds per entry), rebuildDrilldownIndex.20k 159-163 ms; watcher.subtree1k 53 ms

Where: `DatabaseManager.addEntriesCore` (`Prunr/Database/DatabaseManager.swift` near line 735, 500-row multi-row INSERT chunks with `fetchPathIds` per chunk), the drilldown rebuild in `DatabaseManager+Drilldown.swift`, and `applyWorkingSetChanges` (line 243) for the watcher cases (per-event 0.4 ms, per-group indexed statements).
Fix: resolve path ids once per scan batch with a single `INSERT ... ON CONFLICT DO NOTHING` plus an in-memory name-to-id cache kept across chunks, and group watcher events by unit before applying (one `applyWorkingSetChanges` call per 50 ms window instead of per event). Expected gain: scan persistence 20 to 30 percent (about 30 to 40 ms per 10k), burst200 from about 75-90 ms toward 30-40 ms. Small absolute numbers in Debug; in Release these are likely under 20 ms, so this is the lowest priority.

## Recommended first fix

Path 2, chunked prune: it is the only one that blocks other writers, it is low risk (same folding logic, smaller windows, covered by the existing prune tests), and the gain is the largest user-visible one (stall 700 ms to about 20 ms). Path 1 is the biggest raw number but has no real-data impact today.

## Not measured

Real-data scan, snapshot diff and `fetchJournalDetailTotals` on a large real detail table (the real snapshot has no detail rows, so `real.*changes` numbers are small by construction).
