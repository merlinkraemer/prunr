# Path store and DB size design (O38, 2026-11-03)

Design only, no app code. Code read at `d4b06ab`. Ground truth is the "Measured on the real DB" section of `docs/db-size-review-2026-11-03.md` (Mac run 9324eed, dbstat). Every other byte figure here is an estimate from the SQLite record format, calibrated against those measurements (see "Calibration"). Schema and scan/storage logic are Merlin's call (AGENTS.md "must ask"); nothing here is approved work.

## Summary

- Today: 3.47 GB file. After v28 (on this branch) live data is about 2.90 GB plus 568 MB of free pages that no VACUUM will ever reclaim under the current thresholds.
- The options asked for (a to d) together bring this user to about **1.2 GB live** (about 1.45 GB peak during a full scan). They do **not** reach "well under 1 GB" on their own.
- Under 1 GB needs one more step that changes scan semantics: either drop the snapshot payload entirely (d2, about 0.98 GB) or stop storing tiny files one row each (e, product call, size unknown until measured).
- Recommended order, most bytes per unit of risk first: measure (S0), one-time VACUUM into `auto_vacuum = INCREMENTAL` (S1, -568 MB), keep 1 snapshot payload (S2, -243 MB live and peak), slim `workingSetEntry` (S3, about -500 MB), paths as directory + name (S4, about -770 MB), integer classification codes (S5, about -185 MB). Then decide on S6 (d2 or e).

## Baseline numbers used

From the measured table, adjusted for v28 (drops `idx_workingSetEntry_trackedPath` 235 MB and `idx_snapshotEntry_snapshotId` 109 MB):

| Area | Rows | Measured | After v28 (live) |
|---|---|---|---|
| paths (table 695 + unique autoindex 714) | 4.46M | 1,409 MB | 1,409 MB |
| workingSetEntry (table 345 + 3 indexes 546) | 4.4M | 891 MB | 656 MB |
| snapshotEntry (table 160 + 3 indexes 434), 2 payloads | 8.6M | 594 MB | 485 MB (about 243 MB per payload) |
| pathClassification (151 + 171) | 4.46M | 322 MB | 322 MB |
| everything else | | under 30 MB | about 30 MB |
| free pages | | 225 MB | 568 MB (16.4% of 848,228 pages) |
| file | | 3.47 GB | 3.47 GB |

### Calibration

The measured bytes match the record-format model at about 0.9 page fill, so the estimates below use 0.9:
- `paths` table: 625 MB of text + 4.46M x about 10 B overhead = 670 MB model vs 695 measured.
- `paths` autoindex: same text + about 11 B per entry = 674 MB model vs 714 measured.
- `workingSetEntry` table: 345 MB / 4.4M = 78 B per row (UUID text 36 B + `updatedAt` as GRDB date text 23 B + ids, header, cell pointer).
- `idx_workingSetEntry_trackedPath`: 53 B per entry against a 47 B model entry.
- `snapshotEntry`: table 18.6 B per row, the two remaining indexes 37.8 B per row together.

Unknowns that move the big estimates (S0 measures them): number of distinct directories D (assumed 0.3M to 1.0M, central 0.6M) and average file-name bytes Ln (assumed 24 to 40, central 32; the average full path is 140 B).

## 1. Current model

### Schema

- `paths(id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE ON CONFLICT IGNORE COLLATE NOCASE)` (v10, `DatabaseManager.swift:252`). One row per file path. The UNIQUE constraint is the 714 MB `sqlite_autoindex_paths_1`, which stores the full path a second time. NOCASE folds ASCII only.
- Referencing tables, all by `pathId`: `snapshotEntry` (v7, `:189`), `workingSetEntry` (v16, `:378`), `pathClassification` (v17, `:426`, `pathId` is the rowid), `workingSetTopEntry` (v23, `DatabaseManager+Drilldown.swift:99`). All have `ON DELETE CASCADE`.
- `workingSetEntry(id, trackedPathId TEXT, pathId, sizeBytes, updatedAt)` with unique `(trackedPathId, pathId)` and `(pathId)` after v28.
- `snapshotEntry(id, snapshotId, pathId, sizeBytes)` with `(snapshotId, pathId)` and `(pathId)` after v28.
- Path text is also stored, small, in `workingSetPlaceChild(unitRoot, name)`, `growthJournal*` unit keys and `workingSetRefreshStaging(sessionId, path)` (transient, empty between refreshes).

