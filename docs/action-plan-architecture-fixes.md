# Architecture Fixes — Atomic Action Plan

**Source:** `architecture-review-final-findings.md`  
**Date:** 2026-04-08  
**Status:** Ready to execute

Each phase is a self-contained unit: implement → test in simulator → test on device → verify monitoring → commit. Do not proceed to the next phase until the current one passes all checks.

---

## Phase 0: Monitoring & Testing Infrastructure (Do First)

Set up observability so every subsequent phase can be verified in real time.

### Step 0.1 — Add `os_log` / `Logger` subsystem

- [ ] Create `Prunr/Extensions/Logger+Prunr.swift` with categorized loggers:
  ```swift
  import os

  extension Logger {
      static let inventory  = Logger(subsystem: "com.prunr.app", category: "Inventory")
      static let fsEvents   = Logger(subsystem: "com.prunr.app", category: "FSEvents")
      static let scan       = Logger(subsystem: "com.prunr.app", category: "Scan")
      static let state      = Logger(subsystem: "com.prunr.app", category: "StateMerge")
      static let progress   = Logger(subsystem: "com.prunr.app", category: "Progress")
      static let reconciler = Logger(subsystem: "com.prunr.app", category: "Reconciliation")
  }
  ```
- [ ] Build & verify: no compilation errors.

**Test:** Build the project. Run in Xcode. Open Console.app → filter by `com.prunr.app`. Confirm loggers appear.

### Step 0.2 — Instrument `normalizeVisibleInventoryState`

- [ ] In `MenuBarManager.swift` at `normalizeVisibleInventoryState()` (~line 1791), add logging:
  ```swift
  let allItems = growingCategories + stableCategories
  let categoryCounts = Dictionary(allItems.map(\.category), grouping: { $0 })
  let duplicates = categoryCounts.filter { $0.value.count > 1 }
  if !duplicates.isEmpty {
      Logger.state.error("DUPLICATE CATEGORIES detected: \(duplicates.keys) — growing=\(growingCategories.map(\.category)) stable=\(stableCategories.map(\.category))")
  }
  Logger.state.info("normalize: growing=\(growingCategories.count) stable=\(stableCategories.count) total=\(allItems.reduce(0) { $0 + $1.currentSizeBytes }) bytes")
  ```
- [ ] Build.

**Test:**  
1. Run the app.  
2. Trigger a full scan of a test directory (~500+ files).  
3. Monitor Console.app for `StateMerge` logs.  
4. Verify no `DUPLICATE CATEGORIES` messages appear during or after scan.  
5. Verify `normalize` is called and logs the expected count.  
6. Verify the category sizes shown in the UI match the logged totals.

### Step 0.3 — Instrument `applyPartialCategoryTotals`

- [ ] Add logging at the top of `applyPartialCategoryTotals`:
  ```swift
  Logger.progress.info("applyPartial: path=\(trackedPath.id) categories=\(totals.count) totals=\(totals)")
  ```
- [ ] Add logging at the end:
  ```swift
  Logger.progress.info("applyPartial done: growing=\(growingCategories.count) stable=\(stableCategories.count)")
  ```

**Test:**  
1. Run app. Start a scan.  
2. Watch Console.app for `Progress` logs every ~2 seconds.  
3. Confirm `growing=0` after each `applyPartial` (the fix guarantees `growingCategories = []`).  
4. Confirm UI categories update smoothly during scan.

### Step 0.4 — Instrument FSEvents callback chain

- [ ] In `FSEventsWatcher.swift`, add to the C callback (before the `Task`):
  ```swift
  Logger.fsEvents.debug("FSEvents callback: \(numEvents) events, fullRescan=\(requiresFullRescan)")
  ```
- [ ] In `emitChangeBatch`, add:
  ```swift
  Logger.fsEvents.info("emitChangeBatch: \(paths.count) paths, running=\(isRunning)")
  ```

