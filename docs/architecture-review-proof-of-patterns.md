# Architecture Review — Proof of Every Pattern Against Source & Apple Docs

**Date:** 2026-04-08  
**Purpose:** Independently verify every claim in `architecture-review-final-findings.md` by (a) reading the actual source code and (b) citing Apple/GRDB documentation. Each finding is marked ✅ Verified, ⚠️ Partially Accurate, or ❌ Incorrect.

---

## 1. The Bloat Bug Fix

### Claim: `normalizeVisibleInventoryState()` has exactly 3 call sites (lines 1627, 1760, 1778)

**Verdict: ✅ Verified**

Source code grep confirms exactly 3 call sites:
```
1627:        normalizeVisibleInventoryState()
1760:            normalizeVisibleInventoryState()
1778:            normalizeVisibleInventoryState()
```

Line 1627 is inside `applyInventory()` (partition by `recentGrowthStory != nil`).  
Line 1760 is inside `clearVisibleGrowthIndicators()` (sets `growingCategories = []`).  
Line 1778 is inside `restoreGrowthPresentationState()` (restores from captured state).

### Claim: At each call site, arrays are set by synchronous MainActor code immediately before the call — no `await` between set and normalize

**Verdict: ✅ Verified**

**Line 1627 (`applyInventory`):** The growing/stable partition loop (lines 1612–1626) is synchronous. It builds `growing` and `stable` arrays, assigns them to `growingCategories` / `stableCategories`, then immediately calls `normalizeVisibleInventoryState()`. No `await` between.

**Line 1760 (`clearVisibleGrowthIndicators`):** Sets `growingCategories = []` and `stableCategories = allCategories` synchronously, then calls normalize. No `await`.

**Line 1778 (`restoreGrowthPresentationState`):** Sets `growingCategories = state.growingCategories` and `stableCategories = state.stableCategories` synchronously, then calls normalize. No `await`.

### Claim: `applyPartialCategoryTotals` does NOT call `normalizeVisibleInventoryState`

**Verdict: ✅ Verified**

Source at lines 264–298: `applyPartialCategoryTotals` sets `growingCategories = []` and `stableCategories = liveCategories` directly, with no call to `normalizeVisibleInventoryState`.

### Claim: `applyPartialCategoryTotals` clears `growingCategories = []`, preventing merge duplication

**Verdict: ✅ Verified**

Line 296: `growingCategories = []`  
Line 297: `stableCategories = liveCategories`  
Comment at line 294: `"Do NOT merge with existing growingCategories — normalizeVisibleInventoryState would add them together, causing category bloat."`

---

## 2. Bug A: FSEvents Use-After-Free Risk

### Claim: C callback captures watcher via `Unmanaged.passRetained(self).toOpaque()`

**Verdict: ✅ Verified**

Line 69: `let contextPtr = Unmanaged.passRetained(self as AnyObject).toOpaque()`

### Claim: Callback uses `takeUnretainedValue()` inside a `Task {}`

**Verdict: ✅ Verified**

Line 95: `let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()`  
Lines 120–122: `Task { await watcher.emitChangeBatch(changedPaths, ...) }`

### Claim: `stop()` calls `FSEventStreamInvalidate` + `FSEventStreamRelease` + `releaseCallbackInfo` (which calls `Unmanaged.release()`)

**Verdict: ✅ Verified**

Lines 167–170:
```swift
FSEventStreamStop(eventStream)
FSEventStreamInvalidate(eventStream)
FSEventStreamRelease(eventStream)
releaseCallbackInfoIfNeeded()
```

And `releaseCallbackInfoIfNeeded` (lines 200–204) calls `Self.releaseCallbackInfo` which does:  
`Unmanaged<AnyObject>.fromOpaque(callbackInfoPointer).release()` (line 218)

### Claim: Use-after-free scenario is possible

**Verdict: ✅ Verified (mechanically sound)**

The sequence is:
1. C callback fires → captures `watcher` via `takeUnretainedValue()` (no retain)
2. Creates `Task { await watcher.emitChangeBatch(...) }` (unstructured, no execution ordering guarantee)
3. Before the Task executes, `stop()` is called → releases the retain from `passRetained`
4. Task finally executes → calls method on deallocated actor → **use-after-free**

