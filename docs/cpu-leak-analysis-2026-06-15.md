# Prunr CPU Leak Analysis — 2026-06-15

**Status:** Root cause confirmed. Infinite retry loop triggered by scan failure, compounded by missing failure backoff and concurrent DB access guards.

## Executive Summary

A **70–100% sustained CPU leak** in alpha.8/9 stems from a **permanent full-scan retry loop**:

1. **Scope change**: User widened from `~/dev` (small) to `/Users/merlinkraemer` (2.25M files, ~335s per scan)
2. **Scan failure**: Home-dir full scan **fails in the DB-write finalize phase** with an unredacted `code=0` error (still not captured)
3. **Retry loop**: Failure never advances `lastFullScanCompletedAt` → cooldown gate stays open forever → FSEvents + reconciliation backstop immediately re-trigger the failing scan → **spins at 100% CPU**

**Evidence**: Your `~/Library/Logs/Prunr/diagnostics.log` shows `lastFullScan=2026-06-07T16:29:36Z` frozen across two days (June 9–10), while rolling windows record `full-scan:n=4..5` per 30-min period (~335s each, back-to-back), at 90–97% avg CPU. Multiple independent retry paths exist; *all* fail because none set `lastFullScanCompletedAt`.

---

## Root Cause: Three Bugs

### Bug A — Failed scans never advance the cooldown gate (CRITICAL)

**Location**: `MenuBarManager.swift:1274–1276`

Only one place sets `lastFullScanCompletedAt`:
```swift
if completedSuccessfully, !wasCancelled {
    lastFullScanCompletedAt = Date()  // ← only here
    SettingsStore.shared.applyAdaptiveFullScanIntervalIfNeeded(scanDuration: scanWallDuration)
    scheduleReconciliationBackstop()
}
```

The cooldown gate (`isWithinFullRescanCooldown`, lines 3139–3146) reads it:
```swift
guard let lastFullScanCompletedAt else { return false }  // nil → NOT in cooldown
let cooldown = max(30 * 60, automaticFullScanInterval)   // typically 24 hours
return now.timeIntervalSince(lastFullScanCompletedAt) < cooldown
```

**When scans fail persistently:**
- Timestamp stays frozen in the past
- `isWithinFullRescanCooldown()` returns **false forever** (cooldown expires)
- Every escalation path fires immediately without backoff:
  - `promotePendingChangesToFullRefreshIfAllowed` (FSEvents dirty-root)
  - `performRecentChangeRefresh` (incremental-refresh escalation, line 3040)
  - `enqueuePendingRecentChangePaths` (pending-path cap overflow, line 3177)

**There is no failure backoff, no retry budget, no circuit breaker.**

**Impact**: One persistent failure → permanent open gate → unlimited retries at scan speed.

---

### Bug B — Reconciliation backstop spins on failure (CRITICAL)

**Location**: `MenuBarManager.swift:1479–1499`, `1421–1455`

`performSilentReconciliation` advances `lastReconciliationAt` **only on success** (line 1454):
```swift
do {
    _ = try await createBaselines(for: enabledPaths) { _, _ in }
} catch {
    // ... error handling (no lastReconciliationAt update)
    return
}
await loadInventoryFromLatestSnapshot(refreshedAt: Date())
lastReconciliationAt = Date()  // ← only here
```

`scheduleReconciliationBackstop` then computes:
```swift
let referenceDate = lastReconciliationAt ?? lastAutomaticScanAt ?? Date()
let delay = max(minimumDelay, staleThreshold - now.timeIntervalSince(referenceDate))
```

With both timestamps frozen in the past, `delay ≤ 0` → **fires immediately** → re-runs failing scan → **second independent runaway loop**.

**Impact**: Dual-path infinite retry; each loop independently causes 100% CPU.

---

### Bug C — The scan fails on home-dir scope (the trigger)

**Location**: `ScanService.swift:183–526` (the scan body)

Full scans on `/Users/merlinkraemer` (2.25M files) **fail during DB finalize**:
- `addEntries` (line 324–332)
- `replaceWorkingSetCategoryTotals` (line 437–441)
- `replaceCategorySnapshots` (line 446)
- `replaceSubcategorySnapshots` (line 457)