**Test:**  
1. Run app. Let it monitor a directory.  
2. In Terminal: `touch /path/to/watched/test.txt && rm /path/to/watched/test.txt`  
3. Watch Console.app for `FSEvents` logs.  
4. Confirm events arrive within ~1s (coalescing window).  
5. Confirm `emitChangeBatch` logs `running=true`.  
6. Confirm UI refreshes after ~2.5s (coalescing + debounce).

### Step 0.5 — Create a manual test checklist script

- [ ] Write `docs/test-checklist.md` with the following manual test scenarios:
  1. Fresh launch → first scan of empty directory
  2. Fresh launch → first scan of large directory (~10k files)
  3. App running → add 100 files to watched directory → wait for FSEvents refresh
  4. App running → delete 50 files → wait for refresh
  5. App running → start manual scan → cancel mid-scan
  6. App running → accept growth → verify categories update
  7. App running → background the app → foreground → verify state is consistent
  8. App running → trigger two scans rapidly back-to-back
- [ ] Execute all 8 scenarios while monitoring Console.app logs.

**Commit:** `chore: add logging infrastructure and test checklist for architecture fixes`

---

## Phase 1: P0 — Duplicate-Category Assertion (Bloat Verification)

Confirms the bloat fix is solid or catches any remaining trigger.

### Step 1.1 — Add assertion in `normalizeVisibleInventoryState`

- [ ] Replace the logging from Step 0.2 with a stronger check:
  ```swift
  let allItems = growingCategories + stableCategories
  var seen = Set<GrowthCategory>()
  for item in allItems {
      if seen.contains(item.category) {
          assertionFailure("Duplicate category '\(item.category)' in visible inventory state")
          Logger.state.critical("DUPLICATE: \(item.category) — this should not happen after the bloat fix")
          break
      }
      seen.insert(item.category)
  }
  ```
- [ ] Build with assertions enabled (Debug configuration).

**Test:**  
1. Run the full test checklist from Step 0.5.  
2. The app must NOT hit `assertionFailure` in any scenario.  
3. If it does: do NOT proceed. Document which scenario triggered it and investigate.

**Monitor while running:**  
- Keep Console.app open, filtered to `StateMerge`.  
- Watch for `DUPLICATE` messages — there should be zero.  
- Watch `normalize` call frequency — should only fire at expected state transitions, not continuously.

**Commit:** `fix: add duplicate-category assertion to normalizeVisibleInventoryState`

---

## Phase 2: P1 — Fix FSEvents Unmanaged Pattern (Bug A)

### Step 2.1 — Switch from `passRetained(self as AnyObject)` to `passRetained(self)`

- [ ] In `FSEventsWatcher.swift` line 69, change:
  ```swift
  // Before:
  let contextPtr = Unmanaged.passRetained(self as AnyObject).toOpaque()
  // After:
  let contextPtr = Unmanaged.passRetained(self).toOpaque()
  ```
- [ ] In the C callback (line 95), change:
  ```swift
  // Before:
  let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
  // After:
  let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeRetainedValue()
  ```
- [ ] In `releaseCallbackInfo` (line 216–218), remove the `Unmanaged<AnyObject>.fromOpaque(...).release()` call — `takeRetainedValue()` already consumes the retain in the callback.
- [ ] In `stop()`, remove the `releaseCallbackInfoIfNeeded()` call since the retain is now consumed by the callback's `takeRetainedValue()`. Keep the `callbackInfoPointer = nil` cleanup.
- [ ] Build.

**Test — basic file watching:**  
1. Run app. Point at a test directory.  
2. `touch test1.txt` → verify FSEvents callback fires and UI refreshes.  
3. Delete `test1.txt` → verify refresh.  
4. Create 10 files rapidly → verify single batched callback (coalescing).

**Test — stop/start lifecycle:**  
1. Start watching. Create a file. Wait for callback.  
2. Call `stop()` programmatically (or unmount/unselect the path).  
3. Create more files. Verify NO callbacks fire (log silence).  
4. Call `start()` again. Create files. Verify callbacks resume.  
5. Repeat stop/start cycle 5 times rapidly. No crashes.

