# Pre-Beta Fix Plan

Critical issues to address before beta distribution.

---

## Fix 1: Remove hardcoded dev paths from production code

**Severity:** Critical (ships personal dev config)
**Files:** `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/FileScanner.swift`

**Problem:** Two places hardcode the developer's local repo path:

1. `autoScanIgnoredRoots()` (MenuBarManager.swift:2507-2512) adds `~/dev/projects/prunr/.build` as an FSEvents ignore root. Guarded by `fileExists` so it's a no-op for other users, but shouldn't ship.

2. `FileScanner.internalPathFragments` (FileScanner.swift:18) contains `"/.build/derivedData/"` which is fine as a generic pattern, but verify it's intentionally broad and not just matching the dev setup.

**Fix:** Remove the hardcoded repo path block from `autoScanIgnoredRoots()` entirely (lines 2507-2512). The generic `internalPathFragments` and user-configured ignores already cover this.

---

## Fix 2: deinit crash risk with MainActor.assumeIsolated

**Severity:** Critical (potential crash)
**Files:** `Prunr/Services/MenuBarManager.swift`

**Problem:** `MenuBarManager.deinit` (line 2517) uses `MainActor.assumeIsolated { ... }` to access timers and tasks. If deinit ever runs off the main thread, this traps at runtime. Currently safe because MenuBarManager is a singleton, but fragile — any future refactor or test that drops the last reference from a background context will crash.

**Fix:** Replace with nonisolated-safe cleanup:
```swift
deinit {
    updateTimer?.invalidate()
    activityPulseTimer?.invalidate()
    recentChangeTask?.cancel()
    reconciliationTask?.cancel()
    let watcher = fileEventsWatcher
    if let watcher {
        Task { await watcher.stop() }
    }
}
```
Timer.invalidate() and Task.cancel() are thread-safe. No MainActor isolation needed.

---

## Fix 3: Background reconciliation silently swallows all errors

**Severity:** High (user gets stuck with no feedback)
**Files:** `Prunr/Services/MenuBarManager.swift`

**Problem:** `upgradeDeltasOnlyToFullInventory()` (line 1072-1076) and `performSilentReconciliation()` (line 1102-1106) catch all scan errors and silently `return`. If a beta user's first background scan fails (permissions, disk full, path removed), they stay stuck in deltas-only mode permanently with no indication of what happened.

**Fix:**
- In `upgradeDeltasOnlyToFullInventory`: on failure, log via Logger and schedule a retry with exponential backoff (e.g. 30s → 60s → 120s, cap at 10min). After 3 consecutive failures, set an observable error state the UI can surface (e.g. a subtle banner: "Background scan failed — tap to retry").
- In `performSilentReconciliation`: log the error. No retry needed since it's periodic, but don't silently discard.

---

## Fix 4: Scan cancel cannot interrupt a blocking fts_read

**Severity:** High (cancel button unresponsive)
**Files:** `Prunr/Services/FileScanner.swift`, `Prunr/Services/ScanService.swift`

**Problem:** When the user presses cancel, `ScanService.isCancelled` is set to `true`, but this flag is only checked by the stream consumer between items. Inside `FileScanner`, `Task.isCancelled` is checked every 2,000 files (line 125), but `fts_read()` is a blocking syscall. If it blocks on an unresponsive directory (external drive, FUSE mount), the cancel button does nothing until `fts_read` returns.

**Fix:** Run the FTS producer in a detached Task and use `withTaskCancellationHandler` to close the FTS handle from outside when cancelled. Alternatively, add a timeout: if a single `fts_read` call takes >5 seconds, break out of the loop and finish the stream with a timeout error.

---

## Fix 5: GrowthItem.category recomputes classification on every access

**Severity:** Medium (performance foot-gun)
**Files:** `Prunr/Models/GrowthCategory.swift`

**Problem:** `GrowthItem.category` (line 32-34) is a computed property that calls `GrowthCategory.categorize(path:)` — lowercasing the path + 20 string operations — every single time it's accessed. Currently not hit in the main UI path (views use `CategoryInventoryItem.category` which is stored), but it's a landmine. Any future view code that reads `growthItem.category` in a list will trigger hundreds of re-classifications per scroll frame.

**Fix:** Either:
- (a) Store category at init time (add `let category: GrowthCategory` parameter, populate in `SubcategoryAccumulator.add()`), or
- (b) Delete the computed property entirely if it's truly unused — force callers to use the already-classified value from the scan pipeline

---

## Implementation Order

1. **Fix 1** — 5 min, zero risk, must not ship dev paths
2. **Fix 2** — 5 min, prevents a crash pattern
3. **Fix 3** — 30 min, prevents silent onboarding failure
4. **Fix 4** — 1-2 hrs, prevents unresponsive cancel
5. **Fix 5** — 15 min, removes performance foot-gun
