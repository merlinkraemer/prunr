# Prunr Architecture Review: Platform Patterns Audit

**Date:** 2026-04-08  
**Scope:** Every pattern used in the codebase audited against Apple documentation (Swift Concurrency, SwiftUI @Observable, FSEvents), GRDB documentation, and macOS filesystem semantics.

---

## Table of Contents

1. [Swift Concurrency: MainActor & Task Ordering](#1)
2. [Swift Concurrency: Actor Reentrancy](#2)
3. [Swift Concurrency: Unstructured Task Lifecycle](#3)
4. [SwiftUI @Observable: Observation Granularity](#4)
5. [FSEvents: Platform Behavior & Misuse](#5)
6. [GRDB: Connection Pool Semantics](#6)
7. [GRDB: Missed Reactive Pattern (ValueObservation)](#7)
8. [macOS File System Semantics](#8)
9. [Pattern Violation Summary](#9)

---

<a id="1"></a>
## 1. Swift Concurrency: MainActor & Task Ordering

### What the docs say

From the Swift Concurrency Migration Guide:

> **"Because the current isolation domain is freed up to perform other work, actor-isolated state may change after an asynchronous call. As a consequence, you can think of explicitly marking potential suspension points as a way to indicate the end of a critical section."**

> **"While actors do guarantee safety from data races, they do not ensure atomicity across suspension points."**

From the Swift documentation on `Task`:

> `Task { @MainActor in ... }` creates an **unstructured task** that inherits the MainActor isolation of the enclosing scope. This task is enqueued on the MainActor executor and runs at an **indeterminate future time**. It does **not** block the caller and there is **no ordering guarantee** between when it is created and when the current function's next statement runs.

### What Prunr does

In `loadInventory()` (line 824):

```swift
let progressCallback: (TrackedPath, ScanService.ScanProgress) -> Void = { trackedPath, progress in
    Task { @MainActor in
        self.applyAggregateScanProgress(for: trackedPath, progress: progress)
    }
}
```

**Every progress update creates an unstructured task.** The caller (ScanService, running on its own actor) invokes this callback synchronously, but the `Task { @MainActor }` wrapper means the actual UI update runs later.

### The violation

This is not technically incorrect — the code does not crash and has no data races. But it violates the **critical section** pattern that Apple recommends. Between `await createBaselines(...)` returning and the progress task executing, the MainActor executor could process the progress task in any order relative to the continuation of `loadInventory`.

**Apple's recommended pattern:** If you need ordered delivery of progress updates to a MainActor-isolated type, use:
- An `AsyncStream` that the producer writes to and the consumer iterates on MainActor
- A synchronous callback that hops to MainActor via `MainActor.run` (structured)
- `AsyncChannel` from Swift Async Algorithms

**The current pattern is equivalent to** `DispatchQueue.main.async { ... }` — which is exactly what Swift concurrency was designed to replace with structured patterns.

### Concrete risk

The final progress callback's `Task { @MainActor }` can execute **after** `applyInventory` has already set the correct state. This overwrites correct categories with partial scan data (missing growth stories). Not a bloat bug, but a **visual flicker** where growth stories briefly disappear then reappear on the next refresh.

---

<a id="2"></a>
## 2. Swift Concurrency: Actor Reentrancy

### What the docs say

From the Swift Migration Guide, the "Atomicity" section:

> **"Concurrent code often needs to execute a sequence of operations together as an atomic unit, such that other threads can never see an intermediate state. Units of code that require this property are known as critical sections."**

> **"You can think of explicitly marking potential suspension points as a way to indicate the end of a critical section."**

### What Prunr does

`MenuBarManager` is `@MainActor` (not an actor). Since it's `@MainActor`, all its methods run on the main actor executor. But `@MainActor` classes have the **same reentrancy semantics as actors** — between `await` suspension points, other MainActor work can run.

The critical section pattern is violated in `loadInventory()`:

```swift
func loadInventory(...) async {
    guard beginInventoryRefresh() else { return }
    defer { endInventoryRefresh() }
    
    // ... setup ...
    
    completedSnapshotsByPath = try await createBaselines(...)  // ← SUSPENSION POINT
    // At this point, a detached progress Task could run and modify growingCategories/stableCategories
    
    // ... more setup ...
    
    let aggregation = await baselineService.getInventoryWithTrends(...)  // ← SUSPENSION POINT
    
    applyInventory(...)  // Sets growingCategories + stableCategories + normalizeVisibleInventoryState()
    
    // ... more awaits ...
    await DatabaseCleanupService.shared.performAutoCleanup()  // ← SUSPENSION POINT
}
```

**Between each `await`, other MainActor work can interleave.** The `beginInventoryRefresh`/`endInventoryRefresh` gate prevents other inventory loads from starting, but it does NOT prevent:
- Detached progress Tasks from running
- FSEvents callbacks from firing (they're scheduled on the main dispatch queue via `DispatchQueue.main`)
- Timer callbacks from firing

### Apple's recommended pattern

Wrap critical state mutations in **synchronous blocks** — no suspension points between reading state, mutating it, and publishing. Prunr does this correctly within `applyInventory` (synchronous), but the broader flow has many interleaving windows.

### Assessment

The interleaving is **harmless for correctness** because `applyPartialCategoryTotals` now clears `growingCategories = []`. But it's a **fragile pattern** — any future code that reads `growingCategories` between suspension points could see stale or partial data. The codebase has no comments or assertions documenting the reentrancy invariants.

---

<a id="3"></a>
## 3. Swift Concurrency: Unstructured Task Lifecycle

### What the docs say

From the Swift Migration Guide on `Task.init`:

> **"This newly-created task will inherit the MainActor isolation of its enclosing scope unless an explicit global actor is written."**

Unstructured tasks (`Task { ... }`) have no parent-child relationship. They are not cancelled when the creating scope ends. They are not awaited. They run to completion independently.

### What Prunr does

In `loadInventory`, the progress callback creates unstructured tasks. If the user cancels a scan (`stopScan()`), the scan stops, `loadInventory` finishes, but **the detached progress tasks continue running**. There is no cancellation propagation.

In `recordFileWatcherChangeBatch` (line 2490):
```swift
Task { @MainActor in
    await self.emitChangeBatch(changedPaths, requiresFullRescan: requiresFullRescan)
}
```

Inside `FSEventsWatcher`, the C callback creates an unstructured `Task { }` to call back into the actor. These tasks have no cancellation mechanism.

### The violation

**Unstructured tasks should be the exception, not the default.** Apple's structured concurrency model provides `TaskGroup`, `AsyncStream`, and `withTaskCancellationHandler` for managing task lifecycles. Prunr uses `Task { }` as its primary concurrency mechanism.

This means:
1. Scan cancellation doesn't stop pending progress updates
2. There's no way to drain pending progress tasks before `applyInventory` runs
3. Memory leaks are possible if many tasks queue up during a long scan

---

<a id="4"></a>
## 4. SwiftUI @Observable: Observation Granularity

### What the docs say

From Apple's @Observable documentation:

> **"In SwiftUI, a view forms a dependency on an observable data model object when the view's body property reads a property of the object. If body doesn't read any properties of an observable data model object, the view doesn't track any dependencies."**

> **"SwiftUI updates a view only when an observable property changes and the view's body reads the property directly; the view doesn't update when observable properties not read by body change."**

### What Prunr does

`MenuBarManager` is `@Observable`. Every stored property mutation triggers SwiftUI's observation system. The view reads:

```swift
// DriveBarView reads:
manager.growingCategories + manager.stableCategories
manager.totalBytes, manager.usedBytes, manager.freeBytes

// CategoryGrowthListView reads:
manager.growingCategories
manager.stableCategories

// MenuBarView body reads:
manager.isLoading, manager.isAutoScanning, manager.isAutoScanning,
manager.noBaseline, manager.scanProgressPercentage, manager.filesScanned,
manager.growingCategories, manager.stableCategories, manager.totalBytes, ...
```

### The pattern violation

`applyPartialCategoryTotals` fires every ~2 seconds during a scan. Each call mutates `growingCategories`, `stableCategories`, and `stableTotalBytes` — three separate property changes. SwiftUI batches these within the same run loop tick, but each batch still triggers a full re-render of any view that reads these properties.

More importantly, `applyPartialCategoryTotals` creates a **new array** for `stableCategories` on every call:

```swift
stableCategories = liveCategories  // New array every ~2 seconds
```

With @Observable, setting a property to a **new value** always triggers observation, even if the content is identical. This means SwiftUI re-renders the entire category list every 2 seconds during a scan, even if the partial totals haven't changed significantly.

### Apple's recommended pattern

For high-frequency updates, Apple recommends:
- Using `@ObservationIgnored` for properties that change frequently but don't need to drive renders
- Batching mutations within a single synchronous scope (SwiftUI coalesces)
- Computing derived values lazily instead of eagerly

The current `normalizeVisibleInventoryState` does the opposite — it eagerly recomputes derived state after every mutation.

---

<a id="5"></a>
## 5. FSEvents: Platform Behavior & Misuse

### What Apple's documentation says

From the FSEvents Programming Guide and API reference:

> **"The file system events API provides a way for your application to ask for notification when the contents of a directory hierarchy are modified."**

Key FSEvents behaviors documented by Apple:

1. **Coalescing**: The `latency` parameter tells the system how long to wait before delivering events. Events that occur within this window are coalesced into a single callback. This is a **latency** parameter, not a **debounce**.

2. **Historical events**: FSEvents maintains a persistent event log. Starting a stream with `kFSEventStreamEventIdSinceNow` only receives events from this point forward. Starting with a specific event ID replays historical events.

3. **kFSEventStreamEventFlagMustScanSubDirs**: When this flag is set, the event path is a **hint**, not a guarantee. The application MUST scan the entire subtree to find what changed.

4. **kFSEventStreamEventFlagKernelDropped / kFSEventStreamEventFlagUserDropped**: These indicate the kernel's event buffer overflowed. The app MUST do a full rescan.

5. **kFSEventStreamEventFlagRootChanged**: The watched root directory was renamed or moved. The stream may become invalid.

6. **Callback threading**: The callback fires on the run loop or dispatch queue the stream is scheduled on.

### What Prunr does right

- Uses `kFSEventStreamCreateFlagFileEvents` for file-level granularity ✅
- Uses `kFSEventStreamCreateFlagWatchRoot` for root change detection ✅
- Checks `kFSEventStreamEventFlagMustScanSubDirs` + dropped flags → `requiresFullRescan` ✅
- Uses `kFSEventStreamEventIdSinceNow` to avoid replaying history ✅

### What Prunr does wrong

#### 5a. Scheduling on DispatchQueue.main inside an Actor

```swift
// In FSEventsWatcher.start():
if #available(macOS 13.0, *) {
    FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
}
```

`FSEventsWatcher` is an `actor`. But the FSEventStream callback is scheduled on `DispatchQueue.main`. The C callback then does:

```swift
Task {
    await watcher.emitChangeBatch(changedPaths, requiresFullRescan: requiresFullRescan)
}
```

This creates an **unstructured task** from a C callback context to hop into the actor. Apple's documentation for FSEventStream doesn't mention Swift concurrency at all — the API predates it by 15 years. The correct pattern for bridging C callbacks to Swift concurrency is to use `withCheckedContinuation` or a `AsyncStream`.

**The risk**: The `Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()` in the C callback captures a **non-Sendable** reference across a concurrency boundary. If the watcher is deallocated between the C callback firing and the Task executing, this is a **use-after-free**. The `takeUnretainedValue()` means the reference count is NOT incremented for the callback.

#### 5b. "Debounce" terminology mismatch

The codebase uses "debounce" (in `debounceInterval`, `scheduleRecentChangeRefreshTask`) but FSEvents' latency parameter is **coalescing**, not debouncing. The difference:

- **Coalesce**: "Deliver all events from the last N seconds in one batch" (what FSEvents does)
- **Debounce**: "Reset a timer on each event; only fire when the timer expires" (what `scheduleRecentChangeRefreshTask` does)

The code applies BOTH — FSEvents coalesces at 1.0s, then `recordFileWatcherChangeBatch` applies additional debounce via `scheduleRecentChangeRefreshTask(after: 1.5s)`. This means the **effective latency is up to 2.5 seconds** (1.0s FSEvents + 1.5s debounce) before changes reach the DB. This is fine for a disk usage analyzer, but the documentation should be clear about the distinction.

#### 5c. Missing FSEventStreamFlushSync

Apple's documentation states:

> After calling `FSEventStreamFlushSync`, your callback will be called with all events that have occurred since the last time your callback was called (or since the stream started).

Prunr never calls `FSEventStreamFlushSync` or `FSEventStreamFlushAsync`. This means FSEvents events are only delivered according to the latency timer. If the app goes into the background or the main run loop is busy, events may be delayed even longer. For a near-realtime monitoring tool, a periodic flush would ensure timely delivery.

---

<a id="6"></a>
## 6. GRDB: Connection Pool Semantics

### What the GRDB docs say

From `DatabasePool.md`:

> **"Unless readonly, the database is set to WAL mode. The WAL mode makes it possible for reads and writes to proceed concurrently."**

> **"All write accesses are executed in a serial writer dispatch queue."**

> **"All read accesses are executed in reader dispatch queues. Reads are generally non-blocking, unless the maximum number of concurrent reads has been reached."**

From the Concurrency guide:

> **"Reads are isolated, preventing them from seeing changes made by other threads. This allows two concurrent reads to potentially observe different database states."**

### What Prunr does

Prunr uses `DatabasePool` correctly for basic operations. But there's a subtle issue with **snapshot isolation across reads**.

In `loadInventoryFromLatestSnapshot`:
```swift
let aggregation = await baselineService.getInventoryWithTrends(trackedPaths: enabledPaths)
// ... suspension point ...
reconciliationResult = await baselineService.getDiskAccounting(...)
```

Two separate `read` calls on the DatabasePool. Between them, a write could commit. The second read sees a **different snapshot** than the first. This means `reconciliationResult` could be computed from a different database state than the category inventory.

**Is this a bug?** For Prunr's use case — showing approximate disk usage — a minor inconsistency between the category totals and the disk accounting is acceptable. But it violates the principle of reading related data from a single consistent snapshot.

**GRDB's recommended pattern:** Use `dbPool.read { db in ... }` to perform multiple queries within a single read transaction, guaranteeing they see the same snapshot. Or use `dbPool.makeSnapshot()` for a frozen point-in-time view.

### Assessment

Low severity for Prunr's use case, but the pattern is worth noting. A `makeSnapshot()` call at the start of `loadInventoryFromLatestSnapshot` would guarantee both `getInventoryWithTrends` and `getDiskAccounting` read from the same state.

---

<a id="7"></a>
## 7. GRDB: Missed Reactive Pattern (ValueObservation)

### What GRDB provides

GRDB's `ValueObservation` provides **automatic, incremental, reactive** database change notification:

```swift
let observation = ValueObservation.tracking { db in
    try CategoryInventoryItem.fetchAll(db)
}

let cancellable = observation.start(
    in: dbPool,
    scheduling: .mainActor
) { error in
    print("Error: \(error)")
} onChange: { items in
    // Automatically called on MainActor whenever DB changes
    self.categories = items
}
```

### What Prunr does instead

Prunr implements its own reactive pipeline:
1. FSEvents detects file changes → writes to DB via `RecentChangeService`
2. Manual scheduling via `scheduleRecentChangeRefreshTask(after:)` debounces the refresh
3. `performRecentChangeRefresh` reads from DB and calls `applyInventory`
4. `applyInventory` manually sets `growingCategories` and `stableCategories`

### The missed opportunity

`ValueObservation` with `scheduling: .mainActor` would:
- Automatically detect when `workingSetCategoryTotal` or `workingSetEntry` rows change
- Deliver only the changed values to MainActor
- Eliminate the entire `scheduleRecentChangeRefreshTask` debounce machinery
- Eliminate the `normalizeVisibleInventoryState` merge problem (the observation always returns a complete, consistent snapshot)
- Eliminate the `force: true` exclusion bypass issue

### Why Prunr might have avoided it

`ValueObservation` triggers on **any** write to the observed tables. During a full scan, there are thousands of writes per second to `workingSetEntry` and `workingSetCategoryTotal`. Each would trigger a re-observation, potentially overwhelming the UI. Prunr's manual debounce at 1.5s is effectively rate-limiting.

But `ValueObservation` supports **regions** — you can observe specific subsets of the database. And the observation only fires when the **result** of the tracking closure changes, not on every write. For category totals, which change infrequently relative to entry-level writes, this could be efficient.

### Assessment

This is an **architectural recommendation**, not a bug. The current manual pipeline works but reimplements what GRDB already provides. If Prunr ever refactors, `ValueObservation` tracking `workingSetCategoryTotal` with `.mainActor` scheduling would simplify the entire reactive layer.

---

<a id="8"></a>
## 8. macOS File System Semantics

### APFS snapshots and FSEvents

macOS uses APFS, which has Copy-on-Write (COW) semantics. When a file is modified:
1. APFS writes new blocks
2. The old blocks are freed
3. FSEvents fires after the write completes

FSEvents does NOT fire during a write — only after. This means the events are always consistent with the on-disk state. However, FSEvents can report events **out of order** relative to the actual file system operations, especially under heavy I/O load.

### Spotlight metadata

macOS's Spotlight indexer (`mds`/`mdworker`) generates FSEvents as it indexes. This means Prunr's FSEventsWatcher receives events from Spotlight's own writes, creating a feedback loop:

1. User creates a file
2. FSEvents fires → Prunr processes the change
3. Spotlight indexes the file → writes metadata → FSEvents fires again
4. Prunr processes the "change" (which is just Spotlight metadata)

Prunr partially handles this via `FSEventsNoiseFilter`, but the noise filter is based on path patterns, not on the identity of the writing process. There's no way to distinguish "user changed a file" from "Spotlight indexed a file" using FSEvents alone.

**Apple's recommended pattern for avoiding Spotlight noise**: Use `FSEventStreamSetExclusionPaths` (available macOS 10.13+) to exclude paths from Spotlight indexing. Or use the `mdfind` API for metadata queries instead of file monitoring.

### Sandbox and Full Disk Access

Prunr requires Full Disk Access to scan protected locations (Desktop, Documents, Downloads). This is correct per Apple's privacy requirements. But FSEvents delivers events even for paths the app can't read — the event just contains the path, not the content. The app then tries to `lstat` the path, which fails with EPERM. This generates the `runtimeBlockedLocations` entries.

**Apple's recommended pattern**: Check `NSURL.isReadable` or use `FileManager.fileExists(atPath:)` before attempting to read, and silently skip inaccessible paths rather than surfacing them as errors.

---

<a id="9"></a>
## 9. Pattern Violation Summary

| Pattern | Apple/GRDB Recommendation | Prunr Implementation | Severity |
|---|---|---|---|
| Progress callbacks | Structured: `AsyncStream` or synchronous callback on MainActor | `Task { @MainActor }` — unstructured, unordered | 🟡 Medium |
| Critical section atomicity | Synchronous blocks between state read/mutate/publish | Multiple `await` points between mutations | 🟡 Medium |
| Task lifecycle | Structured: `TaskGroup`, cancellation propagation | Unstructured `Task { }` everywhere | 🟠 Medium-High |
| FSEvents bridge to Swift Concurrency | `AsyncStream` or `withCheckedContinuation` | `Unmanaged.takeUnretainedValue()` + `Task { }` (use-after-free risk) | 🔴 High |
| Reactive DB updates | `ValueObservation` with `.mainActor` scheduling | Manual debounce pipeline with mutable state | 🟡 Medium |
| DB snapshot consistency | Single `read { }` block or `makeSnapshot()` | Multiple separate reads that can see different states | 🟢 Low |
| @Observable granularity | Lazy computed properties, `@ObservationIgnored` for high-frequency | Eager recompute on every mutation | 🟢 Low |
| FSEvents terminology | Coalescing (not debouncing) | "Debounce" used for both FSEvents latency and task scheduling | 🟢 Low |
| Spotlight noise | Exclusion paths or process filtering | Path-based noise filter only | 🟢 Low |

### Top 3 actionable fixes by impact

1. **Fix the FSEvents use-after-free** (`Unmanaged.takeUnretainedValue()` → `takeRetainedValue()` or use `AsyncStream`). This is a real crash risk if the watcher is stopped while events are in-flight.

2. **Replace progress callback `Task { @MainActor }` with `AsyncStream`**. This gives ordered delivery, cancellation propagation, and eliminates the stale-data-overwrite risk.

3. **Add `@ObservationIgnored` to `partialScanCategoryTotalsByPathID` and internal bookkeeping**. These change frequently during scans but don't drive renders. Marking them as ignored reduces SwiftUI re-render frequency.

---

*End of platform patterns audit.*
