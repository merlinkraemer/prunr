# Fix Plan: Growth Indicators & Live Tracking

Date: 2026-03-15
Status: Proposed

## Bugs Addressed

1. Duplicated files don't show as added/grown
2. Manual refresh ("Check Growth") does nothing
3. Random growth indicators for untouched areas
4. Subcategory drilldown loads forever (never shows data)
5. Slow initial scan (10+ min for 2M files)

---

## Fix 1: `checkGrowth()` should trigger a real working-set refresh

**Problem:** When `pendingRecentChangePaths` is empty, `checkGrowth()` just re-reads the existing DB snapshot via `loadInventoryFromLatestSnapshot()`. No new filesystem data is collected. If FSEvents already flushed (or were filtered), clicking refresh is a no-op that shows stale data.

**File:** `Prunr/Services/MenuBarManager.swift` — `checkGrowth()` (~line 995)

**Fix:**
- When `pendingRecentChangePaths` is empty and the user explicitly clicks refresh, trigger a lightweight working-set reconciliation for the tracked paths instead of just re-reading the DB.
- Use `RecentChangeService.refreshChangedPaths()` with the tracked root URLs as subtree targets. This re-stats all files under the root without a full FTS scan — it only reads the working set entries and checks for size changes.
- Alternative (simpler): Queue the tracked path roots into `pendingRecentChangePaths` before calling `performRecentChangeRefresh()`, so the existing pipeline handles them.

```swift
func checkGrowth() async {
    guard !isLoading, !isAutoScanning, !isProcessingRecentChanges else { return }
    isCheckingGrowth = true
    defer { isCheckingGrowth = false }
    recentChangeTask?.cancel()
    recentChangeTask = nil

    if pendingRecentChangePaths.isEmpty {
        // Force a root-level refresh instead of just re-reading stale DB data
        let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
        for tp in enabledPaths {
            pendingRecentChangePaths.insert(tp.url.standardizedFileURL)
        }
    }
    await performRecentChangeRefresh()
}
```

**Risk:** If the tracked root is the entire home dir (~2M files), `RecentChangeService.refreshTargets()` will create a single `.subtree(trackedRoot)` target (because there are no more-specific changes to coalesce), which triggers a full subtree rescan via `FileScanner.scan()`. This could be slow.

**Mitigation:** Add a fast-path for root-level refreshes: instead of rescanning the full tree, rebuild working-set category totals from the existing working-set entries and compare to current values. Only do the full subtree rescan if the user holds shift or we detect the working set is stale.

**Simpler alternative:** Just always call `loadInventoryFromLatestSnapshot(refreshedAt: Date(), invalidateSubcategoryCache: true)` AND also update `lastDetectedChangeAt` so the status text refreshes. This at least fixes the "does nothing" perception even if it doesn't pick up new files. The real new-file detection stays with FSEvents.

---

## Fix 2: Lower the growth story threshold for manual check

**Problem:** `GrowthJournalService.recentStoryThresholdBytes` is 250 MB. Any category growth below this threshold produces no `RecentGrowthStory`, so the category lands in `stableCategories` with no growth indicator — even if files were genuinely added.

**File:** `Prunr/Services/GrowthJournalService.swift` — `buildStories()` (~line 113)

**Fix:**
- Reduce `recentStoryThresholdBytes` from 250 MB to something more reasonable like 10 MB or 50 MB.
- Alternatively, make the threshold proportional to category size (e.g., 2% of category total or 10 MB, whichever is larger).

```swift
// Before:
private let recentStoryThresholdBytes: Int64 = 250 * 1024 * 1024

// After:
private let recentStoryThresholdBytes: Int64 = 10 * 1024 * 1024
```

**Trade-off:** Lower threshold means more categories show growth indicators. That's the desired behavior — users want to see where files are being added. The current 250 MB threshold is far too aggressive for detecting day-to-day file duplication.

---

## Fix 3: Narrow the growth story recency window

**Problem:** `recentStoryWindow` is 7 days. Any 250MB+ (or post-fix: 10MB+) growth segment within the past week generates a growth indicator, even if the growth happened days ago and is irrelevant.

**File:** `Prunr/Services/GrowthJournalService.swift` — `buildStories()` (~line 8, 104)

**Fix:**
- Reduce `recentStoryWindow` from 7 days to 24 hours (or make it configurable).
- Add a recency decay: stories older than a few hours get progressively weaker scoring, so only truly recent growth surfaces.

```swift
// Before:
private let recentStoryWindow: TimeInterval = 7 * 24 * 60 * 60

// After:
private let recentStoryWindow: TimeInterval = 24 * 60 * 60
```

This directly fixes "random growth indicators for areas I didn't touch" — old growth stories from days ago will no longer surface.

---

## Fix 4: Subcategory drilldown — stop falling back to full working-set scan

**Problem:** `hasIncrementalDeltasSinceSnapshot` is set to `true` as soon as any FSEvents delta is applied (line 2351). Once true, ALL subcategory drilldowns use `getSubcategoryBreakdownFromWorkingSet()`, which paginates through the entire working set (2M entries at 5000/page = 400+ DB queries + 2M classify() calls). This is far too slow and appears to hang.