**Test — race condition stress test:**  
1. Start watching a busy directory.  
2. Run in Terminal: `for i in $(seq 1 100); do touch /watched/dir/file$i; done`  
3. Immediately (within 1s) call `stop()`.  
4. Watch Console.app — no crashes, no `EXC_BAD_ACCESS`, no use-after-free.  
5. All logged `emitChangeBatch` calls show either `running=true` (executed) or don't appear (guard caught).

**Monitor while running:**  
- Console.app → `FSEvents` category.  
- Every callback should show `emitChangeBatch: N paths, running=true`.  
- After `stop()`, no more `emitChangeBatch` logs.  
- Xcode Debug Navigator — no memory leaks after stop/start cycles.

### Step 2.2 — Rename `debounceInterval` → `coalescingInterval`

- [ ] In `FSEventsWatcher.swift`, rename the property and parameter:
  ```swift
  // Before:
  private let debounceInterval: TimeInterval
  init(pathsToWatch: [URL], debounceInterval: TimeInterval = 1.0)
  
  // After:
  private let coalescingInterval: TimeInterval
  init(pathsToWatch: [URL], coalescingInterval: TimeInterval = 1.0)
  ```
- [ ] Update all references within the file.
- [ ] Update the call site in `MenuBarManager.swift` if it passes a custom interval.
- [ ] Build.

**Test:** Same as Step 2.1 — verify FSEvents still works identically.

**Commit:** `fix: correct FSEventsWatcher Unmanaged lifecycle and rename debounceInterval → coalescingInterval`

---

## Phase 3: P1 — Replace Progress Callback Tasks with AsyncStream (Bug B)

### Step 3.1 — Create an `AsyncStream` for scan progress

- [ ] In `MenuBarManager.swift`, add a progress stream property:
  ```swift
  private var progressContinuation: AsyncStream<ScanProgressEvent>.Continuation?
  private var progressStream: AsyncStream<ScanProgressEvent>!
  
  enum ScanProgressEvent {
      case progress(trackedPath: TrackedPath, progress: ScanService.ScanProgress)
      case scanCompleted
  }
  ```
- [ ] Initialize the stream in `init` or `startMonitoring`:
  ```swift
  let (stream, continuation) = AsyncStream<ScanProgressEvent>.makeStream()
  self.progressStream = stream
  self.progressContinuation = continuation
  ```
- [ ] Start a long-lived `Task` that consumes the stream:
  ```swift
  progressConsumerTask = Task { [weak self] in
      for await event in progressStream {
          guard let self else { return }
          switch event {
          case .progress(let path, let progress):
              self.applyAggregateScanProgress(for: path, progress: progress)
          case .scanCompleted:
              break // terminal event
          }
      }
  }
  ```

### Step 3.2 — Replace the `Task { @MainActor in }` progress callback

- [ ] In the scan progress callback (~line 824), change:
  ```swift
  // Before:
  let progressCallback = { trackedPath, progress in
      Task { @MainActor in
          self.applyAggregateScanProgress(for: trackedPath, progress: progress)
      }
  }
  // After:
  let progressCallback = { [weak self] trackedPath, progress in
      self?.progressContinuation?.yield(.progress(trackedPath: trackedPath, progress: progress))
  }
  ```
- [ ] At the end of `loadInventory()` (after `applyInventory`), yield `.scanCompleted` to flush the stream.
- [ ] Cancel `progressConsumerTask` in `deinit` or when monitoring stops.

**Test — basic scan progress:**  
1. Run app. Start a full scan of a large directory.  
2. Watch Console.app `Progress` logs.  
3. Verify progress updates arrive in order (no out-of-order jumps).  
4. Verify UI progress bar updates smoothly.  
5. Verify final state (after scan completes) is correct — categories with growth stories show indicators.

**Test — scan cancellation:**  
1. Start a scan. Mid-scan, cancel it.  
2. Verify `progressConsumerTask` is cancelled.  
3. Verify no stale progress updates arrive after cancellation.  
4. Verify UI returns to a clean state.

**Test — rapid scan start/stop:**  
1. Start scan → cancel → start scan → cancel → start scan → let complete.  
3. Verify no stale progress from cancelled scans bleeds through.  
4. Verify final inventory state is correct after the last scan.

