# R10 — instant category drilldown: design

Code refs are `feat/review-2` (`git show feat/review-2:<path>`). Prior investigation: docs/slow-category-drilldown-2026-10-12.md.

## 0. Why it is slow and why it slides twice (verified)
- Each level is computed from the 4 M-row working set at tap time: GROUP BY per category (DatabaseManager.swift:1665-1700,
  ~1.3 s) + one pc-driven top-50 query per subcategory (:1110-1118, photos ~2.8 s) + growth totals (:2997) and journal
  overlay (BaselineService.swift:689-699) the view no longer shows (b9452fd). The precomputed `subcategorySnapshot`
  (:1517-1597) is read only while `hasIncrementalDeltasSinceSnapshot == false` (MenuBarManager.swift:2385-2388); any
  FSEvents batch sets it true (:3377). Only `workingSetCategoryTotal` is maintained incrementally (:2836-2869).
- Double slide: `selectCategory` drills to `.subcategories` with a skeleton while loading (CategoryGrowthListView.swift:
  570-596); on arrival, categories without subcategories set `isSubcategoryDrillDown = true` (:638-646) → pane id changes →
  `onChange(of: currentScreen)` (:124-150) slides again. Same in MenuBarView.swift:2037-2075. The "loading item at the
  top" of the files page is `contributorLoadingRow` (:477) fed by `loadGrowthContributors` (MenuBarManager.swift:1978;
  query DatabaseManager.swift:2886-2940 walks the whole subcategory with a LEFT JOIN on snapshotEntry).
- The three incremental writers already produce exact deltas keyed by (category, subcategory, unitKey) —
  `replaceWorkingSetFile` (:1922-2013), subtree staging CTE (:2170-2330), `removeWorkingSetFileIfPresent` (:2036) — and
  `applyWorkingSetCategoryDeltas` (:2843-2848) drops the subcategory. Full scans already accumulate per-subcategory totals
  and top items in memory (ScanService.swift:221-262, 452-459). An exact per-subcategory index is free; it is just not stored.

## 1. Data model — "drilldown index", exact, per tracked path
Two tables, written in the same transaction as `workingSetEntry` (so they can never drift from it), one state row.

```
workingSetGroupTotal (trackedPathId TEXT, category TEXT, groupKey TEXT, subcategory TEXT NOT NULL DEFAULT '',
                      totalBytes INTEGER NOT NULL, fileCount INTEGER NOT NULL, topShort INTEGER NOT NULL DEFAULT 0,
                      updatedAt DATETIME NOT NULL, PRIMARY KEY (trackedPathId, category, groupKey))
workingSetTopEntry   (trackedPathId TEXT, category TEXT, groupKey TEXT, pathId INTEGER NOT NULL REFERENCES paths ON DELETE CASCADE,
                      sizeBytes INTEGER NOT NULL, PRIMARY KEY (trackedPathId, category, groupKey, pathId))
  INDEX idx_wsTop_group_size ON workingSetTopEntry(trackedPathId, category, groupKey, sizeBytes DESC)
workingSetIndexState (trackedPathId TEXT PRIMARY KEY, state TEXT NOT NULL /* building|ready */, builtAt DATETIME)
pathClassification  + groupKey TEXT NOT NULL DEFAULT ''   (= subcategory, except cache subcategories: "cache:<app>" / "cache:")
  INDEX idx_pathClassification_category_groupKey_pathId (category, groupKey, pathId)   -- replaces idx…_subcategory_pathId
```
- `groupKey` preserves the existing per-application cache grouping (DatabaseManager.swift:1251-1300,
  GrowthCategory.swift:194) without path parsing at read time. Computed in Swift where classification is computed
  (ScanResult, `upsertPathClassifications` :2711, staging insert :2199) and by a new pure SQL function
  `prunr_group_key(category, subcategory, path)` (registered like `prunr_unit`, :85-89) for SQL-side paths.
  If Merlin drops per-app cache groups, `groupKey == subcategory` and this column goes away.
- Top-N table holds N = 200 rows per group (`SubcategoryGroup.maxLoadableFiles` is 500, initial page 50:
  CategoryInventoryItem.swift:129-135). Invariant: **the rows are always a correct prefix of the group's
  (sizeBytes DESC, path ASC) order**, possibly shorter than N; `topShort = 1` iff rows < min(N, fileCount).
- `workingSetCategoryTotal` stays (category list reads it, :1469); it is updated by the same delta call.

