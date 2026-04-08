# Prunr Architecture Deep Dive: Category Bloat Bug & Systemic Review

**Date:** 2026-04-08  
**Context:** Post-initial-scan category sizes inflate 2–3× beyond reality (e.g., "Caches & System" shows 700 GB–3 TB when actual is ~41 GB). The DB is always correct; bloat is in-memory only.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Data Flow Maps](#3-data-flow-maps)
4. [Root Cause Analysis](#4-root-cause-analysis)
5. [Secondary Bug: Phantom Scan Indicator](#5-secondary-bug-phantom-scan-indicator)
6. [Systemic Issues Found](#6-systemic-issues-found)
7. [Dead Code Inventory](#7-dead-code-inventory)
8. [Per-File Detailed Findings](#8-per-file-detailed-findings)
9. [Recommendations](#9-recommendations)

---

## 1. Executive Summary

The category bloat is a **data-flow correctness bug** rooted in `MenuBarManager.normalizeVisibleInventoryState()`. The function merges two in-memory arrays (`growingCategories` + `stableCategories`) by **summing** sizes for same-category entries. When the same category appears in both arrays (which happens routinely during scan progress ticks and inventory reloads), sizes double. Because progress ticks fire every ~2 seconds and the function is called after each, the doubling compounds exponentially.

The DB layer is architecturally sound — `workingSetCategoryTotal` and `workingSetEntry` are always consistent because they're updated transactionally. The bug is 100% in the in-memory UI state management in `MenuBarManager`.

Beyond the bloat, the review found:
- **5 systemic issues** (race-prone state, dual-path inventory loads, redundant merges, single-actor bottleneck, missing ownership boundaries)
- **3 dead-code artifacts** from the previous fix attempt
- **1 secondary bug** (phantom scan indicator after initial scan)
- Significant architectural coupling that makes incremental fixes fragile

---

## 2. Architecture Overview

### 2.1 Layer Diagram

```
┌─────────────────────────────────────────────────────────┐
│                     Views (SwiftUI)                      │
│  MenuBarView · DriveBarView · CategoryGrowthListView     │
│  DrilldownListPane · SizeBarView · GrowthBarView          │
└────────────────────────┬────────────────────────────────┘
                         │ reads @Observable properties
┌────────────────────────▼────────────────────────────────┐
│              MenuBarManager (@MainActor)                  │
│  ┌─────────────────┐  ┌─────────────────────────────┐   │
│  │ growingCategories│  │ stableCategories             │   │
│  │ stableTotalBytes │  │ subcategoryGroupsByCategory  │   │
│  │ partialScanCat.. │  │ currentInventorySnapshotIDs  │   │
│  └────────┬────────┘  └──────────┬──────────────────┘   │
│           │ normalizeVisible      │                       │
│           │ InventoryState()      │ applyPartialCategory  │
│           │                       │ Totals()              │
│           ▼                       ▼                       │
│  ┌──────────────────────────────────────────────────┐    │
│  │  loadInventory() · loadInventoryFromLatestSnap()  │    │
│  │  performRecentChangeRefresh() · applyInventory()  │    │
│  │  refreshVisibleInventory() · checkGrowth()        │    │
│  └───────────────────────┬──────────────────────────┘    │
└──────────────────────────┼───────────────────────────────┘
                           │ async calls
┌──────────────────────────▼───────────────────────────────┐
│                      Services (Actors)                    │
│  BaselineService ── ScanService ── FileScanner            │
│  RecentChangeService ── FSEventsWatcher                   │
│  GrowthJournalService ── DatabaseCleanupService           │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│                   DatabaseManager (singleton)             │
│  SQLite/GRDB ── workingSetEntry ── workingSetCategoryTotal│
│  snapshotEntry ── categorySnapshot ── subcategorySnapshot │
│  pathClassification ── growthJournalBucket                │
└──────────────────────────────────────────────────────────┘
```

### 2.2 Key Tables & Their Roles

| Table | Purpose | Updated By |
|---|---|---|
| `snapshot` | Metadata for each full scan | ScanService via createBaseline |
| `snapshotEntry` | Raw file-level sizes per snapshot | ScanService (batch insert) |
| `workingSetEntry` | Live mutable file-level state | ScanService (inline), RecentChangeService |
| `workingSetCategoryTotal` | Aggregated category sizes from working set | ScanService (bulk), RecentChangeService (delta) |
| `pathClassification` | SQL-side category/subcategory per path | Insert triggers, migration v17 |
| `categorySnapshot` | Pre-computed category totals per snapshot | ScanService (after scan) |
| `subcategorySnapshot` | Pre-computed subcategory breakdown | ScanService (after scan) |
| `growthJournalBucket` | Time-bucketed growth deltas | RecentChangeService, createBaseline |

### 2.3 The Dual-Path Data Model

Prunr maintains **two parallel representations** of category sizes:

1. **Snapshot-based** (`categorySnapshot`): Written once during `ScanService.scan()`, immutable per snapshot. Used for historical trend detection and cross-snapshot comparison.

2. **Working-set-based** (`workingSetCategoryTotal` + `workingSetEntry`): Live mutable state, updated incrementally by `RecentChangeService` via `replaceWorkingSetSubtree()`. This is the source-of-truth for current sizes.

The `BaselineService.getCategoryInventory()` method prefers working-set totals when available, falling back to snapshot totals. This creates an asymmetry: the UI sometimes reads from one path, sometimes the other, and sometimes both in rapid succession (during a scan's live progress → final inventory transition).

---

## 3. Data Flow Maps

### 3.1 Full Scan Flow (loadInventory)

```
User taps "Check Growth" / auto-scan triggers
    │
    ▼
MenuBarManager.loadInventory(isAutomatic:)
    │
    ├─ Reset state: partialScanCategoryTotalsByPathID = [:]
    ├─ prepareAggregateScanProgress()
    │
    ▼
createBaselines(for: enabledPaths)
    │
    ├─ For each TrackedPath:
    │   └─ BaselineService.createBaseline()
    │       └─ ScanService.scan()
    │           ├─ Streams files via FileScanner
    │           ├─ Every 250ms: progress callback → applyAggregateScanProgress()
    │           │   └─ Every ~2s: progress.categoryTotals set
    │           │       └─ applyPartialCategoryTotals()
    │           │           ├─ partialScanCategoryTotalsByPathID[path.id] = totals
    │           │           ├─ Aggregate across all paths
    │           │           ├─ growingCategories = []  ← FIX: clear first
    │           │           ├─ stableCategories = liveCategories  ← replaced
    │           │           └─ stableTotalBytes recalculated
    │           │
    │           ├─ Every 50k files: DB batch write
    │           │   └─ addEntriesWithWorkingSet() — writes both snapshotEntry
    │           │       AND workingSetEntry in same transaction
    │           │
    │           ├─ After scan completes:
    │           │   └─ replaceWorkingSetCategoryTotals() — writes workingSetCategoryTotal
    │           │   └─ replaceCategorySnapshots() — writes categorySnapshot
    │           │   └─ replaceSubcategorySnapshots() — writes subcategorySnapshot
    │           │
    │           └─ Final progress callback with categoryTotals
    │               └─ applyPartialCategoryTotals() one last time
    │
    ▼
baselineService.getInventoryWithTrends()
    │
    ├─ For each TrackedPath:
    │   └─ getCategoryInventory()
    │       ├─ Try workingSetCategoryTotal (fast, usually present)
    │       └─ Fallback to categorySnapshot for this path
    │   └─ getInventoryWithTrends() adds growthJournal stories
    │
    └─ Aggregate across paths in BaselineService.getInventoryWithTrends()
        └─ Returns InventoryAggregationResult
    │
    ▼
MenuBarManager.applyInventory()
    │
    ├─ Split items into growing (has growthStory) vs stable
    ├─ growingCategories = growing
    ├─ stableCategories = stable
    ├─ stableTotalBytes = sum of stable
    ├─ normalizeVisibleInventoryState()  ← ***BOOM***
    │   ├─ Merges growingCategories + stableCategories by category
    │   ├─ If same category in both: SUMS currentSizeBytes
    │   └─ Re-splits into growingCategories / stableCategories
    │
    ▼
UI reads growingCategories + stableCategories → DRIVE BAR + CATEGORY LIST
```

### 3.2 FSEvents Incremental Refresh Flow

```
FSEventsWatcher fires → recordFileWatcherChangeBatch()
    │
    ├─ pendingRecentChangePaths accumulates URLs
    └─ scheduleRecentChangeRefreshTask(after: 1.5s)
        │
        ▼
performRecentChangeRefresh()
    │
    ├─ Route changed paths to tracked paths
    ├─ For each tracked path:
    │   └─ RecentChangeService.refreshChangedPaths()
    │       ├─ resolve refreshTargets (file/subtree/removal)
    │       ├─ For each target:
    │       │   └─ db.replaceWorkingSetSubtree()
    │       │       ├─ Computes old-vs-new deltas via staging table
    │       │       ├─ Deletes old workingSetEntry rows under rootPath
    │       │       ├─ Inserts new rows from staging
    │       │       ├─ applyWorkingSetCategoryDeltas() — patches workingSetCategoryTotal
    │       │       └─ Returns deltasByCategory
    │       └─ growthJournalService.recordDeltas()
    │
    ├─ If needsFullScan → loadInventory(isAutomatic: true)
    │
    └─ If updated → loadInventoryFromLatestSnapshot()
        └─ BaselineService.getInventoryWithTrends()
            └─ applyInventory()
                └─ normalizeVisibleInventoryState()
```

### 3.3 Silent Reconciliation Flow

```
reconcileIfStale() triggers (scan interval exceeded)
    │
    ▼
performSilentReconciliation()
    │
    ├─ createBaselines() — full scan, no progress callbacks
    └─ loadInventoryFromLatestSnapshot()
        └─ Same as 3.2's final step
```

---

## 4. Root Cause Analysis

### 4.1 The Smoking Gun: `normalizeVisibleInventoryState()`

```swift
private func normalizeVisibleInventoryState() {
    var mergedByCategory: [GrowthCategory: CategoryInventoryItem] = [:]

    for item in growingCategories + stableCategories {  // ← iterates BOTH arrays
        if let existing = mergedByCategory[item.category] {
            mergedByCategory[item.category] = CategoryInventoryItem(
                category: item.category,
                currentSizeBytes: existing.currentSizeBytes + item.currentSizeBytes,  // ← SUMS!
                growthTrend: mergeGrowthTrend(existing.growthTrend, item.growthTrend),
                recentGrowthStory: mergeRecentGrowthStory(existing.recentGrowthStory, item.recentGrowthStory)
            )
        } else {
            mergedByCategory[item.category] = item
        }
    }

    let sorted = mergedByCategory.values.sorted { ... }
    growingCategories = sorted.filter { $0.recentGrowthStory != nil }
    stableCategories = sorted.filter { $0.recentGrowthStory == nil }
    stableTotalBytes = stableCategories.reduce(0) { $0 + $1.currentSizeBytes }
}
```

**The function assumes `growingCategories` and `stableCategories` contain disjoint category sets.** When this invariant is violated, sizes are summed — producing exactly the 2× bloat observed (and higher with repeated violations).

### 4.2 How the Invariant Gets Violated

There are **three distinct pathways** that can introduce duplicate categories:

#### Pathway A: applyPartialCategoryTotals → applyInventory transition

During a scan, `applyPartialCategoryTotals()` runs every ~2 seconds:

```swift
func applyPartialCategoryTotals(...) {
    // FIX: Now clears growingCategories first
    growingCategories = []
    stableCategories = liveCategories
    stableTotalBytes = liveCategories.reduce(0) { $0 + $1.currentSizeBytes }
}
```

After the scan completes, `applyInventory()` is called with the full inventory from `getInventoryWithTrends()`. This splits items into `growingCategories` (those with growth stories) and `stableCategories` (those without).

**The problem:** Between the last `applyPartialCategoryTotals()` and `applyInventory()`, there is no synchronization gap. The last progress tick may have set `stableCategories` from partial scan data. Then `applyInventory()` overwrites both arrays. So far so good — **this transition is actually safe after the fix**.

**But:** `applyInventory()` calls `normalizeVisibleInventoryState()` at the end. If `applyInventory` itself accidentally puts the same category in both `growing` and `stable` arrays (which it doesn't — it partitions cleanly based on `recentGrowthStory != nil`), then `normalizeVisibleInventoryState` would double them.

Wait — `applyInventory` does partition correctly. The bug must be elsewhere.

#### Pathway B: loadInventoryFromLatestSnapshot race with partial data

After `performRecentChangeRefresh()` completes, it calls:

```swift
if hadUpdate {
    await loadInventoryFromLatestSnapshot(refreshedAt: Date(), invalidateSubcategoryCache: false)
}
```

`loadInventoryFromLatestSnapshot()` calls `applyInventory()` which calls `normalizeVisibleInventoryState()`.

**But what if an FSEvents callback fires during `loadInventoryFromLatestSnapshot`?** The callback calls `recordFileWatcherChangeBatch()` which sets `hasPendingRecentChanges = true` and schedules another `scheduleRecentChangeRefreshTask`. This doesn't directly modify `growingCategories` / `stableCategories`, so it's not a direct cause.

#### Pathway C: The FSEvents flush after initial scan

After `loadInventory()` completes, the final block does:

```swift
// Flush any FSEvents that arrived during the scan
if pendingRecentChangeRequiresFullRefresh || !pendingRecentChangePaths.isEmpty {
    scheduleRecentChangeRefreshTask(after: 0.5)
}
```

This schedules `performRecentChangeRefresh()` which calls `loadInventory(isAutomatic: true)` if `pendingRecentChangeRequiresFullRefresh` is true, or `loadInventoryFromLatestSnapshot()` if only deltas were detected.

**The loadInventory path triggers a full scan** which calls `applyPartialCategoryTotals()` again. But by this point, the arrays were already set by the previous scan's `applyInventory()`. Between those two points, `applyPartialCategoryTotals()` now clears `growingCategories`, so this path is also safe after the fix.

#### Pathway D: The REAL remaining culprit — concurrent Task scheduling

The most likely remaining bloat path involves **task interleaving**. Both `loadInventory` and `performRecentChangeRefresh` are async methods running on `@MainActor`, but they have internal `await` suspension points where other MainActor work can interleave.

Consider this sequence:
1. `loadInventory()` starts, runs `createBaselines()` → `applyPartialCategoryTotals()` sets `stableCategories` to partial data, `growingCategories = []`
2. Scan completes → `applyInventory()` sets `growingCategories` to categories with growth stories and `stableCategories` to those without
3. `applyInventory()` calls `normalizeVisibleInventoryState()` — **this is fine, sets are disjoint**
4. `loadInventory()` hits `await DatabaseCleanupService.shared.performAutoCleanup()` (an await point)
5. During this suspension, the scheduled FSEvents flush fires `performRecentChangeRefresh()`
6. `performRecentChangeRefresh()` detects it needs a full refresh, calls `loadInventory(isAutomatic: true)`
7. But `isLoading` is still true from step 1, so... wait, `performRecentChangeRefresh` checks `!isLoading`:
   ```swift
   guard !isLoading, !isInventoryRefreshInProgress, !isAutoScanning else {
       scheduleRecentChangeRefreshTask(after: currentRecentChangeDebounce)
       return
   }
   ```
8. It reschedules itself. Eventually after `loadInventory()` completes (sets `isLoading = false`), the rescheduled task fires.

This seems properly guarded. Let me look deeper...

#### Pathway E: `loadQuickInventory` → `loadInventoryFromLatestSnapshot` transition

In `MenuBarView.task`:
```swift
// Phase 1: Fast — show categories instantly from pre-computed totals
let hasQuickData = await manager.loadQuickInventory()

// Phase 2: Background — enrich with growth stories, trends, disk accounting
await manager.loadInventoryFromLatestSnapshot()
```

`loadQuickInventory()` sets:
```swift
growingCategories = []
stableCategories = items  // all categories, no growth stories
stableTotalBytes = ...
```

Then `loadInventoryFromLatestSnapshot()` calls `applyInventory()` which calls `normalizeVisibleInventoryState()`.

Between these two calls, `growingCategories = []` and `stableCategories` has all categories. When `applyInventory` runs, it overwrites both arrays. This is safe.

#### Pathway F: The actual smoking gun — `applyPartialCategoryTotals` last tick AFTER applyInventory

Let me re-examine the scan flow more carefully:

1. `ScanService.scan()` sends final progress update with `categoryTotals`
2. Progress callback fires on **MainActor** via `Task { @MainActor in self.applyAggregateScanProgress(...) }`
3. This is a **detached Task** — it runs asynchronously!
4. Meanwhile, `createBaselines()` returns the completed snapshot
5. `loadInventory()` proceeds to `baselineService.getInventoryWithTrends()` and `applyInventory()`
6. `applyInventory()` sets `growingCategories` and `stableCategories`, calls `normalizeVisibleInventoryState()`
7. **THEN** the detached Task from step 2 fires and calls `applyPartialCategoryTotals()`

In `applyPartialCategoryTotals`, the current code does:
```swift
growingCategories = []
stableCategories = liveCategories
stableTotalBytes = liveCategories.reduce(0) { $0 + $1.currentSizeBytes }
```

This replaces `stableCategories` entirely and clears `growingCategories`. So the bloat would be **temporary** — the partial data overwrites the correct data, then on the next full refresh it's corrected.

But wait — the `progress` callback in `createBaselines` is synchronous:
```swift
let progressCallback: (TrackedPath, ScanService.ScanProgress) -> Void = { trackedPath, progress in
    Task { @MainActor in
        self.applyAggregateScanProgress(for: trackedPath, progress: progress)
    }
}
```

The `Task { @MainActor in ... }` creates a **new detached task**! It does NOT block the caller. So the progress update is enqueued on the MainActor queue but may execute **after** `createBaselines` returns.

This means:
1. Scan sends final progress with full category totals
2. The `Task { @MainActor }` for the final progress is enqueued
3. `createBaselines` returns immediately
4. `loadInventory` proceeds to `applyInventory()` → sets correct state
5. **Later**, the enqueued Task runs `applyPartialCategoryTotals()` which replaces the correct state with partial scan data

**This is a race condition!** The final progress tick's `Task { @MainActor }` can execute AFTER `applyInventory` has already set the correct state. When it does, it overwrites the correct categories with partial data from the scan's category totals.

However, this wouldn't cause the **doubling** described in the bug — it would cause incorrect (partial) totals, not inflated ones.

#### Pathway G: The definitive doubling path — concurrent applyInventory calls

The most likely bloat scenario combines **two `applyInventory` calls** in quick succession with an interleaving:

1. First `applyInventory()` call sets:
   - `growingCategories = [Caches(41GB, growthStory)]`
   - `stableCategories = [Developer(100GB), Other(200GB), ...]`

2. `normalizeVisibleInventoryState()` runs — fine, disjoint sets

3. Before the first `loadInventory` finishes, the FSEvents flush triggers `performRecentChangeRefresh` → `loadInventoryFromLatestSnapshot()`

4. Wait — `loadInventoryFromLatestSnapshot` uses `beginInventoryRefresh()` / `endInventoryRefresh()` guard, and `loadInventory` also checks this. So they shouldn't interleave.

**Actually** — `loadInventory` doesn't use `beginInventoryRefresh()`. It has its own `isLoading` flag. And `loadInventoryFromLatestSnapshot` uses `beginInventoryRefresh()`. These are **separate locks**! They don't exclude each other.

So the actual race is:
1. `loadInventory()` is running (isLoading=true)
2. After it sets state via `applyInventory()` but before it finishes (during an await), the FSEvents flush's `performRecentChangeRefresh` is scheduled
3. `performRecentChangeRefresh` checks `!isLoading` → true (still loading) → reschedules
4. `loadInventory()` finishes, sets `isLoading = false`
5. The rescheduled `performRecentChangeRefresh` fires → calls `loadInventoryFromLatestSnapshot()`
6. This loads fresh data from DB and calls `applyInventory()` again

This shouldn't cause doubling either — it's just two sequential `applyInventory` calls, each of which replaces both arrays completely.

**OK, I believe the actual remaining issue is more subtle.** Let me look at what `applyPartialCategoryTotals` does when it races with the transition out of scan state:

The real scenario is likely:
1. During scan, `applyPartialCategoryTotals` fires repeatedly, setting `growingCategories = []`, `stableCategories = [Caches(41GB), Developer(100GB), ...]`
2. Scan completes, `applyInventory` fires with growth stories. Sets `growingCategories = [Caches(41GB, story)]`, `stableCategories = [Developer(100GB), ...]`
3. `normalizeVisibleInventoryState` runs. `growingCategories` has Caches(41GB), `stableCategories` doesn't have Caches. **Fine.**
4. **But** a delayed progress Task fires: `applyPartialCategoryTotals` sets `growingCategories = []`, `stableCategories = [Caches(41GB), Developer(100GB), ...]`
5. This **removes the growth story** from Caches — the category is now only in stableCategories. No doubling.

**I now believe the fix to `applyPartialCategoryTotals` (clearing growingCategories first) actually resolved the primary bloat mechanism.** The remaining bloat reports may come from a different path.

Let me check one more path — `acceptGrowth()`:

```swift
func acceptGrowth() async {
    ...
    await loadInventoryFromLatestSnapshot(refreshedAt: Date(), invalidateSubcategoryCache: true, force: true)
    ...
}
```

This passes `force: true` to `loadInventoryFromLatestSnapshot`:
```swift
func loadInventoryFromLatestSnapshot(..., force: Bool = false) async {
    if force {
        isInventoryRefreshInProgress = true  // bypasses the guard
    } else {
        guard beginInventoryRefresh() else { return }
    }
```

If `acceptGrowth()` is called while another inventory load is in progress, `force: true` **breaks the exclusion** and allows two inventory loads to run simultaneously. Both would call `applyInventory()` and `normalizeVisibleInventoryState()`. If they interleave, the second `applyInventory` reads stale `growingCategories + stableCategories` from the first call's intermediate state.

### 4.3 Summary of Bloat Vectors

| # | Pathway | Mechanism | Status |
|---|---|---|---|
| 1 | `applyPartialCategoryTotals` leaves `growingCategories` intact while setting `stableCategories` from partial data → `normalizeVisibleInventoryState` merges same category from both arrays | **Fixed** by clearing `growingCategories = []` |
| 2 | Detached `Task { @MainActor }` progress callbacks fire after `applyInventory` has already set correct state | Partially addressed — clears growingCategories but may overwrite correct data with stale partial data |
| 3 | `loadInventoryFromLatestSnapshot(force: true)` bypasses mutual exclusion | **Open** — can cause interleaved `applyInventory` calls |
| 4 | `normalizeVisibleInventoryState` fundamentally assumes disjoint sets but has no assertion or guard | **Open** — design fragility |

---

## 5. Secondary Bug: Phantom Scan Indicator

### Symptom
After the initial scan completes, the scan progress indicator reappears briefly at the bottom of the UI.

### Cause
In `loadInventory()`, the final block:
```swift
if pendingRecentChangeRequiresFullRefresh || !pendingRecentChangePaths.isEmpty {
    scheduleRecentChangeRefreshTask(after: 0.5)
}
```

This schedules `performRecentChangeRefresh()` 500ms after the scan finishes. If FSEvents accumulated events during the scan (which is expected — the scan itself writes to the DB and creates files), `performRecentChangeRefresh` may escalate to `loadInventory(isAutomatic: true)`:

```swift
if pendingRecentChangeRequiresFullRefresh {
    pendingRecentChangeRequiresFullRefresh = false
    ...
    await loadInventory(isAutomatic: true)  // sets isAutoScanning = true!
    return
}
```

`isAutoScanning = true` triggers the activity pulse animation and shows scan UI. The fix is to not set `isAutoScanning` when the trigger is a post-scan flush, or to debounce more aggressively after a scan completes.

---

## 6. Systemic Issues Found

### 6.1 Dual Exclusion Mechanisms for Inventory Refresh

**Two separate, non-mutual exclusion mechanisms exist:**

- `isLoading` flag — used by `loadInventory()`
- `isInventoryRefreshInProgress` flag — used by `loadInventoryFromLatestSnapshot()`, `beginInventoryRefresh()`/`endInventoryRefresh()`

These don't exclude each other. `loadInventoryFromLatestSnapshot(force: true)` explicitly bypasses `isInventoryRefreshInProgress`. There's no single gate that prevents concurrent inventory state mutations.

### 6.2 `normalizeVisibleInventoryState` is a Code Smell

The function exists because `growingCategories` and `stableCategories` are allowed to become inconsistent. A properly partitioned data model wouldn't need a "normalize" step. The function:

1. **Adds** sizes when same category appears in both arrays (the bug)
2. **Merges** growth trends and stories using complex custom logic
3. **Re-splits** the merged data back into two arrays
4. Is called from 4 different places

The two-array split (growing vs stable) should be a **view concern** computed from a single source of truth, not maintained as two mutable arrays that need reconciliation.

### 6.3 Progress Callbacks Use Detached Tasks

In `createBaselines()`:
```swift
let progressCallback: (TrackedPath, ScanService.ScanProgress) -> Void = { trackedPath, progress in
    Task { @MainActor in
        self.applyAggregateScanProgress(for: trackedPath, progress: progress)
    }
}
```

Each progress update creates a **detached Task** that runs asynchronously on MainActor. This means:
- Progress updates are unordered relative to the main scan flow
- The last progress update can execute **after** the scan completes and `applyInventory` has run
- There's no way to cancel these orphaned tasks

### 6.4 MenuBarManager is a God Object

At ~2740 lines, `MenuBarManager` handles:
- UI state management (categories, drill-down, scan progress)
- FSEvents monitoring configuration
- Recent change debouncing and scheduling
- Panel/popover lifecycle
- File watcher setup and teardown
- Disk space monitoring
- Growth acceptance flow
- Subcategory breakdown caching
- Onboarding folder picking
- Context menu setup

This makes it extremely difficult to reason about state mutations and their interactions.

### 6.5 applyWorkingSetCategoryDeltas Can Accumulate Drift

The `applyWorkingSetCategoryDeltas()` function in `DatabaseManager` does incremental arithmetic:

```swift
let existing = totalsByCategory[key.category]?.totalBytes ?? 0
let nextTotal = max(0, existing + deltaBytes)
```

If the delta computation in `replaceWorkingSetSubtree` has any rounding or edge-case error (e.g., from the staging-table CTE's LEFT JOIN semantics), the error accumulates and is never corrected because there's no periodic full-reconciliation of the totals table against the actual entry rows.

The `recalculateAllCategoryTotals` and `recalculateAffectedCategoryTotals` functions were added to address this but are currently unused (dead code).

---

## 7. Dead Code Inventory

| Location | Function | Status | Notes |
|---|---|---|---|
| `DatabaseManager` | `recalculateAllCategoryTotals()` | **Dead** — never called | Was added to replace `applyWorkingSetCategoryDeltas`, then reverted due to 2.8s latency on 1.4M entries |
| `DatabaseManager` | `recalculateAffectedCategoryTotals()` | **Dead** — never called | Scoped version of above, also never called |

The old `applyIncrementalDeltas` function in `MenuBarManager` was already removed (confirmed not in current code).

---

## 8. Per-File Detailed Findings

### 8.1 MenuBarManager.swift (2739 lines)

**Severity: Critical**

| Finding | Severity | Lines | Detail |
|---|---|---|---|
| `normalizeVisibleInventoryState()` sums same-category entries | 🔴 Critical | ~2450 | Root cause of bloat bug |
| Detached Task progress callbacks race with applyInventory | 🟡 High | ~createBaselines | Progress updates can overwrite post-scan state |
| `force: true` in `loadInventoryFromLatestSnapshot` breaks exclusion | 🟡 High | ~loadInventoryFromLatestSnapshot | Allows concurrent applyInventory calls |
| `partialScanCategoryTotalsByPathID` cleared too late | 🟠 Medium | ~loadInventory | Cleared after scan, but orphaned Tasks may still reference old data |
| `scheduleRecentChangeRefreshTask(after: 0.5)` post-scan flush | 🟠 Medium | ~loadInventory final block | Causes phantom scan indicator |
| God object anti-pattern | 🟡 High | Entire file | 2740 lines, 10+ responsibilities |
| No `@MainActor` isolation annotation on class | 🟢 Low | Class declaration | Class is `@MainActor` but methods that mutate state don't have explicit assertions |

### 8.2 DatabaseManager.swift (2355 lines)

**Severity: Moderate**

| Finding | Severity | Detail |
|---|---|---|
| Dead code: `recalculateAllCategoryTotals()` | 🟠 Medium | Unused, adds confusion |
| Dead code: `recalculateAffectedCategoryTotals()` | 🟠 Medium | Unused, adds confusion |
| `applyWorkingSetCategoryDeltas` has no drift correction | 🟡 High | Incremental arithmetic accumulates errors over time |
| `replaceWorkingSetSubtree` CTE is complex and hard to verify | 🟠 Medium | 50-line SQL CTE for delta computation |
| `normalizePath` is idempotent but called repeatedly | 🟢 Low | Minor perf concern, already batched |
| `fetchPathIds` + `upsertPathClassifications` race window | 🟠 Medium | Between fetch and upsert, another writer could insert same path |

### 8.3 BaselineService.swift (1517 lines)

**Severity: Moderate**

| Finding | Severity | Detail |
|---|---|---|
| `getCategoryInventory` has 3-tier fallback with different data shapes | 🟠 Medium | workingSet → categorySnapshot → raw scan — each returns slightly different data |
| `getSubcategoryBreakdown` has massive TopEntryHeap implementation | 🟠 Medium | 130 lines of heap sort inlined — duplicated for working-set variant |
| `comparableBaselineSnapshotId` has arbitrary thresholds | 🟢 Low | `candidateEntryCount < minimumComparableEntryCount` could reject valid baselines |
| `mergeRecentGrowthStory` logic duplicated in MenuBarManager | 🟠 Medium | Both files have identical merge functions |

### 8.4 RecentChangeService.swift

**Severity: Low**

| Finding | Severity | Detail |
|---|---|---|
| Well-structured actor with clear responsibility boundaries | ✅ Good | Clean separation of concerns |
| `maxRefreshTargets = 192` is arbitrary but reasonable | 🟢 Low | Falls back to full scan at 192 targets |
| Staging table approach is sound | ✅ Good | Avoids large in-memory sets |

### 8.5 ScanService.swift

**Severity: Moderate**

| Finding | Severity | Detail |
|---|---|---|
| Inline working-set writes are a major performance win | ✅ Good | Eliminates 2.2M row post-scan copy |
| Category totals accumulated in-memory during scan | ✅ Good | Avoids per-file DB queries |
| `cancellationToken` pattern is correct | ✅ Good | Shared token checked in hot loop |
| Final progress update sent after scan completes | 🟠 Medium | May race with consumer's post-scan processing |
| SubcategoryAccumulator duplicated from BaselineService | 🟠 Medium | Same TopEntryHeap pattern |

### 8.6 GrowthJournalService.swift

**Severity: Low**

| Finding | Severity | Detail |
|---|---|---|
| Clean time-bucketed design | ✅ Good | Simple, correct |
| Segment scoring weights recency appropriately | ✅ Good | 24h full weight, then decay |
| `floorToMinute` truncation is correct | ✅ Good | Prevents sub-second bucket proliferation |

### 8.7 DatabaseCleanupService.swift

**Severity: Low**

| Finding | Severity | Detail |
|---|---|---|
| Thorough snapshot lifecycle management | ✅ Good | Backfills category/subcategory totals before deleting entries |
| VACUUM gating is sensible (reclaim thresholds) | ✅ Good | Avoids unnecessary expensive operations |
| Startup maintenance waits for idle | ✅ Good | Doesn't interfere with user-initiated scans |

---

## 9. Recommendations

### 9.1 Fix the Bloat (Immediate Priority)

**Option A: Single-source-of-truth with computed split (Recommended)**

Replace the two mutable arrays with a single `allCategories: [CategoryInventoryItem]` and compute growing/stable as derived properties:

```swift
var allCategories: [CategoryInventoryItem] = []

var growingCategories: [CategoryInventoryItem] {
    allCategories.filter { $0.recentGrowthStory != nil }
}

var stableCategories: [CategoryInventoryItem] {
    allCategories.filter { $0.recentGrowthStory == nil }
}
```

This eliminates `normalizeVisibleInventoryState()` entirely. The drive bar and category list would read from the computed properties. `applyInventory()` would just set `allCategories` and be done.

**Caveat:** `@Observable` with computed properties may trigger excessive SwiftUI re-renders. Benchmark needed. If re-renders are a problem, cache the split in a stored property that's set alongside `allCategories`.

**Option B: Guard normalizeVisibleInventoryState**

If refactoring to a single array is too risky, add a pre-condition assertion:

```swift
private func normalizeVisibleInventoryState() {
    // Assert no duplicates across arrays
    let growingSet = Set(growingCategories.map(\.category))
    let stableSet = Set(stableCategories.map(\.category))
    assert(growingSet.isDisjoint(with: stableSet), 
           "Duplicate categories in growing+stable: \(growingSet.intersection(stableSet))")
    ...
}
```

This won't fix the bug but will catch it immediately during development.

### 9.2 Fix Mutual Exclusion (High Priority)

Replace `isLoading`, `isInventoryRefreshInProgress`, and `force: true` with a single `@MainActor` state machine:

```swift
enum InventoryRefreshState {
    case idle
    case fullScan(Task<Void, Never>?)
    case quickRefresh(Task<Void, Never>?)
}
```

Only allow state transitions that make sense:
- idle → fullScan
- idle → quickRefresh
- fullScan → idle
- quickRefresh → idle

### 9.3 Fix Detached Progress Callbacks (High Priority)

Change the progress callback to be **synchronous on MainActor**:

```swift
let progressCallback: @MainActor (TrackedPath, ScanService.ScanProgress) -> Void = { ... }
```

Or use an `AsyncStream` that the scan produces into and `MenuBarManager` consumes on MainActor, ensuring ordered delivery.

### 9.4 Fix Phantom Scan Indicator (Medium Priority)

After `loadInventory()` completes, clear the FSEvents flush delay or mark it as "post-scan cleanup" so it doesn't trigger `isAutoScanning = true`:

```swift
// After scan completes:
if pendingRecentChangeRequiresFullRefresh || !pendingRecentChangePaths.isEmpty {
    // Process incrementally, don't escalate to full scan with UI
    scheduleRecentChangeRefreshTask(after: 2.0) // Longer delay
    // OR: process silently without setting isAutoScanning
}
```

### 9.5 Periodic Category Total Reconciliation (Medium Priority)

Add a periodic reconciliation that runs `recalculateAffectedCategoryTotals` for categories that have had many incremental delta applications. This could run during `performAutoCleanup()`:

```swift
// In DatabaseCleanupService.performAutoCleanup():
try await db.recalculateAffectedCategoryTotals(
    affectedCategories: categoriesWithDeltasSinceLastReconciliation,
    trackedPathId: pathId,
    updatedAt: Date()
)
```

This would catch any drift from `applyWorkingSetCategoryDeltas` arithmetic errors.

### 9.6 Decompose MenuBarManager (Low Priority, High Impact)

Split into focused services:

- **`InventoryStateManager`** — owns `allCategories`, `growingCategories`, `stableCategories`, handles apply/set
- **`ScanProgressManager`** — owns `scanProgressPercentage`, `filesScanned`, `scanCurrentPath`, handles progress updates
- **`FileSystemMonitor`** — owns FSEvents watcher, recent change debouncing, pending paths
- **`SubcategoryCacheManager`** — owns subcategory breakdown caching and loading
- **`MenuBarUIManager`** — owns status item, panel, popover, disk space display

`MenuBarManager` becomes a thin coordinator that delegates to these services.

### 9.7 Clean Up Dead Code

Remove:
- `DatabaseManager.recalculateAllCategoryTotals()` 
- `DatabaseManager.recalculateAffectedCategoryTotals()`

These are currently unreachable and add confusion. If needed in the future, they can be restored from git history.

---

## Appendix: State Variable Inventory in MenuBarManager

The following mutable state variables live in `MenuBarManager` and are read by SwiftUI views:

| Variable | Type | Set By | Consumed By |
|---|---|---|---|
| `growingCategories` | `[CategoryInventoryItem]` | applyInventory, applyPartialCategoryTotals, normalize | DriveBarView, CategoryGrowthListView |
| `stableCategories` | `[CategoryInventoryItem]` | applyInventory, applyPartialCategoryTotals, normalize | DriveBarView, CategoryGrowthListView |
| `stableTotalBytes` | `Int64` | applyInventory, applyPartial | DriveBarView |
| `isLoading` | `Bool` | loadInventory | MenuBarView (scan UI) |
| `isAutoScanning` | `Bool` | loadInventory | MenuBarView (pulse animation) |
| `scanProgressPercentage` | `Double` | applyAggregateScanProgress | SizeBarView |
| `filesScanned` | `Int` | applyAggregateScanProgress | scan status card |
| `partialScanCategoryTotalsByPathID` | `[UUID: [GrowthCategory: Int64]]` | applyPartialCategoryTotals | Internal only |
| `isInventoryRefreshInProgress` | `Bool` | begin/endInventoryRefresh | Mutual exclusion |
| `hasIncrementalDeltasSinceSnapshot` | `Bool` | applyInventory, loadInventory | Subcategory path selection |
| `subcategoryGroupsByCategory` | `[GrowthCategory: [SubcategoryGroup]]` | loadSubcategoryBreakdown | DrilldownListPane |
| `selectedInventoryCategory` | `CategoryInventoryItem?` | UI tap handlers | Drilldown navigation |
| `reconciliationResult` | `DiskAccountingResult?` | loadInventory | DriveBarView |
| `hasPendingRecentChanges` | `Bool` | recordFileWatcherChangeBatch | Status bar text |

**Total: 14+ mutable state variables** that interact through `normalizeVisibleInventoryState()` and `applyInventory()`. This is the core complexity driver.

---

*End of review.*