**File:** `Prunr/Services/MenuBarManager.swift` — `loadSubcategoryBreakdown()` (~line 1251)

**Fix:** Use the precomputed `subcategorySnapshot` table as the primary source and only patch it with incremental deltas, rather than rebuilding from scratch.

```swift
// In loadSubcategoryBreakdown(), replace the branching logic:

let groups: [SubcategoryGroup]
if currentInventorySnapshotIDsByPath.isEmpty {
    // Deltas-only mode (no snapshot at all): must use working set
    guard let primaryPath = self.primaryTrackedPath(from: enabledPaths) else {
        return .skipped
    }
    groups = await baselineService.getSubcategoryBreakdownFromWorkingSet(
        for: category,
        trackedPathId: primaryPath.id
    )
} else {
    // Always use precomputed subcategorySnapshot (fast path)
    groups = await baselineService.getSubcategoryBreakdown(
        for: category,
        trackedPathsById: trackedPathsByID,
        latestSnapshotIdsByPath: currentInventorySnapshotIDsByPath,
        baselineSnapshotIdsByPath: currentGrowthBaselineSnapshotIDsByPath
    )
}
```

**Key insight:** The precomputed `subcategorySnapshot` data is written during the scan and is always available for the latest snapshot. The incremental FSEvents deltas update `workingSetCategoryTotals` (category-level) but NOT `subcategorySnapshot`. The drilldown data may be slightly stale (missing FSEvents changes), but it's far better than an infinite-loading spinner.

**Follow-up improvement:** After FSEvents deltas are applied, invalidate only the affected categories' subcategory caches. On next drilldown, load from `subcategorySnapshot` and merge the known deltas on top. This gives accuracy without the full-scan cost.

---

## Fix 5: Guard against `isInventoryRefreshInProgress` blocking manual refresh

**Problem:** `loadInventoryFromLatestSnapshot()` calls `beginInventoryRefresh()` which returns `false` if another refresh is already in progress. This silently swallows the entire operation. When `checkGrowth()` calls it, the user sees nothing happen.

**File:** `Prunr/Services/MenuBarManager.swift` — `checkGrowth()` / `beginInventoryRefresh()` (~line 2496)

**Fix:** `checkGrowth()` should bypass or override the `isInventoryRefreshInProgress` guard since it's an explicit user action. Options:

Option A: Add a `force` parameter to `loadInventoryFromLatestSnapshot()`:
```swift
func loadInventoryFromLatestSnapshot(
    refreshedAt: Date? = nil,
    invalidateSubcategoryCache: Bool = false,
    force: Bool = false  // Bypasses isInventoryRefreshInProgress guard
) async {
    guard force || beginInventoryRefresh() else { return }
    ...
}
```

Option B: Cancel any in-progress refresh before starting the manual one (similar to how `refreshVisibleInventory()` already cancels reconciliation at line 984).

---

## Fix 6: Scan performance improvements (lower priority)

**Problem:** 2M files in 10+ minutes. The bottleneck is the combination of: per-file classify(), AsyncThrowingStream yielding, and batched DB inserts with path deduplication.

**File:** `Prunr/Services/FileScanner.swift`, `Prunr/Services/ScanService.swift`

**Potential improvements (pick and measure):**

### 6a. Reduce classify() cost
`GrowthCategory.classify()` lowercases the entire path and runs 20+ string contains/prefix checks per file. For 2M files this is ~40M string operations.

- Cache the lowercased home path (already done via `homePathLowercased`).
- Short-circuit: if path starts with `~/Library/Caches/`, immediately return `.cachesAndSystem` without checking all other categories.
- Pre-compute the lowercased path once in FileScanner and pass it to classify — avoid double lowercasing when both `categorize()` and `subcategorize()` are called separately (this already happens via `classify()` but `buildSnapshotSummary` in DatabaseCleanupService calls them separately at line 529).

### 6b. Increase batch size
Current batch is 15,000 items. For 2M files that's 133 batch inserts. Each batch involves a DB transaction with path dedup + multi-row INSERT. Increasing to 50,000 would reduce to 40 batches.

### 6c. Reduce Task.yield() frequency
Currently yields every 2,000 files (FileScanner line 148). For 2M files that's 1,000 yields. Increase to every 10,000 or 20,000.

### 6d. Skip files below a size threshold during scan
Files < 4KB (one filesystem block) contribute negligible disk usage. Skipping them could eliminate a large fraction of the 2M entries. This would need a user-facing setting and careful messaging.

---

## Implementation Order

1. **Fix 4** — Subcategory drilldown (highest user impact, simplest fix)
2. **Fix 1** — Manual refresh actually does something
3. **Fix 5** — Guard bypass for manual refresh
4. **Fix 2** — Lower growth threshold
5. **Fix 3** — Narrow recency window
6. **Fix 6** — Scan performance (measure first, then pick improvements)

Fixes 1 + 5 together resolve "manual refresh does nothing."
Fixes 2 + 3 together resolve "random growth indicators / missing indicators."
Fix 4 alone resolves "subcategory drilldown hangs."