`takeUnretainedValue()` does NOT retain. The only retain was the `passRetained` in `start()`, which `stop()` releases. If `stop()` runs between steps 2 and 4, the watcher is deallocated.

### Claim: `emitChangeBatch` has a `guard isRunning` check that would prevent execution after stop

**Verdict: ⚠️ Mitigating factor exists, but not sufficient**

Line 192: `guard isRunning else { return }`

However, `isRunning` is set to `false` in `stop()` (line 164). Since `FSEventsWatcher` is an actor, and `stop()` sets `isRunning = false` before releasing, the `Task` created in the C callback would re-enter the actor and see `isRunning == false`. This **does** protect against the crash in most scenarios because actor serialization means the `stop()` would complete before the `emitChangeBatch` call enters.

**Revised assessment:** The risk is lower than stated because actor isolation serializes access to `isRunning`. However, the `Unmanaged` pointer pattern is still technically unsound — if the actor's deinit runs (releasing the last reference) before the Task enters the actor, the `takeUnretainedValue()` reference is dangling. In practice, the `Task` holds an actor reference that keeps it alive until the task completes, so this is **theoretically possible but extremely unlikely** in the current code.

**Note on `deinit` double-release:** Verified safe — `releaseCallbackInfoIfNeeded()` in `stop()` sets `self.callbackInfoPointer = nil` before releasing, and `deinit` reads the stored property (which is `nil` if `stop()` ran), so no double-release occurs.

**New finding: `Unmanaged` type mismatch:** `start()` retains via `Unmanaged.passRetained(self as AnyObject)` → `Unmanaged<AnyObject>`, but the callback casts back via `Unmanaged<FSEventsWatcher>.fromOpaque(info)` → `Unmanaged<FSEventsWatcher>`. Different generic types. Works in practice because `self as AnyObject` is identity for Swift actors, but fragile.

---

## 3. Bug B: Detached Progress Tasks Overwrite Correct State

### Claim: Line 824 creates unstructured `Task { @MainActor in ... }`

**Verdict: ✅ Verified**

Lines 823–826:
```swift
let progressCallback: (TrackedPath, ScanService.ScanProgress) -> Void = { trackedPath, progress in
    Task { @MainActor in
        self.applyAggregateScanProgress(for: trackedPath, progress: progress)
    }
}
```

### Claim: Final progress task can execute after `applyInventory` has already set the correct state

**Verdict: ✅ Verified (mechanically possible)**

The progress callback is called from within `createBaselines` (which uses this callback during scanning). When `createBaselines` returns, `loadInventory` immediately calls `applyInventory`. But unstructured `Task {}` created by the last progress callback may not have executed yet — it's scheduled on MainActor but could be queued behind other work.

However, `applyAggregateScanProgress` calls `applyPartialCategoryTotals` which sets `growingCategories = []`, so the stale-data overwrite risk is specifically: progress task sets partial categories without growth stories, then `applyInventory` sets categories with growth stories, then a _later_ progress task overwrites with partial data again. In practice, once `createBaselines` returns, no more progress callbacks should fire. The risk is a **race between the last progress callback's Task and `applyInventory`**.

**Revised assessment:** The race is real but the window is very narrow — it requires a progress callback to fire at the exact moment `createBaselines` returns and for its Task to be scheduled after `applyInventory`.

---

## 4. Bug C: `force: true` Bypasses Mutual Exclusion

### Claim: `acceptGrowth()` calls `loadInventoryFromLatestSnapshot(force: true)` at line 1064–1067

**Verdict: ✅ Verified**

Lines 1064–1067:
```swift
await loadInventoryFromLatestSnapshot(
    refreshedAt: Date(),
    invalidateSubcategoryCache: true,
    force: true
)
```

### Claim: `force: true` sets `isInventoryRefreshInProgress = true` unconditionally instead of using `beginInventoryRefresh()`

**Verdict: ✅ Verified**

Lines 988–990:
```swift
if force {
    isInventoryRefreshInProgress = true
} else {
    guard beginInventoryRefresh() else { return }
}
```

`beginInventoryRefresh()` (line 2692) guards with `!isInventoryRefreshInProgress` — the `force: true` path skips this guard.

