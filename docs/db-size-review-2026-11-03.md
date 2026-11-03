# DB size and retention review (O37, 2026-11-03)

Analysis only, from code at 723d4cf. Facts are from one real 687 MB DB after v27. Byte figures are model estimates until the REALDB `size.bytes.*` lines (dbstat) come back.

## Short answers

1. **Retention.** Snapshot rows live for `categoryHistoryRetentionDays` (default 30, never below 30) and at most 500 per tracked path; the newest complete snapshot per path is always kept. `snapshotEntry` rows are kept only for the 2 newest complete snapshots per path (`maxSnapshotEntryPayloadsPerPath = 2`); older snapshots keep their row plus `categorySnapshot` totals and lose their entries. 14 snapshots hold 8.6M entries because only 2 of them hold entries, and each is a full copy (about 4.3M rows, same as the 4.4M working set). They are not sparse deltas: `ScanService` writes every scanned path into `snapshotEntry` on each full scan. Growth over months is bounded: entries stay at 2 payloads, snapshot rows at about 30 to 500, journal at 30 days.
2. **paths GC.** Yes. `cleanupOrphanedPaths` deletes paths with no `snapshotEntry` and no `workingSetEntry` reference, after each auto-cleanup (post scan, deferred, startup, scope change). Orphan share is at most 1.3 percent right now: `workingSetEntry` already references 4,405,167 of 4,462,509 paths, so at most 57,342 can be orphans. The query is below.
3. **VACUUM.** No `auto_vacuum` or `incremental_vacuum` anywhere (default NONE, never set, and cannot be changed without a full VACUUM). Full `VACUUM` runs only when cleanup deleted something, freelist is at least 18 percent of pages and at least 96 MB, and 12 hours passed since the last one. Without it, deletes leave the file the same size and the free pages are reused by the next writes.
4. **Bytes per row.** See table. `workingSetEntry` is the heaviest per row because of the 36-char `trackedPathId` UUID string, stored in the row and in two indexes.
5. **6-month projection.** Roughly flat: about 690 MB at the same file count, 750 to 850 MB if the file count grows 10 to 25 percent. Details at the end.

## Findings ranked by impact

### 1. A third full payload is written every scan, then freed; file high-water is about 3 payloads
`ScanService` inserts the new snapshot's 4.4M entries (plus the working set) before cleanup runs, so for a while 3 payloads exist, then the oldest is deleted. The freed pages (about one payload, 20 to 25 percent of the file by the model) are reused by the next scan. The file never shrinks below the 3-payload peak unless VACUUM runs.
- Fix option: keep 1 payload per path (`maxSnapshotEntryPayloadsPerPath = 1`) and delete the older payload before the new scan writes, or skip `snapshotEntry` for the new scan and diff against the working set. Saves about 1 payload (roughly 150 to 250 MB on this DB).
- Risk: the 2-payload rule exists "so historical comparison can still compute deltas" (`fetchDeltas` uses `INDEXED BY idx_snapshotEntry_snapshotId_pathId`). Needs a check of exactly which comparisons need the older payload. Touches scan/storage logic, Merlin's call.

### 2. VACUUM thrash and transient disk use
After every daily cleanup the freelist is probably above the 18 percent and 96 MB bar, so VACUUM rewrites the whole 687 MB, then the next scan regrows it. In WAL mode a VACUUM can need about one DB size of temp file plus up to one DB size of WAL, so peak disk is about 2 to 3x the DB (about 1.5 to 2 GB), on a user's system disk.
- Fix option: raise the bar (for example freelist at least 40 percent or 7 days between vacuums), or set `auto_vacuum = INCREMENTAL` via one VACUUM and call `PRAGMA incremental_vacuum(n)` after cleanup. Best combined with finding 1, which removes most of the freelist.
- Risk: raising the bar leaves a larger file on disk. Incremental needs a one-time full VACUUM migration (the same transient 2 to 3x peak, once) and does not stop regrow churn.