### Incremental maintenance (exact)
Change `JournalDeltaKey` values from `Int64` to `WorkingSetDelta { bytes: Int64; files: Int }` and add `groupKey`
to the key (journal still records `.bytes` keyed by category/subcategory/unit, GrowthJournalService unchanged).
- File upsert (:1922): old row → `-old.size, files -1`; new → `+size, +1` (per old/new groupKey). Subtree CTE (:2210-2256):
  add `SUM(CASE WHEN newRows.path IS NOT NULL THEN 1 ELSE 0 END - CASE WHEN oldRows.path IS NOT NULL THEN 1 ELSE 0 END)`
  and `pc.groupKey`/`s.groupKey` in the group. Removal (:2036): `-size, -1`.
- `applyWorkingSetDeltas` (rename of :2836): upsert `workingSetCategoryTotal` as today, plus upsert
  `workingSetGroupTotal` per (category, groupKey) with `totalBytes = MAX(0, +Δ)`, `fileCount = MAX(0, +Δ)`; delete rows
  with `fileCount <= 0`.
- Top table, per touched path in the same transaction (all O(log n) index ops):
  removed or shrunk path → `DELETE FROM workingSetTopEntry WHERE … pathId = ?`; set `topShort = 1` if rows < min(N, fileCount).
  new or grown path with size s → `m = MIN(sizeBytes)` of the group; insert if `rows < N AND topShort = 0`, or `s >= m`;
  then trim to N (`DELETE … WHERE pathId NOT IN (SELECT pathId … ORDER BY sizeBytes DESC, pathId LIMIT N)`).
  Proof sketch: a full top-N minus a removed path is the true top-(N-1); absent files are all ≤ the old minimum, so
  only inserts with `s >= m` can be ranked without a scan. Everything else marks `topShort` and is refilled later.
  Subtree replace: the staging rows are at most `maxRefreshTargets` subtrees; apply the per-path rule via two set
  statements (delete all old paths of the subtree from the top table; then insert staging rows that satisfy the rule
  per group; then trim) — no per-row Swift loop.
- Refill: `refillShortTopGroups(trackedPathId)` runs the existing pc-driven query (:1110, with `groupKey`) for groups
  with `topShort = 1`, in the background after each incremental refresh (debounced 2 s, one at a time, lowest
  priority). Photos (207 k rows, ~2.8 s cold) refills only when a top-200 photo is deleted or shrunk — rare.
- Zero-size files count toward `fileCount`, as today (`COUNT(*)` :1684). Groups are listed when `totalBytes > 0`
  (as :1686), kept while `fileCount > 0`.

### Full scan rebuild (write cost ≈ 0)
- ScanService already keeps `SubcategoryAccumulator` per (category, subcategory) with top-50 items (:221-262).
  Key it by `groupKey`, raise the top keep to N = 200 (a 200-element array per group, swap-min as now), and at the
  end write `workingSetGroupTotal` + `workingSetTopEntry` (≤ 200 × ~30 groups rows; pathIds via one
  `SELECT id, path FROM paths WHERE path IN (…)` per group) instead of `replaceSubcategorySnapshots` (:459).
  Then `state = ready`. This happens inside the scan's final transaction next to `replaceWorkingSetCategoryTotals`
  (:439) / `rebuildWorkingSet` (BaselineService.swift:135) so the index and the working set flip together.
- SQL fallback `rebuildDrilldownIndex(trackedPathId)` (used by migration, `rebuildWorkingSet` :1765,
  `restoreWorkingSetFromLatestSnapshotOrClear` :1838): `INSERT … SELECT category, groupKey, SUM, COUNT FROM
  workingSetEntry ⋈ pathClassification GROUP BY` (~1.3 s/category on the owner DB) + one top-N query per group
  (photos ~2.8 s, most < 0.1 s). `clearWorkingSetEntries` (:1816) and `clearRealtimeData` (:2657) also clear both tables.
- Migration `v23_drilldown_index`: create tables + column + index; backfill `groupKey` for cache rows only
  (`UPDATE pathClassification SET groupKey = prunr_group_key(…)` joined to paths, `WHERE category = 'cachesAndSystem' AND
  subcategory IN (…)`, else `groupKey = subcategory`); insert `state = building` per tracked path. The actual
  rebuild runs off-main at launch (`rebuildDrilldownIndexIfNeeded`) so the 4.5 GB DB does not block app start
  (est. 10–25 s once). Drop `subcategorySnapshot` and `idx_pathClassification_category_subcategory_pathId` in a later
  `v24` once nothing reads them. Keep `optimizeQueryPlanner` (:1372) — the refill and "more" queries still need stats.