### Writes of path text

| # | Where | What |
|---|---|---|
| W1 | `DatabaseManager.swift:2685-2693` `fetchPathIds` | full scan: `INSERT OR IGNORE INTO paths (path) VALUES (?),...` in chunks of 500 |
| W2 | `DatabaseManager.swift:2702-2707` `fetchPathIds` | then `SELECT id, path FROM paths WHERE path IN (...)` (NOCASE lookup), keyed in Swift by lowercased path |
| W3 | `DatabaseManager.swift:1465-1472` `replaceWorkingSetFileRows` | watcher single file: `INSERT OR IGNORE` + `SELECT id FROM paths WHERE path = ?` |
| W4 | `DatabaseManager.swift:1952-1957` `replaceWorkingSetSubtree` | watcher subtree: `INSERT OR IGNORE INTO paths SELECT path FROM workingSetRefreshStaging` |
| W5 | `DatabaseManager.swift:2658-2669` `getOrCreatePathId` | test/debug `addEntry` |
| W6 | `DatabaseCleanupService.swift:793` `cleanupOrphanedPaths` | `DELETE FROM paths WHERE NOT EXISTS snapshotEntry AND NOT EXISTS workingSetEntry` |

### Reads that use path text

"Hot" means it runs on every watcher event or every panel open, not only once per full scan.

| # | file:line | Function | Shape | Index used today | Hot |
|---|---|---|---|---|---|
| Q1 | `DatabaseManager.swift:1599-1607` | `removeWorkingSetFileRowsIfPresent` | exact `p.path = ?` + WSE join | path autoindex | yes (watcher) |
| Q2 | `DatabaseManager.swift:1637-1656` | `removeWorkingSetSubtreeRows` | `p.path = ? OR (p.path >= ? AND p.path < ?)` subtree range | path autoindex range | yes |
| Q3 | `DatabaseManager.swift:1672-1684` | same | `DELETE ... pathId IN (subtree range)` | path autoindex range | yes |
| Q4 | `DatabaseManager.swift:1963-2020` | `replaceWorkingSetSubtree` | subtree range (old rows) + `JOIN paths p ON p.path = s.path` (staging) | autoindex range + exact | yes |
| Q5 | `DatabaseManager.swift:2040-2052` | same | classification upsert, `JOIN paths ON p.path = s.path` | autoindex exact | yes |
| Q6 | `DatabaseManager.swift:2054-2071` | same | `DELETE ... pathId IN (subtree range)` | autoindex range | yes |
| Q7 | `DatabaseManager.swift:2073-2086` | same | WSE upsert, `JOIN paths ON p.path = s.path` | autoindex exact | yes |
| Q8 | `DatabaseManager.swift:1709-1718` | `fetchWorkingSetSizes` (RecentChangeService:214) | `p.path IN (...)` | autoindex exact | yes |
| Q9 | `DatabaseManager.swift:1746-1759` | `fetchWorkingSetEntries` (RecentChangeService:234, denied carry-forward) | subtree range, keyset `p.path > ?`, `ORDER BY p.path` | autoindex range, ordered | sometimes |
| Q10 | `DatabaseManager.swift:939-961` | `fetchEntries(for:atOrBelow:)` (ScanService:434 denied carry-forward) | same as Q9 on snapshotEntry | autoindex range, ordered | per scan |
| Q11 | `DatabaseManager+Drilldown.swift:1238-1246` | `placeChildrenFromWorkingSet` | `p.path >= ? AND p.path < ?` | autoindex range | panel |
| Q12 | `DatabaseManager+Drilldown.swift:527` | `replaceDrilldownIndex` | `SELECT id FROM paths WHERE path = ?` per top file without id | autoindex exact | per scan |
| Q13 | `DatabaseManager+Drilldown.swift:722-733` | `fetchGroupFiles` owner groups | `prunr_owner_group(p.path) IN (...)`, `ORDER BY size DESC, p.path` | none on path (filter via pc category) | panel |
| Q14 | `DatabaseManager.swift:2792-2823` | `calculateDeltas` | by id, returns `p.path` | none needed | per scan |
| Q15 | by id, path only returned | `fetchEntries` `:914`, `fetchTopEntries` `:1002`, `fetchEntriesPaginated*` `:1025,1049,1072,1082`, `drilldownIndexBuilder` Drilldown `:562`, `fetchGroupFiles` subcategory Drilldown `:738`, `fetchDrilldownTopFiles` Drilldown `:852`, `fetchDrilldownCategoryFromWorkingSet` Drilldown `:1269` | `JOIN paths p ON p.id = x.pathId` | rowid | mixed |
| Q16 | `DatabaseManager+Drilldown.swift:206-215` | v25 migration `reclassifyOwnerUnitPaths` | `p.path LIKE '%...%'` (full scan) | none | migration only |
| Q17 | `DatabaseManager.swift:449` | v17 migration | `SELECT id, path FROM paths` | none | migration only |
| Q18 | `E2ETestCommand.swift:284` | E2E check | exact path | autoindex | debug |