### Claim: The `acceptGrowth` function does NOT check `isInventoryRefreshInProgress` before proceeding

**Verdict: ✅ Verified**

Line 1044: `guard !isLoading, !isAutoScanning, !isCheckingGrowth else { return }`  
— does NOT check `isInventoryRefreshInProgress`.

---

## 5. Platform Pattern Violations

### 5.1 Unstructured Tasks as Default Pattern

### Claim: Progress callbacks use `Task { @MainActor in ... }`

**Verdict: ✅ Verified** — Line 824

### Claim: FSEvents bridge uses `Task { await watcher.emitChangeBatch(...) }`

**Verdict: ✅ Verified** — FSEventsWatcher.swift lines 120–122

### Claim: Subcategory preload uses `Task { @MainActor in ... }`

**Verdict: ⚠️ Line number slightly off**

The doc says line 1406. Actual code is at line 1211 in `preloadSubcategoryBreakdowns`. The pattern is confirmed:
```swift
Task { @MainActor in
    _ = await loadSubcategoryBreakdown(for: category)
}
```

### Claim: Silent reconciliation uses `reconciliationTask = Task { @MainActor in ... }`

**Verdict: ⚠️ Line number slightly off**

The doc says line 1118. Actual code is at line 1134:
```swift
reconciliationTask = Task { @MainActor in
    await performSilentReconciliation()
}
```

### Claim: No cancellation propagation from scan stop to pending progress tasks

**Verdict: ✅ Verified**

The progress callback creates fire-and-forget `Task {}` with no reference stored. There is no mechanism to cancel these tasks when a scan stops. Apple's Swift Programming Language book documents `TaskGroup` and structured concurrency as the recommended pattern for cancellation propagation.

### Claim: Apple recommends structured concurrency (TaskGroup, AsyncStream, cancellation handlers)

**Verdict: ✅ Verified against Apple docs**

From Apple's Swift Programming Language (Concurrency chapter):
- `TaskGroup` provides structured concurrency with automatic cancellation propagation
- `withTaskCancellationHandler` provides immediate cleanup on cancellation
- Unstructured `Task.init` "creates an unstructured task that runs similarly to the surrounding code" — no parent-child cancellation relationship

From Apple's Swift Migration Guide (`DataRaceSafety.md`):
> "Because the current isolation domain is freed up to perform other work, actor-isolated state may change after an asynchronous call."

### 5.2 Critical Section Atomicity Not Enforced

### Claim: Quote from Apple's Migration Guide about critical sections

**Verdict: ✅ Exact match against Apple docs**

The exact quote from `swiftlang/swift-migration-guide/Guide.docc/DataRaceSafety.md`:

> "Because the current isolation domain is freed up to perform other work, actor-isolated state may change after an asynchronous call. As a consequence, you can think of explicitly marking potential suspension points as a way to indicate the end of a critical section."

And:

> "While actors do guarantee safety from data races, they do not ensure atomicity across suspension points."

### Claim: `loadInventory()` has 9 `await` suspension points

**Verdict: ⚠️ Off by one — there are 8, not 9**

Counted `await` statements in `loadInventory()` (lines 772–970):
1. `await armFileWatcherBeforeFullScanIfNeeded(for: enabledPaths)` — line 831
2. `try await createBaselines(...)` — line 834
3. `try? await Task.sleep(for: .milliseconds(120))` — line 842
4. `await baselineService.getInventoryWithTrends(...)` — line 852
5. `await baselineService.getDiskAccounting(...)` — line 862
6. `try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))` — line 906
7. `await DatabaseCleanupService.shared.performAutoCleanup()` — line 919
8. `await growthJournalService.prune(...)` — line 920

**8 await points, not 9.** The claim is directionally correct but the count is wrong.

### Claim: Between each await, detached Tasks or FSEvents callbacks can modify `growingCategories`/`stableCategories`

**Verdict: ✅ Verified (mechanically correct per Apple docs)**

Since `MenuBarManager` is `@MainActor`, each `await` is a suspension point where the MainActor executor can process other work (including fire-and-forget `Task {}` blocks). Per Apple's migration guide, this is the end of a critical section — actor-isolated state can change.

### 5.3 FSEvents Coalescing vs Debouncing Confusion

### Claim: FSEvents `latency` parameter is coalescing, not debouncing