## 2. Read path per level (all from the index, one read each, all < 10 ms on 4 M rows)
| Level | Query | Cost | Shows immediately |
|---|---|---|---|
| Categories | `workingSetCategoryTotal` (:1469), unchanged | PK scan, < 1 ms | sizes |
| Subcategories | `SELECT groupKey, subcategory, totalBytes, fileCount, topShort FROM workingSetGroupTotal WHERE trackedPathId = ? ORDER BY totalBytes DESC` — **all categories at once**, ≤ ~100 rows | < 1 ms | names, sizes, counts |
| Files | `SELECT p.path, t.sizeBytes FROM workingSetTopEntry t JOIN paths p ON p.id = t.pathId WHERE trackedPathId = ? AND category = ? AND groupKey = ? ORDER BY t.sizeBytes DESC, p.path` ≤ 200 rows | ~2–5 ms (200 rowid lookups) | first 50 rows + "n more / x GB" from exact totals |
| "More" (> 200) | existing `workingSetEntriesByClassificationSQL` (:1110) with `OFFSET`, user-initiated, inline spinner on the button | 0.1–3 s | — |

In-memory model: a `DrilldownStore` (@MainActor @Observable, replaces the subcategory caches in MenuBarManager)
holding `groupsByCategory` (loaded together with every inventory load: `loadQuickInventory` :2198 and
`loadInventoryFromLatestSnapshot` :1471 — so it is in memory whenever category rows are) and `filesByGroup`
(loaded when the subcategory page becomes current, one query for all groups of the category, ≤ 3 k rows ≈ 10 ms;
also on row hover). Multi-path merge as `mergedTopFiles` does today (BaselineService.swift:1390). Growth overlays
(`fetchGrowthTotalsBySubcategory`, journal subcategory totals, growth contributors) are not loaded in this view.

## 3. Navigation and state model — one slide per tap, no loader pages
- Replace the four manager fields (`isDrilledDown`, `selectedInventoryCategory`, `selectedSubcategory`,
  `isSubcategoryDrillDown`, MenuBarManager.swift:219-222) by one value:
  `enum DrilldownSelection: Equatable { case main; case subcategories(GrowthCategory); case files(GrowthCategory, groupKey: String) }`.
  `DrilldownListPane`/header derive purely from it; `reconcileDrillDownSelection` (:1741) maps it to the refreshed
  inventory (drop to `.main` only if the category disappeared; keep `.files` if the group still exists).
- **Rule: a tap sets the final selection synchronously from data already in memory, exactly once.**
  `selectCategory`: `category.supportsSubcategories ? .subcategories(c) : .files(c, onlyGroupKey)` — no async
  continuation (deletes :602-648 and MenuBarView.swift:2058-2075). `selectSubcategory`: `.files(c, key)`.
  Back: parent of the current case (:2008-2027 collapses to a 3-line switch). Nothing else may change the selection
  while the popover is open except back/close.
- `onChange(of: currentScreen)` therefore fires once per tap; `pendingTransition` queueing (:124-150) stays as safety
  but is unreachable from the drilldown itself. `DrilldownTransitionCoordinator` unchanged.
- Page contents are pure functions of `DrilldownStore` + selection. States without pages:
  `.subcategories`: groups present → list; `state == building` → one inline row "Indexing files…" (only loading
  state left in the view, shown once after the v23 upgrade); groups empty → "No files found" (exists :371).
  `.files`: rows from `filesByGroup`; if the prefetch has not landed yet (≤ 10 ms) the list simply fills in on the
  same page — header (name, size, count) is already known from totals; `topShort` only affects the "n more" math.
  Read error → inline row "Couldn't read the index — Retry" that calls `rebuildDrilldownIndex`. No skeleton, no spinner.

## 4. Delete (competing paths)
- DatabaseManager: `fetchWorkingSetSubcategoryGroupsByClassification` (:1665), `fetchSubcategoryGroupsByClassification` (:1600),
  `replaceSubcategorySnapshots`/`fetchSubcategoryGroups`/`StoredSubcategorySnapshot` (:1507-1597), cache-application group
  builders (:1251-1300), `fetchGrowthTotalsBySubcategory` (:2997), `fetchGrowthTotalsByCacheApplication` (:2950),
  `fetchGrowthContributors` (:2886), snapshot/LIKE-based entry fetches (:1075, :1141, :1177 — groupKey replaces the LIKE).
- BaselineService: both `getSubcategoryBreakdown` (:540, :1020), both `…FromWorkingSet` (:567, :587), `getSubcategoryGrowthTotals`
  (:1003), both `getGrowthContributors` (:712, :735; only this view uses them), snapshot `loadMoreSubcategoryFiles` (:788, :835).