There are no `LIKE 'prefix%'` scans in app code. Every prefix query is a NOCASE range `[root/, root0)` built by `pathPrefixUpperBound` (`DatabaseManager.swift:2598`), and it only works because the autoindex is ordered by full path. That is the constraint that decides the options below. Tests: 20 SQL statements in 6 test files touch `paths` directly.

### What the snapshot payloads are used for

- `BaselineService.swift:164` diffs the previous complete snapshot against the new one right after each full scan (journal residual). Needs both payloads at scan end.
- `ScanService.swift:434` carries denied subtrees forward from the previous snapshot. Needs the previous payload during the scan.
- `BaselineService.swift:451` `comparableBaselineSnapshotId` only uses **entry counts** of older snapshots; `loadInventoryWithTrends` hides trends when no comparable baseline exists.
- `getGrowthList` (`:298`) and `drillDown` (`:351`) diff older snapshots, but have no app callers (only `BaselineServiceRegressionTests.swift:969`). `MainViewModel` (the other `calculateDeltas` user) is not referenced outside its own file. `StressScanCommand`/`E2ETestCommand` diff right after a scan.
- Full scans write the snapshot with `alsoWriteWorkingSet: false` (`BaselineService.swift:118`) and then `rebuildWorkingSet` copies the payload into `workingSetEntry` (`DatabaseManager.swift:1259`). So right after a scan the newest payload is a copy of the working set.
- Cleanup runs after the scan: during the scan 3 payloads exist (2 kept + the new one), so the file's high-water mark includes a third payload. The 225 MB of free pages measured before v28 is mostly that third payload.

## 2. Options

All savings are against the after-v28 column. "Peak" means the file high-water mark during a full scan, which is what the file size returns to without a VACUUM.

### (a) Parent id + name tree

`paths(id, parentId, name COLLATE NOCASE)`, unique `(parentId, name)`, one row per file and per directory. Full path rebuilt by recursive CTE or an in-memory cache.