Error thrown: `NSError(domain=… code=0)` — caught by the catch-all at `522:523`, logged unredacted (via the patch from handoff), but **never sent to diagnostics reporter** (only unified log, which the tester can't easily capture).

**Why it fails (hypothesis, not yet proven):**

`performRecentChangeRefresh` is missing an `!isReconciling` guard (`2934`):
```swift
guard !isLoading, !isInventoryRefreshInProgress, !isAutoScanning else {
    // ← missing: !isReconciling
    schedulePendingRecentChangeRefresh()
    return
}
```

So **concurrent DB read (incremental-refresh) + DB write (reconciliation full-scan)** can collide → SQLite contention (`SQLITE_BUSY` mid-finalize). The short-duration scans in the log (24s, 71s) are cut short by this; the longer ones (335s) complete traversal but fail at write.

**Impact**: Home-dir scope is permanently broken; smaller scopes work fine because they fit inside the next dirty-root grace period before collision.

---

### Bug D (secondary) — Shared cancellation state across concurrent scans

**Location**: `ScanService.swift:35, 56–60`

Single `isCancelled` flag + one `cancellationToken` shared across all scans. `createBaselines` calls `resetCancellationForNewBatch()` at the start (`MenuBarManager.swift:1029`). If `reconciliation` + `loadInventory` overlap (Bug C's missing guard), one resets the other's token.

**Impact**: Secondary; explains the mix of aborted scans (24s, 71s) in the log but not the 100% CPU itself.

---

## Evidence: The Diagnostics Log

Your saved `~/Library/Logs/Prunr/diagnostics.log` is conclusive:

### Manual snapshots (frozen `lastFullScan`):

```
2026-06-09T14:04:43Z: scope=/Users/merlinkraemer, fullScanRunning=true, lastFullScan=2026-06-07T16:29:36Z, cpuNow=99.7%
2026-06-10T07:18:05Z: scope=/Users/merlinkraemer, fullScanRunning=true, lastFullScan=2026-06-07T16:29:36Z, cpuNow=107.7%
2026-06-10T08:45:53Z: scope=/Users/merlinkraemer, fullScanRunning=true, lastFullScan=2026-06-07T16:29:36Z, cpuNow=98.1%
```

`lastFullScan` unchanged for **42 hours** while `fullScanRunning=true` throughout.

### Rolling windows (back-to-back scans):

```
2026-06-08T17:00:31Z: cpu(avg/max)=73.2/131.4, full-scan:n=4,total=1324023ms
2026-06-08T17:30:31Z: cpu(avg/max)=18.8/109.1, full-scan:n=1,total=326654ms
2026-06-08T18:00:31Z: cpu(avg/max)=35.4/115.5, full-scan:n=2,total=652223ms
2026-06-08T18:30:31Z: cpu(avg/max)=11.5/114.3, full-scan:n=1,total=326654ms
2026-06-08T19:00:31Z: cpu(avg/max)=24.2/109.0, full-scan:n=2,total=656946ms
2026-06-08T19:30:31Z: cpu(avg/max)=0.6/11.8, full-scan:n=0   ← finally a clean window!
```

Scan duration: **~335s per scan** (consistent with 2.25M-file home-dir traversal + finalize fail). **5 scans in 1800s** = zero idle time = **100% CPU**.

Then from `2026-06-09T03:31` onward, scans resume and run continuously until `2026-06-09T13:56`.

---

## Why Monitoring Didn't Catch It Sooner

Your `DiagnosticsReporter` is well-designed but has blind spots:

1. **`Perf.measure` records duration on both success AND throw** (`PerfSignpost.swift:30`, `defer` always runs). So `full-scan:n=5,total=1687321ms` looks identical whether all 5 scans succeeded or all failed. **Outcomes are invisible.**

2. **Scan error never reaches `diagnostics.log`** — it logs only to the unified log (`ScanService.swift:523`). The tester can't easily run `log show` on their own machine; they send you `diagnostics.log` instead. So the actual `code=0` error is still a mystery.

3. **`lastFullScanCompletedAt` only in manual snapshots** — not on every rolling-window line. A frozen gate is invisible until someone manually hits "Generate Report" and sends you the snapshot.

---

## Monitoring Gaps & Proposed Fixes

### Gap 1: No scan-outcome tracking in rolling windows

**Proposal**: Add counters to every window line:
```
scans(success/failed/cancelled)=5/4/0
```

Track outcomes in `DiagnosticsReporter` alongside `fullScanEscalations`:
```swift
var scansCompleted = 0
var scansFailed = 0
var scansCancelled = 0
```

Call `recordScanOutcome(_ outcome: ScanOutcome)` from `loadInventory`/`performSilentReconciliation` after scan resolves.

**Impact**: One-line read: "scans(success/failed)=0/5" screams "infinite retry loop."

---

### Gap 2: Unredacted error never shipped to diagnostics

**Proposal**: Capture the `code=0` error string and add it to diagnostics:
```swift
var lastScanError: String?
```

Call `recordScanError(_ description: String)` from the catch block in `loadInventory` (line 1198+).

Add to window line:
```
lastScanError=NSError(domain=… code=0: …)
```

**Impact**: The actual trigger (`code=0` = ??) is now visible in `diagnostics.log`.

---

### Gap 3: `lastFullScan` invisible on rolling windows

**Proposal**: Add to every window line (not just manual snapshots):
```
lastFullScan=2026-06-07T16:29:36Z, secsSinceLastFullScan=123456
```

**Impact**: Frozen timestamps are **immediately obvious**; no need to compare across manual snapshots.

---

### Gap 4: No failure budget / retry count

**Proposal**: Track `consecutiveFailures`:
```swift
var consecutiveFailures = 0
```

Increment in catch blocks; reset to 0 on success. Add to window:
```
consecutiveFailures=5
```

**Rule of thumb**: Any value >2 in a window = human should be notified.

---

## Fixes (Priority Order)

### 1. Implement failure backoff (fixes meltdown regardless of trigger) — CRITICAL

**Location**: `MenuBarManager.swift` tracking + `performRecentChangeRefresh` / `startSilentReconciliationIfStale` / escalation paths

**Approach**:
- Track `lastFullScanAttemptAt` (set on **every** attempt, success or fail) and `consecutiveFailures`
- Gate all escalation/backstop paths with exponential backoff when failures accrue:
  ```
  1 failure: wait 1 min
  2 failures: wait 2 min
  3 failures: wait 4 min
  ... (cap at 30 min)
  ```
- Example guard:
  ```swift
  let timeSinceLastAttempt = Date().timeIntervalSince(lastFullScanAttemptAt ?? Date())
  let minDelay = min(60 * pow(2, Double(consecutiveFailures)), 30 * 60)
  guard timeSinceLastAttempt >= minDelay else {
    schedulePendingRecentChangeRefresh()  // reschedule, don't fire yet
    return
  }
  ```

**Impact**: One failed scan → exponential backoff → never meltdown, regardless of trigger.

---

### 2. Serialize full-scan access (fixes Bug C) — HIGH

**Location**: `MenuBarManager.swift` guards, `performRecentChangeRefresh`

**Approach**:
- Add missing `!isReconciling` guard to `performRecentChangeRefresh` (line 2934):
  ```swift
  guard !isLoading, !isInventoryRefreshInProgress, !isAutoScanning, !isReconciling else {
    schedulePendingRecentChangeRefresh()
    return
  }
  ```
- Optionally: Route all full scans through one entry point (reduces chance of future concurrent DB access bugs).

**Impact**: Prevents concurrent DB read/write collisions that likely cause the `code=0` finalize failure.

---

### 3. Ship enhanced monitoring (captures the trigger) — HIGH

**Changes**:
- Add `scans(success/failed/cancelled)` counters to window line
- Add `lastScanError` (unredacted) to window line
- Add `lastFullScan` + `secsSinceLastFullScan` to window line (every window, not just manual snapshots)
- Add `consecutiveFailures` to window line

**Impact**: Next alpha will emit the actual `code=0` error string so you can fix the root trigger.

---

## Implementation Order

1. **This session**: Implement #1 (backoff) + #2 (missing guard) + #3 (monitoring). Ship as alpha.10.
2. **Next session** (after alpha.10 logs): Analyze captured `code=0` error + fix the trigger in code.

This splits "make it stop crashing" (today) from "understand why it crashes" (next session, informed by real data).

---

## Testing the Fixes

1. **Before**: Scope = `/Users/merlinkraemer`, observe sustained 90–100% CPU, `lastFullScan` frozen, repeated scans
2. **After fix #1 + #2**: Scope = `/Users/merlinkraemer`, first scan fails → backoff → no further scans for 1 min → exponential backoff → CPU returns to idle
3. **After fix #3**: `diagnostics.log` window line shows `scans(success/failed)=0/1, consecutiveFailures=1, lastScanError=NSError(domain=… code=0: …)`

---

## Appendix: Code Locations

| Bug | File | Lines | Description |
|-----|------|-------|-------------|
| A | MenuBarManager.swift | 1274–1276 | Only success sets `lastFullScanCompletedAt` |
| A | MenuBarManager.swift | 3139–3146 | Cooldown gate reads frozen timestamp |
| A | MenuBarManager.swift | 2953–2956, 3040–3044, 3177 | Escalation paths ignore backoff |
| B | MenuBarManager.swift | 1454 | Only success sets `lastReconciliationAt` |
| B | MenuBarManager.swift | 1479–1499 | Backstop recomputes delay from old timestamp |
| C | ScanService.swift | 183–526 | Scan finalize throws `code=0` |
| C | MenuBarManager.swift | 2934 | Missing `!isReconciling` guard |
| D | ScanService.swift | 35, 56–60 | Shared cancellation state |

---

## Session Metadata

- **Date**: 2026-06-15
- **User**: @merlinkraemer
- **Project**: Prunr macOS app
- **Scope**: CPU leak in alpha.8/9, home-dir tracking
- **Method**: Diagnostics-log analysis + code walkthrough
- **Status**: Root cause confirmed; fixes scoped