**Verdict: ✅ Verified against Apple FSEvents.h**

From `/Applications/Xcode.app/.../FSEvents.h`:
> "Clients can supply a 'latency' parameter that tells how long to wait after an event occurs before forwarding it; this reduces the volume of events and reduces the chance that the client will see an 'intermediate' state"

This is **coalescing** — batch events over a window. Debouncing resets the timer on each event, delaying delivery until a quiet period.

### Claim: Code applies both — FSEvents coalesces at 1.0s, then `scheduleRecentChangeRefreshTask` debounces at 1.5s

**Verdict: ✅ Verified**

- FSEventsWatcher init (line 2461): `FSEventsWatcher(pathsToWatch: urls, debounceInterval: 1.0)` → passed as `latency` to `FSEventStreamCreate` (line 132)
- `normalRecentChangeDebounce` (line 466): `1.5` seconds
- `scheduleRecentChangeRefreshTask` (line 2682): cancels previous task, sleeps for `delay`, then refreshes — this is **debouncing** (reset timer on each event)

Effective worst-case: 1.0s (FSEvents coalescing) + 1.5s (app-level debounce) = 2.5s. ✅

### Claim: Variable naming (`debounceInterval` for the FSEvents latency parameter) illustrates the confusion

**Verdict: ✅ Verified**

FSEventsWatcher.swift line 29: `private let debounceInterval: TimeInterval` — this is passed to `FSEventStreamCreate` as the `latency` parameter (line 132). The name "debounceInterval" is misleading since FSEvents latency is coalescing behavior.

### Claim: Stream created WITHOUT `kFSEventStreamCreateFlagNoDefer`

**Verdict: ✅ Verified**

Lines 83–85:
```swift
let flags = FSEventStreamCreateFlags(
    kFSEventStreamCreateFlagFileEvents |
    kFSEventStreamCreateFlagWatchRoot
)
```

`kFSEventStreamCreateFlagNoDefer` is NOT included.

### Claim: Without `NoDefer`, the first event after a quiet period is delayed by the full latency

**Verdict: ✅ Verified against Apple FSEvents.h**

From the header:
> "If you do not specify this flag, then when an event occurs after a period of no events, the latency timer is started. Any events that occur during the next latency seconds will be delivered as one group (including that first event)."

This confirms the doc's claim: the default (deferred) mode delays the first event by the full latency, unlike `NoDefer` which delivers the first event immediately.

### 5.4 Missing FSEventStreamFlush

### Claim: Prunr never calls `FSEventStreamFlushSync` or `FSEventStreamFlushAsync`

**Verdict: ✅ Verified**

Project-wide grep for `FlushSync`, `FlushAsync`, `FSEventStreamFlush` returns zero results.

### Claim: Apple documents `FSEventStreamFlushSync` as a way to force immediate delivery of pending events

**Verdict: ✅ Verified against Apple FSEvents.h**

> "FSEventStreamFlushSync() -> Requests that the fseventsd daemon send any events it has already buffered (via the latency parameter to one of the FSEventStreamCreate...() functions). Then runs the runloop in its private mode till all events that have occurred have been reported (via the clients callback). This occurs synchronously."

---

## 6. Architecture Observations

### 6.1 MenuBarManager is a 2740-line God Object

**Verdict: ✅ Verified (actually 2738 lines)**

```bash
wc -l MenuBarManager.swift → 2738
```

The doc says 2740 — off by 2 lines, likely due to edits since the count.

### 6.2 Two-Array Split Should Be Computed, Not Stored

**Verdict: ✅ Verified — pattern is confirmed**

Lines 108–109: `var growingCategories` and `var stableCategories` are stored properties.  
Lines 1814–1815: `normalizeVisibleInventoryState` re-partitions:  
```swift
growingCategories = sorted.filter { $0.recentGrowthStory != nil }
stableCategories = sorted.filter { $0.recentGrowthStory == nil }
```

These could indeed be computed from a single `allCategories` array.

### 6.3 GRDB ValueObservation Could Replace the Manual Reactive Pipeline

### Claim: ValueObservation can deliver consistent snapshots on MainActor

**Verdict: ✅ Verified against GRDB docs**