- Bytes: about (Ln + 16) B per row + (Ln + 16) B per index entry at 0.9 fill, for 4.46M + D rows. Central 560 MB (range 440 to 700). **Saves about 850 MB (700 to 970).**
- Queries: every exact lookup (Q1, Q4-Q8, Q12, W1-W4) walks components (8 to 15 index probes per path instead of 1) or needs a cache. Subtree range (Q2-Q4, Q6, Q9-Q11) becomes a recursive CTE over `parentId`. Every `p.path` output (Q13-Q15) needs reconstruction: a recursive CTE per row or a Swift cache of directory paths. `ORDER BY p.path` + keyset paging (Q9, Q10) has no index order any more.
- Migration: split 4.46M paths, build directory rows, keep file ids. 1 to 3 min (estimate), WAL about 0.6 to 0.8 GB, file grows by the new tables until a VACUUM or incremental vacuum.
- Risk: high. Biggest rewrite, slowest hot-path lookups, recursive CTEs in the watcher path. Saves only about 90 MB more than (a2).

### (a2) Directory + name, two levels (recommended form of a)

`dirs(id, path TEXT UNIQUE COLLATE NOCASE)` storing each directory once **with a trailing slash** ("/Users/x/Library/"), and `paths(id, dirId, name COLLATE NOCASE)` with unique `(dirId, name)`. Full path = `d.path || p.name`. File ids are kept as they are, so no referencing table changes.

- Bytes: files about 475 MB (4.46M x (Ln+16) x 2 / 0.9 at Ln = 32), dirs about 160 MB (D = 0.6M, dir path about 105 B, stored twice). Central 635 MB (range 475 to 810). **Saves about 770 MB (600 to 930).**
- Queries:
  - Exact lookup (Q1, Q4, Q5, Q7, Q8, Q12, W1-W4): split in Swift into dir and name, two index probes, `JOIN dirs d ON d.path = ? JOIN paths p ON p.dirId = d.id AND p.name = ?`. Staging joins (Q4, Q5, Q7) need staging rows split too (add `dir`, `name` columns to `workingSetRefreshStaging`, transient table).
  - Subtree range (Q2, Q3, Q6, Q11): the existing range works unchanged on `dirs.path` (`d.path >= 'root/' AND d.path < 'root0'`), then joins files by `dirId`. The exact-root case (root is a file) becomes a dir+name probe. Cost: one dir range scan (small) + `dirId` index probes. Likely as fast as today or faster.
  - Ordered paging (Q9, Q10): `ORDER BY p.path` becomes `ORDER BY d.path, p.name` with a row-value keyset `(d.path, p.name) > (?, ?)`. Order differs from full-path order in edge cases ('/' sorts after '.'), which the callers do not care about (they only need a stable keyset). Caller passes the last row's dir and name instead of `afterPath`.
  - Output-only joins (Q13-Q15): a view `pathText(id, path) AS SELECT p.id, d.path || p.name FROM paths p JOIN dirs d ON d.id = p.dirId` lets these queries change only the join target. `ORDER BY ..., p.path` tie-breaks (Q13, Q15) still work, unindexed, on small result sets.
  - Q16, Q17 run before the new migration on fresh installs; they keep working on the old schema.
  - GC: `cleanupOrphanedPaths` also deletes `dirs` with no files (anti-join over D rows, cheap).
- Migration: `dirs` from `SELECT DISTINCT rtrim(path, replace(path, '/', ''))` (the standard "everything up to the last slash" trick), new `paths` with explicit old ids, drop old `paths`, rename. Must run with foreign keys off (GRDB default `.deferred`, not `.immediate` like v28), otherwise dropping `paths` cascades into every referencing table. Estimate 1 to 3 min, WAL about 0.7 to 1 GB, file grows by about 0.65 GB before space is returned.
- Risk: medium-high. About 25 SQL statements and 20 test statements change; the hot watcher path changes shape. Mitigation: the pathText view, kept ids, and a checksum test (S4).

### (b) Keep the full path, replace the unique index by an 8-byte hash

`paths(id, path, hash INTEGER)` with an index on `hash`, hash = 64-bit FNV/xxhash of the ASCII-lowercased path (to match NOCASE), lookups `WHERE hash = ? AND path = ?` (collision check).