**Test — growth story flicker (the original bug):**  
1. Start a scan. Wait for categories with growth to appear.  
2. Watch the UI — growth story indicators should NOT flicker off and on.  
3. Monitor Console.app — verify no `applyAggregateScanProgress` calls after `applyInventory` logs.

**Monitor while running:**  
- Console.app → `Progress` category.  
- Verify events are processed sequentially, no interleaving.  
- Xcode Debug Navigator — verify no unbounded stream buffer growth during long scans.

**Commit:** `fix: replace unstructured progress tasks with AsyncStream for ordered delivery`

---

## Phase 4: P2 — Dead Code Cleanup

### Step 4.1 — Delete `recalculateAllCategoryTotals`

- [ ] In `DatabaseManager.swift`, delete lines 1931–1975 (the entire function).
- [ ] Grep entire project for any references: `grep -r "recalculateAllCategoryTotals" Prunr/` — should return zero results.
- [ ] Build.

### Step 4.2 — Delete `recalculateAffectedCategoryTotals`

- [ ] In `DatabaseManager.swift`, delete lines 1977–20xx (the entire function).
- [ ] Grep entire project: `grep -r "recalculateAffectedCategoryTotals" Prunr/` — zero results.
- [ ] Build.

**Test:**  
1. Full build — no compilation errors.  
2. Run all test checklist scenarios from Step 0.5.  
3. No behavior change — this is pure deletion.

**Commit:** `chore: delete dead recalculateAllCategoryTotals and recalculateAffectedCategoryTotals`

---

## Phase 5: P2 — Fix Mutual Exclusion Bypass in `acceptGrowth` (Bug C)

### Step 5.1 — Remove `force: true` from `acceptGrowth`

- [ ] In `MenuBarManager.swift` at `acceptGrowth()` (~line 1064), change:
  ```swift
  // Before:
  await loadInventoryFromLatestSnapshot(
      refreshedAt: Date(),
      invalidateSubcategoryCache: true,
      force: true
  )
  // After:
  await loadInventoryFromLatestSnapshot(
      refreshedAt: Date(),
      invalidateSubcategoryCache: true
  )
  ```
- [ ] Add a guard at the top of `acceptGrowth()`:
  ```swift
  guard !isInventoryRefreshInProgress else {
      Logger.inventory.warning("acceptGrowth skipped — inventory refresh in progress")
      return
  }
  ```
- [ ] Build.

**Test — accept growth normally:**  
1. Run app. Scan directory. Wait for growth to be detected.  
2. Click "Accept Growth".  
3. Verify categories update correctly — growth stories disappear, sizes remain stable.  
4. Verify Console.app shows no "acceptGrowth skipped" warning.

**Test — accept growth during refresh:**  
1. Start a manual scan.  
2. Immediately trigger accept growth (programmatically or via UI).  
3. Verify the guard logs "acceptGrowth skipped".  
4. Verify no crash or inconsistent state.  
5. When scan completes, try accept growth again — should succeed.

**Monitor while running:**  
- Console.app → `Inventory` category.  
- Verify `acceptGrowth` only proceeds when no refresh is in progress.

**Commit:** `fix: remove force:true from acceptGrowth, add mutual exclusion guard`

---

## Phase 6: P3 — Replace Two-Array Split with Single Source of Truth

> **⚠️ This is the largest refactor. Do it on a separate branch.**

### Step 6.1 — Add `allCategories` property

- [ ] In `MenuBarManager.swift`, add:
  ```swift
  var allCategories: [CategoryInventoryItem] = []
  ```
- [ ] Mark `growingCategories` and `stableCategories` as computed:
  ```swift
  var growingCategories: [CategoryInventoryItem] {
      allCategories.filter { $0.recentGrowthStory != nil }
          .sorted { $0.currentSizeBytes > $1.currentSizeBytes }
  }
  var stableCategories: [CategoryInventoryItem] {
      allCategories.filter { $0.recentGrowthStory == nil }
          .sorted { $0.currentSizeBytes > $1.currentSizeBytes }
  }
  ```