- ScanService: `replaceSubcategorySnapshots` call (:459) → index write.
- MenuBarManager: `loadSubcategoryBreakdown` + resolve/load tasks/loading set/generations (:1840-1925, :2390-2445), warm-up
  (:1797-1838, aea356a), `hasIncrementalDeltasSinceSnapshot`/`shouldUseWorkingSetForSubcategoryDetails`/
  `liveWorkingSetDrillDownCategories` (:684-685, :2385, :3377), growth-contributor cache (:235-236, :1978-2021, :2433),
  `loadMoreFiles` snapshot branch (:1920-1940), `_test*` hooks (:2437-).
- CategoryGrowthListView: `isLoadingSubcategories`, subcategory/file skeletons, `contributorLoadingRow`, contributor state +
  `.task(id: contributorTaskID)` (:413-532), warm-up (:699-730), `subcategoryLoadTask`/token, `prefetchGrowthContributors`.
  Keep `categoryListSkeletonView` (first launch only). MenuBarView: async half of `navigateFromDriveBar` (:2058-2075).
- Tests from f68adec (warm-up, legacy-vs-new SQL comparisons) → replaced by §5.

## 5. Risks and the tests that pin them
1. **Index drift** (the correctness risk): any working-set write that bypasses `applyWorkingSetDeltas` desyncs totals.
   Writers are enumerated: file/subtree/remove deltas, scan rebuild, `rebuildWorkingSet`, `clear*`. Test helper
   `verifyDrilldownIndex(trackedPathId)` recomputes via GROUP BY + top-N and diffs; tests call it after every
   delta kind: new file, grow, shrink, delete, reclassify (category and groupKey change), subtree add/remove/mixed
   (staging path), removal of a subtree, zero-byte files, same path twice in one batch, multiple tracked paths.
2. **Top prefix invariant**: delete top-1 → rows = N-1, `topShort = 1`, list still a prefix; refill → N, flag 0;
   insert bigger than min while short → inserted; insert smaller than min while short → not inserted; trim at N+1.
3. **Migration on big DBs**: v23 on a v22 fixture (incl. cache paths) → `groupKey` backfilled, state `building`,
   background rebuild → `verifyDrilldownIndex` passes, drilldown reads work before and after. App start must not
   wait for the rebuild (assert migration time on a 1 M-row fixture < 1 s; rebuild measured separately).
4. **Scan/FSEvents race**: the index flips with the working set in the same transaction (scan final step,
   `rebuildWorkingSet`); a delta applied mid-scan hits the old working set and old index consistently — same
   exposure as `workingSetCategoryTotal` today. Test: deltas interleaved with `rebuildWorkingSet` end consistent.
5. **Staleness**: only the shortened prefix (until refill) — list still correct; counts exact. Test: refill
   debounce runs once per batch and leaves `topShort = 0`.
6. **Timing** (DrilldownQueryPerformanceTests, 1 M-row fixture, `measure`): group list < 5 ms, file list < 10 ms,
   a file delta < 5 ms, subtree delta of 1 k files < 100 ms; full index rebuild recorded, not asserted.
7. **Navigation**: `DrilldownSelection` transitions — tap on `supportsSubcategories == false` → `.files` directly;
   pane id changes exactly once per tap (observe `currentScreen` in a test harness); back from each level;
   `reconcileDrillDownSelection` keeps `.files` across an inventory refresh when the group survives and only
   collapses when it is gone. Journal `recordDeltas` still receives byte-only keys (existing episode tests stay green).

## 6. Slices (each `mac-queue add <dir> <ref> test Prunr` green)
S1 **Index (data, lands)**: v23 migration, `groupKey`, `WorkingSetDelta`, `applyWorkingSetDeltas` with group totals +
   top-N rules in the three delta paths, scan/rebuild/clear writes, `rebuildDrilldownIndexIfNeeded` + refill,
   `verifyDrilldownIndex`, tests §5.1–5.6. Old read paths untouched (UI unchanged).
S2 **Read path (logic, lands)**: `DrilldownStore` fed from the index with inventory loads; `loadMoreFiles` single path;
   delete §4 DB/Baseline/Manager query code, warm-up, snapshot bypass, `subcategorySnapshot` writes. Views still
   compile against the store; skeletons become unreachable (no visual change except speed).
S3 **Navigation (UI, waits for Merlin)**: `DrilldownSelection`, synchronous `selectCategory`/`selectSubcategory`/back,
   drive-bar entry, inline states, delete skeletons/contributor row/CGLV warm-up; tests §5.7.
S4 **Cleanup (lands)**: v24 drops `subcategorySnapshot` + old pc index, removes snapshot-based fallbacks and
   `SkeletonListRow` styles, prunes lessons/docs; final perf numbers into docs/.