- Bytes: +9 B per row in the table (+45 MB), hash index about 19 B per entry (about 95 MB at 0.9, up to 120 MB if random inserts fill worse), drop the 714 MB autoindex. **Saves about 550 to 575 MB.**
- Queries: exact lookups (Q1, Q4-Q8, Q12, W1-W4) stay one probe; uniqueness moves to code (`INSERT OR IGNORE` no longer dedups, so W1/W3/W4 need "select by hash, insert if missing"). **Every subtree range query (Q2, Q3, Q4, Q6, Q9, Q10, Q11) loses its index and becomes a full scan of 4.4M working-set rows**, several of them per watcher event. That reintroduces exactly the kind of constant CPU load investigated in bug #2.
- Migration: add column, fill 4.46M hashes (needs a registered SQL function or a Swift loop), drop the constraint (table rebuild, since SQLite cannot drop a UNIQUE constraint in place). 1 to 2 min, WAL about 0.7 GB.
- Risk: not viable alone. It only works combined with a separate ordered directory structure, which is (a2) with extra hash code. Rejected.

### (c) Slim the entry tables (WITHOUT ROWID, small keys, drop unused columns)

c1, `workingSetEntry` (the big one): `workingSetEntry(trackedPathKey INTEGER, pathId INTEGER, sizeBytes INTEGER, PRIMARY KEY (trackedPathKey, pathId)) WITHOUT ROWID` plus index `(pathId)`, with a tiny map table `trackedPathKey(key INTEGER PRIMARY KEY, uuid TEXT UNIQUE)`. Drop `updatedAt`: it is only read as `MAX(updatedAt)` per tracked path (`DatabaseCleanupService.swift:231`, v24 migration `Drilldown.swift:164`, v18 migration `:479`); one timestamp per tracked path (for example on `workingSetIndexState`) covers that.
- Bytes: row about 18 B (88 MB), pathId index about 12 B (59 MB), about 150 MB total. **Saves about 500 MB.**
- Queries: 27 places use `wse.trackedPathId` / `workingSetEntry.trackedPathId`. Reads can keep passing the UUID string by writing `trackedPathKey = (SELECT key FROM trackedPathKey WHERE uuid = ?)` (a constant subquery, evaluated once), so Swift call sites barely change. Inserts (`:816`, `:1279`, `:1493`, `:2075`) need the key. No query gets slower; the unique index and the table become one B-tree.
- Migration: create, `INSERT ... SELECT` 4.4M rows ordered by `(key, pathId)`, drop, rename. Foreign keys off. Estimate 30 to 90 s, WAL about 200 to 300 MB.
- Risk: medium. Mechanical but wide. Keeping the UUID text in the PK instead of an integer key is not worth it: the `(pathId)` secondary index of a WITHOUT ROWID table stores the full PK, so it would grow to about 260 MB.

c2, `snapshotEntry` WITHOUT ROWID with PK `(snapshotId, pathId)` plus `(pathId)`: about 195 MB per payload instead of 243. Saves about 50 MB per payload kept. `fetchEntriesPaginatedUnordered` pages by `se.id` (`:1061`, used by `DatabaseCleanupService.swift:598`) and must page by `pathId` instead. Low priority; moot if d2 lands.

c3, `pathClassification` with integer codes: `category` and `subcategory` as 1-byte integers (Swift enum to code map) instead of text. Row about 13 B, index `(category, subcategory, pathId)` about 14 B: about 135 MB. **Saves about 185 MB.** Every `pc.category = ?` / `pc.subcategory = ?` argument and every read of `pc.category` text changes (drilldown, working-set totals, v-migrations stay as they are). With (a2), the two codes could live directly in the new `paths` row (+2 B per row) and the table disappears: saves about 55 MB more, but makes S4 bigger.

### (d) Stop keeping a second full snapshotEntry payload