From GRDB's `ValueObservation.md` documentation:
```swift
let cancellable = observation.start(in: dbQueue) { error in
    // This closure is MainActor-isolated.
} onChange: { value in
    // This closure is MainActor-isolated.
}
```

And: "By default, ValueObservation notifies the initial value, as well as eventual changes and errors, on the main actor, asynchronously."

### Claim: The reason ValueObservation wasn't used is that it fires on every write

**Verdict: ✅ Verified against GRDB docs**

GRDB docs state: "ValueObservation tracks changes in the results of database requests, and notifies fresh values whenever the database changes." And: "ValueObservation may coalesce subsequent changes into a single notification."

During a full scan with thousands of batch writes, this could overwhelm the UI. The doc's analysis of observing only `workingSetCategoryTotal` (less frequent changes) as an alternative is sound.

### 6.4 DB Reads Can See Inconsistent Snapshots

### Claim: `loadInventoryFromLatestSnapshot` performs two separate `await`-based reads that can see different snapshots

**Verdict: ✅ Verified**

Lines 1007 and 1024:
```swift
let aggregation = await baselineService.getInventoryWithTrends(trackedPaths: enabledPaths)
// ← write could commit here
reconciliationResult = await baselineService.getDiskAccounting(trackedPaths: enabledPaths, ...)
```

### Claim: GRDB's DatabasePool uses WAL mode where each read sees a consistent snapshot, but different reads can see different snapshots if a write commits between them

**Verdict: ✅ Verified against GRDB docs**

From GRDB's `DatabasePool.md`: "Unless Configuration.readonly, the database is set to the WAL mode. The WAL mode makes it possible for reads and writes to proceed concurrently."

And: "A DatabasePool can take snapshots of the database: see DatabaseSnapshot and DatabaseSnapshotPool." — `makeSnapshot()` exists specifically to provide frozen point-in-time views across multiple reads.

### 6.5 @Observable Granularity

### Claim: `applyPartialCategoryTotals` fires every ~2s, setting `stableCategories` to a new array, triggering observation even if content is identical

**Verdict: ✅ Verified (directionally correct)**

With `@Observable`, setting a stored property always marks it as changed. SwiftUI views reading `stableCategories` will re-render whenever the property is set, regardless of content equality. The `@Observable` macro tracks property _access_ and _mutation_, not content diffing.

### Claim: `partialScanCategoryTotalsByPathID` should be marked `@ObservationIgnored`

**Verdict: ⚠️ Already `private` — may not need it**

Line 375: `private var partialScanCategoryTotalsByPathID: [UUID: [GrowthCategory: Int64]] = [:]`

Since `@Observable` only triggers observation when SwiftUI views _access_ the property, and `private` properties can't be accessed from SwiftUI views directly, this is already effectively observation-ignored. However, if any computed property accessed by a view reads this dictionary, it would still be tracked. The recommendation is sound as a defensive measure.

---

## 7. Dead Code

### Claim: `recalculateAllCategoryTotals()` at line 1931 and `recalculateAffectedCategoryTotals()` at line 1977 are never called

**Verdict: ✅ Verified**

- Line numbers match exactly (1931 and 1977)
- Both are `private` functions in `DatabaseManager.swift`
- Project-wide grep outside `DatabaseManager.swift` returns zero results
- No call within `DatabaseManager.swift` itself (grep confirms only the function definitions match)

---

## 8. Summary of Discrepancies

| Item | Doc Claim | Actual | Verdict |
|------|-----------|--------|---------|
| `loadInventory` await count | 9 | 8 | ⚠️ Off by 1 |
| MenuBarManager line count | 2740 | 2738 | ⚠️ Off by 2 |
| Subcategory preload line | 1406 | 1211 | ⚠️ Wrong line |
| Reconciliation task line | 1118 | 1134 | ⚠️ Wrong line |
| FSEvents UAF crash severity | "Real crash risk" | Mitigated by actor isolation + `isRunning` guard | ⚠️ Overstated |
| All other factual claims | — | — | ✅ Verified |

**No claims were found to be fundamentally wrong.** The line numbers drifted due to edits, and the FSEvents use-after-free is less severe than stated because actor serialization provides an additional safety net. Every pattern, Apple doc quote, GRDB claim, and code behavior description is substantiated.
