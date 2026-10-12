# R9 — slow category drilldown (skeleton for ~30 s)

Branch feat/s16-beta-flow. Measured read-only on mbp's real DB (4.5 GB, sqlite3 CLI, wall times).
Data: workingSetEntry 4.0 M rows (one tracked path), snapshotEntry 7.3 M, pathClassification 4.4 M,
mediaAndDocuments = 236 k paths (photos 207 k, videos 13.6 k, documents 8.9 k, designFiles 210).

## Code path
1. Tap row → `CategoryGrowthListView` (~l.570) / `MenuBarView` (l.2060): if `!isSubcategoryBreakdownReady`
   it drills in immediately with the skeleton and awaits `manager.loadSubcategoryBreakdown(category)`.
2. `MenuBarManager.loadSubcategoryBreakdown` (l.1830): cache hit returns at once. Miss → branch on
   `shouldUseWorkingSetForSubcategoryDetails` = `hasIncrementalDeltasSinceSnapshot`, which is set by
   ANY FSEvents incremental update (l.3367). On a watched home folder that is true almost always.
3. Working-set branch → `BaselineService.getSubcategoryBreakdownFromWorkingSet` (l.587) →
   `DatabaseManager.fetchWorkingSetSubcategoryGroupsByClassification` (l.1620):
   a. GROUP BY subcategory over wse⋈pc — plan is pc(category) → wse(trackedPath,pathId). **1.3 s**
   b. then a serial `for` loop: one `fetchWorkingSetEntriesByClassification` top-20 query PER subcategory.
      Plan: `SEARCH wse USING INDEX idx_workingSetEntry_trackedPath (trackedPathId=?)` → walks all 4 M
      working-set rows, looks up pc and paths by rowid, temp B-tree sort. **6.8 / 9.4 / 8.2 / 8.3 s** → ~33 s.
   c. `fetchGrowthTotalsBySubcategory` (wse⋈pc⋈LEFT snapshotEntry). **1.5 s**
   d. journal subcategory totals (indexed bucket table, small).
   Total ≈ **35 s cold** for Media & Documents. Wall ≫ CPU (user ~0.4 s per query) → I/O bound.
4. Snapshot branch (only right after a full scan) is fast: `subcategorySnapshot` precomputed rows **<1 ms**
   + 3c (1.5 s). So the precompute exists but is bypassed by step 2.
5. Not the cause: main actor (DB work runs in `dbPool.read`, Swift merge is tiny); re-fetch on every
   open (cache keyed by generation, only bumped on full refresh/snapshot change); `GrowthCategory.categorize`
   (classification is precomputed in `pathClassification`); view rebuilds.

## Root causes (ranked)
1. **Bad join order in the per-subcategory top-N query.** SQLite has no `sqlite_stat1` (never ANALYZEd),
   so it drives from `wse.trackedPathId` (= every row, single tracked path) instead of the selective
   `pc(category, subcategory)` covering index. Forcing pc first (`pathClassification pc CROSS JOIN
   workingSetEntry wse`): photos 9.4 s → **1.9 s**, videos 6.8 s → **0.065 s**. Same issue in
   `fetchSnapshotEntriesByClassification` (fallback path) — same fix.
2. **Working-set branch is the default after any file change**, so the scan-time `subcategorySnapshot`
   precompute is almost never used, and each subcategory query runs serially.
3. Contention: first open fans out a preload per visible category (review P5), all hitting the same 4 M
   rows on a 4.5 GB DB at once, slowing the one the user actually opened.
4. Cache invalidation: every full scan / snapshot change clears all categories, so the first open after
   each nightly scan pays the full cost again.

## Fix options
A. **Force pc-driven join order** (CROSS JOIN or reorder FROM) in the 2 `...EntriesByClassification`
   queries (+ check the cache-app variants). Size: S (2–4 SQL strings + a test). Risk: low; same results,
   plan only. Expected: ~35 s → ~5 s cold (photos 207 k rows still dominates), < 1 s warm.
   Optionally run `ANALYZE`/`PRAGMA optimize` after scans so the planner gets it right everywhere (S, low).
B. **Use the precomputed snapshot breakdown for structure even with deltas**, overlaying working-set
   totals from (3a) and journal growth; fetch top files lazily when a subcategory opens. Size: M.
   Risk: medium — top-file lists can be stale until the next scan; changes what the list shows.
C. **Keep working-set subcategory totals + top-N in a table updated by incremental refresh**
   (like `workingSetCategoryTotal`). Size: L. Risk: medium-high (scan/storage logic, needs Merlin).

Recommendation: A now (+ PRAGMA optimize), drop P5 warm-all to "largest category only"; B later if
photos-scale subcategories still feel slow.