- [ ] Update `stableTotalBytes` as computed:
  ```swift
  var stableTotalBytes: Int64 {
      stableCategories.reduce(0) { $0 + $1.currentSizeBytes }
  }
  ```

### Step 6.2 — Remove `normalizeVisibleInventoryState`

- [ ] Delete the entire function body.
- [ ] Remove all 3 call sites (lines 1627, 1760, 1778). They're no longer needed — setting `allCategories` automatically produces correct partitions.
- [ ] Update `applyPartialCategoryTotals` to write `allCategories` instead of `stableCategories`/`growingCategories`.

### Step 6.3 — Update all writers to set `allCategories`

- [ ] Find every place that assigns `growingCategories = ...` or `stableCategories = ...` and replace with a single `allCategories = ...` assignment.
- [ ] Update `applyInventory` to set `allCategories` directly.
- [ ] Update `clearInventoryState` to set `allCategories = []`.
- [ ] Update the saved-state restoration to set `allCategories`.

### Step 6.4 — Update SwiftUI views

- [ ] Any view that reads `growingCategories` or `stableCategories` continues to work (they're computed now).
- [ ] Verify `@Observable` correctly tracks computed property dependencies — views should re-render when `allCategories` changes.
- [ ] Build.

**Test — comprehensive:**  
1. Run the full test checklist from Step 0.5.  
2. Every scenario must produce identical UI behavior to before the refactor.  
3. Verify in Console.app that category counts are correct at every state transition.  
4. Verify no `DUPLICATE CATEGORIES` messages (now impossible by construction).  
5. Performance test: start a scan of a large directory. Verify no UI jank from recomputed filters (the arrays are small — <100 items — so this should be negligible).

**Test — @Observable correctness:**  
1. Add a temporary `print()` in a computed property getter.  
2. Navigate the UI. Verify the getter is called only when `allCategories` changes, not on every render.  
3. Remove the `print()`.

**Monitor while running:**  
- Console.app → `StateMerge` and `Inventory` categories.  
- Verify `allCategories` is set exactly once per state transition (not multiple times).  
- Xcode Instruments → Time Profiler — verify no unexpected CPU spikes from recomputed filters.

**Commit:** `refactor: replace two-array split with single allCategories source of truth`

---

## Phase 7: P3 — FSEvents Coalescing Improvements

### Step 7.1 — Add `kFSEventStreamCreateFlagNoDefer`

- [ ] In `FSEventsWatcher.swift`, add the flag:
  ```swift
  let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents |
      kFSEventStreamCreateFlagWatchRoot |
      kFSEventStreamCreateFlagNoDefer
  )
  ```
- [ ] Build.

**Test:**  
1. Run app. Let it idle for 30 seconds (quiet period).  
2. Create a single file in the watched directory.  
3. Measure time until FSEvents callback fires.  
4. With `NoDefer`, it should fire within ~1s (coalescing interval).  
5. Without `NoDefer` (old behavior), first event after quiet could be delayed up to 1s extra.

### Step 7.2 — Add `FSEventStreamFlushSync` after manual scans

- [ ] In `MenuBarManager.swift`, after a scan completes and the watcher is armed, call:
  ```swift
  await fsEventsWatcher?.flush()  // thin wrapper around FSEventStreamFlushSync
  ```
- [ ] Add the `flush()` method to `FSEventsWatcher`.

**Test:**  
1. Run a full scan. Immediately after completion, create a file.  
2. Verify the file change is picked up faster than before (no stale events sitting in the queue).  
3. Monitor Console.app → `FSEvents` — verify events arrive promptly.

**Commit:** `perf: add kFSEventStreamCreateFlagNoDefer and post-scan flush`

---

## Phase 8: P3 — Explore ValueObservation for DB → UI Pipeline

> **⚠️ Research phase first. Do not implement until Phase 6 is complete and stable.**

### Step 8.1 — Spike: ValueObservation on `workingSetCategoryTotal`

- [ ] Create a throwaway branch.
- [ ] Write a `ValueObservation` that tracks `workingSetCategoryTotal`:
  ```swift
  let observation = ValueObservation.tracking { db in
      try CategoryTotalRecord.fetchAll(db)
  }
  let cancellable = observation.start(in: dbPool, scheduling: .mainActor) { error in
      Logger.inventory.error("ValueObservation error: \(error)")
  } onChange: { items in
      self.allCategories = items.map { ... }
  }
  ```
- [ ] Wire it up alongside the existing pipeline (don't remove the old one yet).

### Step 8.2 — Measure write frequency

- [ ] Add a counter that logs how many times `onChange` fires during a full scan.
- [ ] Compare against the current `applyPartialCategoryTotals` frequency (~every 2s).
- [ ] If `onChange` fires >10x more frequently, the approach needs throttling or a different observed table.

**Test — spike validation:**  
1. Run a full scan.  
2. Count `onChange` fires vs `applyPartialCategoryTotals` calls.  
3. If write amplification is acceptable (<2x), proceed to full implementation.  
4. If not, document findings and close this phase as "not viable for now".

**Deliverable:** Spike branch with findings. Either merge or archive.

---

## Phase 9: Final Validation

### Step 9.1 — Full regression run

Execute the complete test checklist from Step 0.5 with Console.app monitoring:

- [ ] Scenario 1: Fresh launch → first scan (empty dir) ✅
- [ ] Scenario 2: Fresh launch → first scan (large dir) ✅
- [ ] Scenario 3: Add 100 files → FSEvents refresh ✅
- [ ] Scenario 4: Delete 50 files → refresh ✅
- [ ] Scenario 5: Scan → cancel mid-scan ✅
- [ ] Scenario 6: Accept growth → categories update ✅
- [ ] Scenario 7: Background → foreground → consistent state ✅
- [ ] Scenario 8: Rapid double scan ✅

For each: no crashes, no `DUPLICATE CATEGORIES` logs, no growth-story flicker, correct category sizes.

### Step 9.2 — Memory leak check

- [ ] Open Instruments → Leaks.  
- [ ] Run through all 8 scenarios.  
- [ ] Verify no new leaks introduced by the AsyncStream or Unmanaged changes.  
- [ ] Specifically check: `FSEventsWatcher` is deallocated after `stop()`, `AsyncStream` consumer task is cancelled cleanly.

### Step 9.3 — Stress test

- [ ] Watch a directory with `find /LargeDir -exec touch {} \;` running continuously.  
- [ ] Run for 10 minutes.  
- [ ] Verify: no memory growth, no `assertionFailure`, no frozen UI, Console.app shows expected log cadence.

### Step 9.4 — Remove debug logging from Phase 0 (optional)

- [ ] Convert `Logger.state.error("DUPLICATE CATEGORIES...")` to keep (it's a legitimate error path).  
- [ ] Convert `Logger.state.info("normalize...")` to `.debug` level (reduce noise in production).  
- [ ] Convert `Logger.progress.info("applyPartial...")` to `.debug` level.  
- [ ] Keep `Logger.fsEvents.info("emitChangeBatch...")` at `.debug` level.  
- [ ] Build and run one final time to verify nothing breaks.

**Commit:** `chore: tune log levels for production`

---

## Summary: Phase Dependencies

```
Phase 0 (Monitoring)  ← must be first
    ↓
Phase 1 (P0 Assertion)
    ↓
Phase 2 (P1 FSEvents)  ←→  Phase 3 (P1 AsyncStream)
    ↓                          ↓
Phase 4 (P2 Dead Code)
    ↓
Phase 5 (P2 Exclusion Fix)
    ↓
Phase 6 (P3 Single Array)  ← largest refactor, separate branch
    ↓
Phase 7 (P3 FSEvents Flags)
    ↓
Phase 8 (P3 ValueObservation)  ← research spike, may not merge
    ↓
Phase 9 (Final Validation)
```

Phases 2 and 3 can run in parallel — they touch different files.  
Phases 4 and 5 are independent of each other but should wait for Phase 3 (AsyncStream changes the scan flow).  
Phase 6 depends on all previous phases being stable.  
Phase 7 is independent of Phase 6 but touches `FSEventsWatcher` (already modified in Phase 2).