d1, keep 1 payload (`maxSnapshotEntryPayloadsPerPath = 1`, `DatabaseCleanupService.swift:24`):
- The code allows it, with one fix: store the entry count on the snapshot row (`snapshot.entryCount`, written at `markSnapshotComplete`, backfilled once from the 2 payloads) and read that in `comparableBaselineSnapshotId`. Without it, the previous snapshot reports 0 entries, no comparable baseline is found, and `loadInventoryWithTrends` drops the trend stories when more than one snapshot exists.
- The scan-end diff and the denied carry-forward still have their previous payload, because cleanup runs after the diff. `getGrowthList`/`drillDown` lose history beyond the last scan; only a test uses them (that test needs adjusting or the functions removing).
- Bytes: **-243 MB live and -243 MB peak** (high-water goes from 3 payloads to 2).
- Migration: one column plus a backfill (`COUNT(*) GROUP BY snapshotId`, seconds). Next cleanup deletes the older payload.
- Risk: low to medium (storage logic, Merlin's call).

d2, no snapshot payload; the working set carries the scan baseline:
- Add `scanSizeBytes` to `workingSetEntry` (the size at the last full scan) and keep watcher-deleted rows as tombstones (current size 0) until the next scan, or put them in a small side table. A full scan writes `pendingSizeBytes` in place, and at the end the diff is `pending` vs `scanSizeBytes` (same meaning as today's previous-vs-new snapshot diff), then commits pending to current and to scan size in one transaction. Denied subtrees keep their old values instead of being copied.
- Bytes: snapshotEntry about 0, working set +about 25 MB. **-485 MB live, about -730 MB peak.**
- Queries: every working-set read must ignore tombstones (or the side-table variant avoids that), the scan write path, `rebuildWorkingSet`, `createSnapshotFromWorkingSet`, carry-forward, abandoned-scan cleanup and the cancel path all change. `snapshot` rows and `categorySnapshot` history stay.
- Risk: high. It rewrites how a full scan publishes ("do not update the live working set until the scan completes", `BaselineService.swift:98`) and the residual journal math. Only worth it if under 1 GB is a hard goal.

### (e) Not asked, but the only other big lever: fewer rows

Every table scales with the number of files (4.46M). Rolling up files below a size threshold into one row per directory would shrink all of the above in proportion, but the drilldown would no longer list those files. Product call. Each 10% of rows removed is worth about 100 to 120 MB once S2 to S5 are in. S0 measures the size distribution so this can be decided on numbers.

### Combined effect (central estimates, file size between scans with incremental vacuum)

| Step | Live | Peak during full scan |
|---|---|---|
| today | 2.90 GB + 0.57 GB free = 3.47 GB file | about 3.5 GB |
| S1 VACUUM + incremental | 2.90 GB | about 3.15 GB |
| S2 keep 1 payload (d1) | 2.66 GB | about 2.9 GB |
| S3 slim workingSetEntry (c1) | 2.16 GB | about 2.4 GB |
| S4 dirs + names (a2) | 1.39 GB | about 1.65 GB |
| S5 classification codes (c3) | 1.20 GB | about 1.45 GB |
| S6a no payload (d2) | about 0.98 GB | about 1.0 GB + WAL |
| S6b small-file rollup (e) | unknown, scales with rows removed | |

The range on S4 alone is plus or minus 160 MB until D and Ln are measured. Plus WAL during scans (several hundred MB before TRUNCATE), unchanged by any option.

## 3. Vacuum policy

Today (`DatabaseCleanupService.swift:29-45, 82-110, 144-153`): `auto_vacuum` is NONE (never set). A full `VACUUM` runs after cleanup only if cleanup deleted rows, the freelist is at least 18% of pages and at least 96 MB, and 12 h passed since the last one. Startup maintenance applies the same test.

What that means for this user:
- v28 frees 343 MB, giving 568 MB free = 16.4% of the file. Below 18%, so no VACUUM.
- It stays stuck there: each full scan first refills free pages with the new payload (freelist drops to about 325 MB), then cleanup frees the older payload (back to about 568 MB). The ratio hovers around 16%, so the 343 MB from v28 is never returned to the disk.
- When a VACUUM does run, it rewrites the whole file: about 1x DB of temp file plus up to 1x DB of WAL, so 5 to 6 GB of transient disk at today's size, on the user's system disk.

Options:
1. Lower the bar (for example 10% or 256 MB absolute). Returns the 568 MB at the next idle window. Keeps the full-rewrite cost and the regrow churn.
2. `auto_vacuum = INCREMENTAL`. Needs one full VACUUM to switch (`PRAGMA auto_vacuum = INCREMENTAL; VACUUM;`). Afterwards `PRAGMA incremental_vacuum(N)` after cleanup moves pages from the end of the file into free slots and truncates, with no temp file and no full rewrite. Cost: pointer-map pages (about 0.1% of the file), extra page moves on each incremental run, more fragmentation over time. It does not lower the high-water mark during a scan; it returns space after cleanup.
3. `auto_vacuum = FULL`: truncates on every commit, makes the per-scan delete of a payload expensive. Not recommended.

Recommendation: do option 2 once (S1), as the very next storage change, so the large frees from S2 to S5 come back through `incremental_vacuum` instead of more full VACUUMs. Run `incremental_vacuum` after `performAutoCleanup` when the freelist is above about 64 MB, and only when the app is idle (same gate as today). Keep the full `VACUUM` for "Compact now" and a rare defragmentation (for example once a month, or when the freelist ratio after incremental runs stays high). Before any full VACUUM, check that free disk space is at least 2x the DB size and skip otherwise. To verify on the Mac: whether pages freed and reallocated inside one migration transaction are reused within that transaction (affects transient file growth in S3/S4), and the exact incremental_vacuum time for about 1.4 GB of moves.

## 4. Recommendation: ordered slices

Each slice is one migration or one logic change, landable and revertable on its own. All are "must ask" (data/schema or scan/storage logic). Acceptance runs on the real-DB copy test (`ReplayHarnessTests.testRealDatabaseCopyMigratesPrunesAndBuildsFeed`, prints `PERF realdb.*` and `REALDB size.*`), via `mac-queue` when the Mac is open.

Test harness changes needed first (part of S0): the copy is made with `backup()`, which keeps free pages, so file size is not a measure of live size. Add `REALDB size.file.vacuumed` (run `VACUUM INTO` a temp file at the end and stat it) and `size.file.bytes` (page_count x page_size). Add a `performAutoCleanup` call after migration so payload policy changes show up. Add `PERF realdb.subtree`, `realdb.lookup` and `realdb.deltas` timings (a subtree refresh dry run under the largest top-level folder, 1,000 exact lookups, one `calculateDeltas` on the two payloads) so query regressions are visible.

**S0, measure (test only, no app code).** New REALDB lines: `size.paths.distinctDirs` (`COUNT(DISTINCT rtrim(path, replace(path, '/', '')))`), `size.paths.sumDirBytes` over distinct dirs, `size.paths.sumNameBytes`, `size.wse.under4k` / `under64k` / `under1m` counts and byte sums, plus the harness lines above.
Acceptance: lines present; the S4 estimate is recomputed from D and Ln before S4 starts. Decide S6 on the size histogram.

**S1, VACUUM into incremental (-568 MB file, 3.47 to about 2.90 GB).** One-time `auto_vacuum = INCREMENTAL` + VACUUM at an idle startup with a free-space check, then `incremental_vacuum` after cleanup.
Acceptance: `size.pragma.autoVacuum` = 2; `size.file.bytes` minus `size.file.vacuumed` under 64 MB after cleanup; `PERF realdb.vacuum` recorded (expect minutes on 3.4 GB; that number decides whether it runs at startup or needs a user-visible "compacting" state).

**S2, keep 1 snapshot payload (d1: -243 MB live, -243 MB peak).** `maxSnapshotEntryPayloadsPerPath = 1`, `snapshot.entryCount` column + backfill, `comparableBaselineSnapshotId` reads the column.
Acceptance: after cleanup `size.snapshotEntry.snapshotsWithEntries` = 1 and `rank1` absent; `size.file.vacuumed` down by at least 200 MB vs S1; `feed.episodes` and `drilldown.groups` unchanged; unit test: trends still attach with 2+ snapshots and one payload.

**S3, slim workingSetEntry (c1: about -500 MB).** WITHOUT ROWID, integer tracked-path key, no `updatedAt`.
Acceptance: `size.bytes.workingSetEntry` + its indexes at most 200 MB; `PERF realdb.migrate.<id>` under 90 s; `drilldown.groups` and `feed.episodes` unchanged; `PERF realdb.drilldownGroups` and `realdb.subtree` not more than 20% slower; `EXPLAIN QUERY PLAN` for Q2/Q6 shows a SEARCH on the primary key, no SCAN.

**S4, paths as directory + name (a2: about -770 MB, range -600 to -930).** New `dirs` table, `paths(id, dirId, name)`, ids kept, `pathText` view for output-only joins, split staging.
Acceptance: `size.bytes` of paths + dirs + their indexes at most 850 MB (tighten from S0 numbers); a checksum line `REALDB paths.checksum` (count plus sum of a hash over the full path text ordered by id) identical before and after the migration; `realdb.subtree` and `realdb.lookup` not more than 20% slower; migration under 3 min; all snapshot/working-set/classification/top-entry row counts unchanged (`*.before` vs `*.after`).

**S5, integer classification codes (c3: about -185 MB).** Or fold the codes into `paths` during S4 (about -240 MB, bigger S4).
Acceptance: `size.bytes.pathClassification` + index at most 150 MB; per-category totals from `workingSetCategoryTotal` identical before and after; `drilldown.groups` unchanged.

**S6, only if under 1 GB is required (decide on S0 data).** Either d2 (about -240 MB more, high risk, rewrites scan publishing) or a small-file rollup (product change). Acceptance defined when chosen.

Expected result after S1 to S5: about 1.2 GB between scans and about 1.45 GB peak for this user, down from 3.47 GB. With S6a about 1.0 GB. Honest bottom line: the path text itself (file names, about 4.46M x 32 B, stored twice for the unique lookup) sets a floor of about 0.5 GB for any per-file design, so getting well under 1 GB needs fewer rows, not just smaller rows.

## Open questions and uncertainty

- D and Ln are assumptions; S4's savings move by plus or minus 160 MB with them.
- The 0.9 fill factor is calibrated on today's tables; tables built by random-order inserts during scans may fill worse (0.7), which would add 10 to 25% to the S3 and S5 targets.
- Migration times are estimates; nothing here has been timed on the Mac. `PERF realdb.migrate.<id>` gives real numbers per slice.
- Whether S3 and S4 should share one migration (one transient disk spike, one VACUUM-free cycle) or stay separate (smaller risk per step). Recommendation: separate, because S1 makes the space return cheap.
- d2 changes the residual journal math; it needs its own design pass before any estimate of effort.

## Measured (O39, Mac run 44f68ab, real DB)

- Live size after VACUUM: 2.76 GB (file 3.47 GB), so one VACUUM frees 712 MB (estimate was 568 MB). VACUUM INTO took 8.5 s.
- 627,866 distinct folders (estimate 0.6M). Average file-name length 29.3 bytes (estimate 32). Folder text 77 MB + name text 131 MB = 208 MB, against 625 MB of full-path text.
- Exact NOCASE lookup: 1,000 in 29 ms.
- calculateDeltas on the two newest snapshots: 4.4 s for 325,973 deltas.
- The subtree timing did not run (the test found no top-level folder); needs a fix in the test.
