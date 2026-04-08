# Prunr Architecture Review — Final Findings

**Date:** 2026-04-08  
**Context:** Category bloat bug (sizes inflate 2–3× after scan). Three rounds of review, one platform-patterns audit against Apple/GRDB docs. This document consolidates all verified findings.

**Proof audit:** 2026-04-08 — every claim verified against source code + Apple `FSEvents.h`, `swiftlang/swift-migration-guide` DataRaceSafety.md, Swift Programming Language Concurrency chapter, and bundled GRDB `ValueObservation.md`/`DatabasePool.md`. Discrepancies corrected inline. Full proof in `architecture-review-proof-of-patterns.md`.

---

## 1. The Bloat Bug: Fix Status

### Fix is complete.

`normalizeVisibleInventoryState()` was the doubling mechanism — it summed same-category entries from `growingCategories` + `stableCategories` when both arrays contained the same category. The fix (clearing `growingCategories = []` in `applyPartialCategoryTotals`) closes the only code path that could introduce duplicates before `normalizeVisibleInventoryState` runs.

**Proof:**

- `normalizeVisibleInventoryState` has exactly **3 call sites** (lines 1627, 1760, 1778)
- At each call site, arrays are set by **synchronous MainActor code** immediately before the call — no `await` between set and normalize
- At each call site, arrays are **provably disjoint** by construction (partition by `recentGrowthStory != nil`, or `growing = []`, or restore from captured valid state)
- `applyPartialCategoryTotals` (the only other writer to these arrays) does **not** call `normalizeVisibleInventoryState`
- MainActor serialization prevents any interleaving between array assignment and normalize

**If bloat still reproduces**, the cause is not in the growing/stable split. Investigate `workingSetCategoryTotal` arithmetic drift or verify the fix was actually compiled into the running binary.

---

## 2. Bugs Found

### Bug A: FSEvents Use-After-Free Risk (Severity: High)

**File:** `Prunr/Services/FSEventsWatcher.swift`

The C callback captures the watcher via `Unmanaged.passRetained(self).toOpaque()`, then in the callback:

```swift
let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
Task {
    await watcher.emitChangeBatch(changedPaths, ...)
}
```

If `FSEventsWatcher.stop()` runs between the C callback firing and the unstructured `Task` executing, `stop()` calls `FSEventStreamInvalidate` + `FSEventStreamRelease` + `releaseCallbackInfo` (which calls `Unmanaged.release()`). The Task then calls `emitChangeBatch` on a deallocated actor — **use-after-free**.

**Mitigation already in place:** `emitChangeBatch` (line 192) starts with `guard isRunning else { return }`. Since `FSEventsWatcher` is an actor, `stop()` sets `isRunning = false` and releases the pointer atomically before the pending Task re-enters the actor. The `isRunning` guard then causes the stale Task to return early. Actor serialization prevents the race in practice.

**Residual risk:** If the actor's last strong reference is released by `stop()` (unlikely — the caller typically holds a reference), the Task's `takeUnretainedValue()` reference would dangle. The `Unmanaged` pattern is still technically unsound; it should use `takeRetainedValue()` or bridge to `AsyncStream`.

**Type-mismatch in `Unmanaged` usage:** `start()` retains via `Unmanaged.passRetained(self as AnyObject)` (creating an `Unmanaged<AnyObject>`), but the callback casts back via `Unmanaged<FSEventsWatcher>.fromOpaque(info)`. These are different generic types. In practice, for Swift actors, `self as AnyObject` produces the same pointer, so the cast works. But this is fragile — any change to the boxing behavior or introducing a class hierarchy could break it. The canonical pattern is to use `Unmanaged.passRetained(self)` without the `as AnyObject` erasure.