### 3. Redundant indexes on the two big tables, about 10 to 15 percent of the file
- `idx_workingSetEntry_trackedPath (trackedPathId)` is a strict prefix of the unique `idx_workingSetEntry_trackedPath_path (trackedPathId, pathId)`. It costs about 46 B per row, about 200 MB by the model on 4.4M rows (the UUID string is stored again).
- `idx_snapshotEntry_snapshotId (snapshotId)` is a prefix of `idx_snapshotEntry_snapshotId_pathId`. It costs about 11 B per row, about 95 MB by the model on 8.6M rows. Queries use the composite by name; no query hints the single-column index.
- Fix option: new migration dropping both, then VACUUM. Planner serves prefix lookups from the composite.
- Risk: schema change (Merlin's call). Slightly more pages scanned for `trackedPathId`-only counts. Verify with `EXPLAIN QUERY PLAN` on `WHERE trackedPathId = ?` and `WHERE snapshotId = ?` queries.

### 4. `workingSetEntry` stores the UUID string per row
36 bytes of `trackedPathId` TEXT in the row, in the unique index and (until finding 3) in a second index, for 4.4M rows: about 110 to 150 MB by the model. The `workingSetPlaceChild`, `workingSetTopEntry` and `workingSetGroupTotal` tables repeat it too, but they are small (51k, 26k, 1k rows).
- Fix option: map `trackedPathId` to a small integer key.
- Risk: large schema and query rewrite across the working set and drilldown code, high risk for a gain that mostly overlaps with finding 3. Not recommended unless the DB must shrink further after 1 to 3.

### 5. `paths` plus `pathClassification` are one row per distinct path ever seen, kept while any entry references it
`paths` stores each path twice (table and the NOCASE unique index), about 2L + 18 B per row (L = average path bytes). Orphans are collected, so this is not a leak; it scales with file count. `pathClassification` adds about 46 B per row (including its `(category, subcategory, pathId)` index) for all 4.46M rows, although classification is a pure function of the path and is read only for working-set paths.
- Fix option: none needed now. If size matters later, store classification only for working-set paths (cascade-delete already handles removal).
- Risk: classification rebuild logic and `pathClassification` joins in the drilldown code.

### 6. Orphan GC and abandoned-snapshot cleanup gaps (small)
- Orphan paths: at most 57k rows (1.3 percent), about 6 to 10 MB. Not worth work. `cleanupOrphanedPaths` ignores `workingSetTopEntry`, but that table has `ON DELETE CASCADE`, so it is correct.
- Entries of in-flight or abandoned (`lifecycle != complete`) snapshots are excluded from the "keep 2" rule; `cleanupAbandonedSnapshots` runs only at startup (15 min grace). A killed scan leaves a partial payload until the next launch.
- Fix option: also run `cleanupAbandonedSnapshots` at the start of `performAutoCleanup`.
- Risk: it must never delete a live scan; the grace window handles that, but `MenuBarManager` busy checks should gate it.

### 7. Journal and category history are negligible
`growthJournalBucket` 3,249 rows, `growthJournalDetail` and `growthJournalCheckpoint` empty, `categorySnapshot` small. Bounded by the 30-day clamp and 500 snapshots per path. No action.

## Bytes per row estimate (SQLite record format, about 90 percent page fill)

| table (rows) | row | indexes | total per row | model size |
|---|---|---|---|---|
| paths (4.46M) | L + 9 | unique NOCASE path: L + 9 | 2L + 18 plus tree overhead | at L=50: about 530 MB |
| snapshotEntry (8.6M) | 19 | snapshotId 11, (snapshotId,pathId) 14, pathId 12 | about 56 | about 480 MB |
| workingSetEntry (4.4M) | about 64 (UUID 36 plus updatedAt 8) | unique (UUID,pathId) 50, UUID 46, pathId 12 | about 170 | about 750 MB |
| pathClassification (4.46M) | about 22 | (category,subcategory,pathId) about 24 | about 46 | about 205 MB |
| workingSetPlaceChild (51k), TopEntry (26k), GroupTotal (1k), journal (3k) | | | | under 15 MB together |

Dominating indexes by model: `workingSetEntry` unique and trackedPath indexes (about 96 B per row together), `snapshotEntry` three indexes (37 B per row against a 19 B row), `paths` unique path index (L + 9).

Caveat: this model sums to about 2 GB, three times the observed 687 MB. Either the average path is short and record sizes are smaller than modelled, or the 687 MB figure and the counts are not from the same moment. Treat the shares (workingSetEntry about 37 percent, paths about 26 percent, snapshotEntry about 24 percent, pathClassification about 10 percent) as the useful part and scale to 687 MB. The `size.bytes.*` dbstat lines below replace this table with measured bytes. If `dbstat` is not compiled into the Mac SQLite, those lines are absent and only the other counts appear.

## 6-month projection

Cadence from code:
- Full scans (the only thing that writes snapshots): `automaticFullScanIntervalHours` presets are 24, 48, 72, 168, 336; default 24, adaptively set after the first scan to 24 (under 5 min), 48 (under 20 min), 72 (under 1 h) or 168 h. Hourly full scans are not possible. Hourly activity is the FSEvents watcher, which edits `workingSetEntry` in place and writes journal buckets; it adds no snapshots.
- Daily scans for 183 days: 183 snapshot rows created, pruned to about 30 (30-day cutoff) and never above 500. Entries stay at 2 payloads. `categorySnapshot` and journal: tens of thousands of rows at most.
- Hourly scans (hypothetical, if the interval were lowered): 500 snapshot rows per path cap, still 2 payloads; size unchanged, only write churn and VACUUM frequency go up.

Result for this user:
- Steady state is about the current size, 690 MB, plus the growth of the file population: size scales with distinct file count (paths, workingSetEntry, 2 snapshot payloads, classification), so +10 to 25 percent files means about 750 to 850 MB.
- Transient: WAL during a full scan (several hundred MB before TRUNCATE) and about 2 to 3x peak disk during VACUUM, unchanged from today.
- Path churn does not accumulate: orphan paths are removed after each cleanup, and `paths.id` keeps growing (AUTOINCREMENT) but costs nothing.
- Nothing grows without bound; the real risk is the per-scan churn and VACUUM cost, not 6-month size.

## Count queries added to the real-DB test (all counts, no paths or names)

Emitted as `REALDB size.*` lines at the end of `testRealDatabaseCopyMigratesPrunesAndBuildsFeed` (`emitSizeCounts`):

- `size.paths.orphan`: paths with no snapshotEntry and no workingSetEntry reference.
- `size.paths.onlySnapshotEntry`, `size.paths.onlyWorkingSet`, `size.paths.inBoth`: reference mix.
- `size.paths.sumPathBytes`, `size.paths.maxPathBytes`: gives L (sum divided by `paths.after`).
- `size.snapshotEntry.distinctPathIds`, `size.snapshotEntry.snapshotsWithEntries`.
- `size.snapshotEntry.rank0..N`: entries per snapshot, newest first (expect two large values, rest absent).
- `size.snapshot.total`, `.complete`, `.trackedPaths`, `.oldestAgeDays`, `.newestAgeHours`.
- `size.workingSetEntry.trackedPaths`, `size.pathClassification.withoutPath`.
- `size.pragma.pageCount`, `pageSize`, `freelistCount`, `autoVacuum`: freelist share and vacuum mode.
- `size.bytes.<table or index name>`: measured bytes per table and index from `dbstat` (best effort, absent if `dbstat` is unavailable).

Plain SQL for the main orphan check:

```sql
SELECT COUNT(*) FROM paths p
WHERE NOT EXISTS (SELECT 1 FROM snapshotEntry se WHERE se.pathId = p.id)
  AND NOT EXISTS (SELECT 1 FROM workingSetEntry w WHERE w.pathId = p.id);
```

What to read from the result: `freelistCount * pageSize` over file size tells whether VACUUM thrash is real (finding 2); `size.bytes.idx_workingSetEntry_trackedPath` and `idx_snapshotEntry_snapshotId` confirm finding 3; `size.snapshotEntry.rank0` and `rank1` against `workingSetEntry.after` confirm full-copy payloads (finding 1).

## Measured on the real DB (Mac run 9324eed, dbstat)

The file is 3.47 GB (848,228 pages of 4 KB), not 687 MB. 225 MB of it is free pages (54,945).

| Area | Table | Indexes | Total | Share |
|---|---|---|---|---|
| paths (full path text, stored twice) | 695 MB | 714 MB (unique autoindex) | 1.41 GB | 41% |
| workingSetEntry | 345 MB | 546 MB (3 indexes) | 891 MB | 26% |
| snapshotEntry | 160 MB | 434 MB (3 indexes) | 594 MB | 17% |
| pathClassification | 151 MB | 171 MB | 322 MB | 9% |
| everything else | | | under 30 MB | 1% |

Findings, corrected:
1. Path text dominates. 4.46M paths average 140 bytes each (625 MB of raw text), and the unique index stores it a second time. Storing parent id + name instead of the full path would save most of the 1.41 GB. That is a schema and storage-logic redesign, Merlin's call.
2. The 2 redundant prefix indexes (O32a, v28) are 343 MB: idx_workingSetEntry_trackedPath 235 MB + idx_snapshotEntry_snapshotId 109 MB. That is 10% of the file, a real disk win even though it is no faster.
3. There are no orphans. 57,342 paths are referenced only by the older snapshot and get freed when it is pruned.
4. Two snapshots hold entries (4.41M + 4.19M rows); the 11 others are empty, as designed.
5. auto_vacuum is off, so the free pages stay in the file until a full VACUUM.