**Fix:** Use `takeRetainedValue()` in the Task (and don't release in `stop()`), or better: bridge FSEvents to Swift concurrency via `AsyncStream` instead of unstructured Tasks.

### Bug B: Detached Progress Tasks Overwrite Correct State (Severity: Medium)

**File:** `Prunr/Services/MenuBarManager.swift` line 824

```swift
let progressCallback = { trackedPath, progress in
    Task { @MainActor in
        self.applyAggregateScanProgress(for: trackedPath, progress: progress)
    }
}
```

Each progress update creates an unstructured task. The final progress task can execute **after** `applyInventory` has already set the correct state, overwriting it with partial scan data (categories without growth stories). This causes growth story indicators to briefly flicker off then on.

**Fix:** Replace with `AsyncStream` for ordered delivery + cancellation propagation, or drain/cancel pending progress tasks before calling `applyInventory`.

### Bug C: `loadInventoryFromLatestSnapshot(force: true)` Bypasses Mutual Exclusion (Severity: Low)

**File:** `Prunr/Services/MenuBarManager.swift` line 984

`acceptGrowth()` calls `loadInventoryFromLatestSnapshot(force: true)` which sets `isInventoryRefreshInProgress = true` unconditionally instead of using `beginInventoryRefresh()`. This can theoretically allow two inventory loads to interleave at `await` suspension points.

In practice this is harmless because both are MainActor-isolated and `applyInventory` always produces disjoint arrays. But it breaks the exclusion pattern and could cause issues if the code evolves.

**Fix:** Remove `force: true`, use `beginInventoryRefresh()`, and guard `acceptGrowth` with `!isInventoryRefreshInProgress`.

---

## 3. Platform Pattern Violations

### 3.1 Unstructured Tasks Used as Default Pattern

Apple's Swift Concurrency documentation recommends structured concurrency (`TaskGroup`, `AsyncStream`, cancellation handlers). Prunr uses `Task { }` (unstructured) as its primary mechanism:

- Progress callbacks: `Task { @MainActor in ... }` (line 824)
- FSEvents bridge: `Task { await watcher.emitChangeBatch(...) }` (FSEventsWatcher.swift)
- Subcategory preload: `Task { @MainActor in ... }` (line 1211, `preloadSubcategoryBreakdowns`)
- Silent reconciliation: `reconciliationTask = Task { @MainActor in ... }` (line 1134, `reconcileIfStale`)

**Consequence:** No cancellation propagation from scan stop to pending progress tasks. No ordering guarantees. Potential memory accumulation during long scans.

### 3.2 Critical Section Atomicity Not Enforced

Apple's Migration Guide states:

> *"Because the current isolation domain is freed up to perform other work, actor-isolated state may change after an asynchronous call. You can think of explicitly marking potential suspension points as a way to indicate the end of a critical section."*

`loadInventory()` has 8 `await` suspension points:
1. `await armFileWatcherBeforeFullScanIfNeeded(for:)` (line 831)
2. `try await createBaselines(for:progressCallback:)` (line 834)
3. `try? await Task.sleep(for: .milliseconds(120))` (line 842)
4. `await baselineService.getInventoryWithTrends(trackedPaths:)` (line 852)
5. `await baselineService.getDiskAccounting(trackedPaths:primaryTrackedPath:)` (line 862)
6. `try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))` (line 906, minimum display duration)
7. `await DatabaseCleanupService.shared.performAutoCleanup()` (line 919)
8. `await growthJournalService.prune(retentionDays:)` (line 920)

Between each, detached Tasks or FSEvents callbacks can modify `growingCategories`/`stableCategories`. The code works correctly today because `applyPartialCategoryTotals` clears `growingCategories`, but the invariants are undocumented and fragile.

### 3.3 FSEvents Coalescing vs Debouncing Confusion

The codebase uses "debounce" terminology but FSEvents' `latency` parameter is **coalescing** (deliver all events from the last N seconds in one batch), not debouncing (reset timer on each event). The code applies both — FSEvents coalesces at 1.0s, then `scheduleRecentChangeRefreshTask` debounces at 1.5s — giving effective latency up to 2.5 seconds. The distinction matters for understanding the system's responsiveness characteristics.

Additionally, the stream is created **without** `kFSEventStreamCreateFlagNoDefer`. Per Apple's `FSEvents.h`, the default (deferred) mode delays the **first** event after a quiet period by the full latency — unlike `NoDefer` mode which delivers the first event immediately and only delays subsequent ones. This makes the worst-case 2.5s latency more likely in practice, because even an isolated file change sits in the FSEvents queue for a full second before the callback fires. The variable naming (`debounceInterval` for the FSEvents latency parameter in `FSEventsWatcher`) further illustrates the coalescing/debouncing confusion.

### 3.4 Missing FSEventStreamFlush

Apple documents `FSEventStreamFlushSync` as a way to force immediate delivery of pending events. Prunr never calls it. Under heavy I/O or when the main run loop is busy, events may be delayed beyond the configured latency.

---

## 4. Architecture Observations

### 4.1 MenuBarManager is a 2738-line God Object

Handles: UI state management, FSEvents monitoring, scan orchestration, panel/popover lifecycle, disk space monitoring, growth acceptance, subcategory caching, onboarding, context menus. Decomposition into focused services (InventoryStateManager, ScanProgressManager, FileSystemMonitor, SubcategoryCacheManager, MenuBarUIManager) would improve testability and make the reentrancy invariants tractable.

### 4.2 Two-Array Split Should Be Computed, Not Stored

`growingCategories` and `stableCategories` are maintained as two separate mutable arrays that require `normalizeVisibleInventoryState` to reconcile. A single `allCategories: [CategoryInventoryItem]` with computed `growingCategories`/`stableCategories` filters would eliminate the entire class of merge bugs. The `@Observable` macro tracks computed property access — SwiftUI would re-render only when `allCategories` changes.

### 4.3 GRDB ValueObservation Could Replace the Manual Reactive Pipeline

The entire debounce → read DB → apply to state → normalize pipeline could be replaced by:

```swift
let observation = ValueObservation.tracking { db in
    try fetchCategoryTotals(db)
}
observation.start(in: dbPool, scheduling: .mainActor) { error in
    // handle error
} onChange: { items in
    self.allCategories = items  // Single source of truth
}
```

This would automatically deliver consistent snapshots on MainActor whenever the DB changes, eliminating `normalizeVisibleInventoryState` and the debounce machinery. The reason it wasn't used is likely that `ValueObservation` fires on every write — during a full scan with thousands of batch writes, this could overwhelm the UI. But observing only `workingSetCategoryTotal` (which changes far less frequently than `workingSetEntry`) would be manageable.

### 4.4 DB Reads Can See Inconsistent Snapshots

`loadInventoryFromLatestSnapshot` performs two separate `await`-based reads:

```swift
let aggregation = await baselineService.getInventoryWithTrends(trackedPaths: enabledPaths)
// ← write could commit here
reconciliationResult = await baselineService.getDiskAccounting(trackedPaths: enabledPaths, ...)
```

GRDB's `DatabasePool` uses WAL mode where each read sees a consistent snapshot — but **different reads can see different snapshots** if a write commits between them. GRDB provides `makeSnapshot()` for frozen point-in-time views. Low severity for Prunr's use case but worth noting.

### 4.5 @Observable Granularity

`applyPartialCategoryTotals` fires every ~2s during scans, setting `stableCategories` to a new array each time. With `@Observable`, setting a property to a new value always triggers observation, even if the content is identical. SwiftUI re-renders any view reading `stableCategories` every 2 seconds during scans.

**Note on `@ObservationIgnored` recommendation:** `partialScanCategoryTotalsByPathID` is already `private` (line 375), so SwiftUI views cannot access it directly and it won't trigger observation transitively — unless a computed property read by a view references it. Marking it `@ObservationIgnored` is a valid defensive measure but not strictly required. The real render-frequency concern is `stableCategories` itself being reassigned every ~2s with identical content; a manual equality check before assignment would be more effective.

---

## 5. Dead Code

| Location | Function | Status |
|---|---|---|
| `DatabaseManager.swift` line 1931 | `recalculateAllCategoryTotals()` | Never called |
| `DatabaseManager.swift` line 1977 | `recalculateAffectedCategoryTotals()` | Never called |

Both confirmed dead via project-wide grep. The old `applyIncrementalDeltas` was already removed.

---

## 6. Prioritized Recommendations

| Priority | Action | Rationale |
|---|---|---|
| **P0** | Add assertion to `normalizeVisibleInventoryState` logging when same-category duplicates appear | Confirms fix is complete or catches any remaining trigger |
| **P1** | Fix FSEvents `Unmanaged` pattern in `FSEventsWatcher` | Technically unsound; mitigated by actor isolation + `isRunning` guard, but should use `takeRetainedValue()` or `AsyncStream` |
| **P1** | Replace progress callback `Task { @MainActor }` with `AsyncStream` | Eliminates stale-data overwrite and enables cancellation |
| **P2** | Delete dead `recalculate*` functions in DatabaseManager | Hygiene |
| **P2** | Remove `force: true` from `acceptGrowth` | Exclusion bypass (harmless today, risky for future changes) |
| **P3** | Replace two-array split with single `allCategories` + computed properties | Eliminates merge-bug class |
| **P3** | Evaluate `ValueObservation` for reactive DB → UI pipeline | Could simplify debounce + normalize machinery |
| **P3** | Decompose MenuBarManager | Improves testability and makes invariants tractable |
| **P3** | Add periodic `applyWorkingSetCategoryDeltas` reconciliation | Catches arithmetic drift in category totals |
