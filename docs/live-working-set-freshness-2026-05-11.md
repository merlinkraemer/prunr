# Live Working Set Freshness

**Date:** 2026-05-11
**Status:** draft

## Problem

Prunr currently gets a correct initial scan, then stops reflecting new files because the automatic watcher is disabled. Re-enabling it directly risks recreating the old feedback loop: broad roots such as `~` include Prunr's own SQLite DB/WAL/SHM writes, so the app can wake itself and keep processing its own churn. The menu bar UI also reloads too much on open, so freshness work can turn into visible latency.

## Solution

Make `workingSetEntry` and `workingSetCategoryTotal` the live current-state source of truth. The initial full scan builds the working set and baseline. FSEvents then acts as a cheap invalidation source: small external batches update the working set incrementally, while large/dropped/uncertain batches mark the tracked root dirty for a delayed bounded refresh with backoff. Full scans become scheduled reconciliation only, defaulting to 24 hours. Accepting growth promotes the current working set to the baseline with a DB-local operation, not a filesystem scan.

Prunr's own operational files must be outside accounting and watcher feedback before whole-home watching is enabled. Developer/package/cache/media growth remains visible by default; only Prunr internals and necessary OS traversal hazards are hard-excluded.

## Out of scope

- Built-in cleanup or deletion workflows.
- Adaptive scheduling beyond a simple fixed reconciliation interval.
- Default ignoring of `node_modules`, package caches, build artifacts, media imports, agent workdirs, or developer tool output.
- Whole-volume `/` live watching; this plan targets user-selected roots such as `~` and normal folders.
- Rewriting the whole inventory UI or category taxonomy.

## Slices

### s1: Isolate Prunr Operational State
- **outcome:** Prunr DB/state/log/temp files are never counted as growth and cannot create a self-feedback loop for whole-home watching.
- **depends_on:** none
- **likely_files:** `Prunr/Database/DatabaseManager.swift`, `Prunr/Services/FSEventsNoiseFilter.swift`, `Prunr/Services/FileScanner.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/ViewModels/SettingsStore.swift`
- **acceptance:**
  - [ ] With `~` enabled, Prunr's DB/WAL/SHM paths are outside the live accounting result or are hard-excluded before accounting.
  - [ ] A DB write/checkpoint does not enqueue a user-visible recent-change refresh.
  - [ ] Initial scan and incremental refresh do not show Prunr's own files in category totals or growth.
  - [ ] Existing reset/install flow still clears the active Prunr state location.

### s2: Cheap Watcher Intake Coordinator
- **outcome:** FSEvents can be enabled without doing heavy work in the callback or storing unbounded pending paths.
- **depends_on:** s1
- **likely_files:** `Prunr/Services/FSEventsWatcher.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/FSEventsNoiseFilter.swift`, `Prunr/Services/RecentChangeService.swift`
- **acceptance:**
  - [ ] Watcher callback filters internal-only batches and records only bounded state.
  - [ ] Small external batches keep at most a capped set of paths for incremental refresh.
  - [ ] Large, dropped, root-changed, or directory-heavy batches mark the tracked root dirty instead of storing thousands of paths.
  - [ ] Logs expose batch classification at `notice` or `debug` level without per-batch info flooding.

### s3: Incremental Working-Set Refresh Path
- **outcome:** New and changed files appear in the UI as growth shortly after normal filesystem activity, without a full scan.
- **depends_on:** s2
- **likely_files:** `Prunr/Services/RecentChangeService.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Database/DatabaseManager.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Views/MenuBarView.swift`
- **acceptance:**
  - [ ] After initial scan, creating a file under the tracked path updates `workingSetEntry` and `workingSetCategoryTotal`.
  - [ ] The menu bar view shows category growth for the new file without running `loadInventory()`.
  - [ ] Deleting the same file removes or offsets the growth indicator.
  - [ ] Manual "Check Growth" flushes queued small changes but does not full-rescan by default.

### s4: Dirty-Root Backoff Refresh
- **outcome:** Noisy valuable directories such as package installs stay visible, but bursts collapse into bounded background work.
- **depends_on:** s2
- **likely_files:** `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/RecentChangeService.swift`, `Prunr/Services/FileScanner.swift`, `Prunr/Extensions/Logger+Prunr.swift`
- **acceptance:**
  - [ ] A large synthetic batch marks the tracked root dirty and schedules one delayed refresh.
  - [ ] More events during refresh mark the root dirty again instead of starting parallel refreshes.
  - [ ] Repeated dirty refreshes back off and never loop continuously.
  - [ ] UI remains usable and can show a stale/changes-pending state while reconciliation is pending.

### s5: Cheap Accept Growth Baseline Promotion
- **outcome:** Accepting growth resets growth indicators from the current working set without touching the filesystem.
- **depends_on:** s3
- **likely_files:** `Prunr/Database/DatabaseManager.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Views/MenuBarView.swift`
- **acceptance:**
  - [ ] Accept growth creates/promotes a baseline snapshot from the current working set with DB-local work only.
  - [ ] Growth journal state for the accepted tracked path is cleared.
  - [ ] The UI returns to stable immediately after accept.
  - [ ] No full scan starts as part of accept growth.

### s6: Scheduled Reconciliation Backstop
- **outcome:** Prunr periodically corrects drift with a simple fixed 24-hour reconciliation schedule, while normal tracking remains incremental.
- **depends_on:** s3, s4
- **likely_files:** `Prunr/ViewModels/SettingsStore.swift`, `Prunr/Views/SettingsView.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/ScanService.swift`, `Prunr/Services/DatabaseCleanupService.swift`
- **acceptance:**
  - [ ] Default reconciliation interval is 24 hours.
  - [ ] Settings allow selecting fixed intervals such as 24h, 48h, 72h, 1w, and 2w.
  - [ ] Reconciliation does not run on every menu open.
  - [ ] Cleanup/checkpoint work is decoupled from scan completion enough to avoid watcher feedback.

### s7: Fast Menu Open From Cached Current State
- **outcome:** Opening the menu bar panel reads current working-set totals without blocking on scan or heavy category reload.
- **depends_on:** s3
- **likely_files:** `Prunr/Views/MenuBarView.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Database/DatabaseManager.swift`
- **acceptance:**
  - [ ] Opening the panel after a completed initial scan shows clickable categories from cached/current state.
  - [ ] Panel open does not trigger full scan or root-level reconciliation.
  - [ ] Closing the panel during refresh cannot leave loading flags stuck.
  - [ ] Freshness text reflects last updated time or pending dirty state.

### s8: End-to-End Monitor and Regression Coverage
- **outcome:** The implementation has a repeatable proof that tracking is both fresh and lightweight over time.
- **depends_on:** s5, s6, s7
- **likely_files:** `PrunrTests/`, `package.json`, `scripts/`, `docs/test-checklist.md`, `docs/todo.md`
- **acceptance:**
  - [ ] Test coverage proves post-init file creation appears as growth.
  - [ ] Test coverage proves Prunr internal DB writes do not create user-visible growth.
  - [ ] `npm run monitor` includes a freshness check that creates/modifies a file after baseline and observes DB/UI-facing totals.
  - [ ] A smoke run shows low idle CPU/RSS, bounded pending state, and no repeated full-scan loop.

## Dependency graph

```text
s1 -> s2
s2 -> s3, s4
s3 -> s5, s6, s7
s4 -> s6
s5 -> s8
s6 -> s8
s7 -> s8
s8 -> (none)
```

## Parallel batches

- **Batch 1** (independent): s1
- **Batch 2** (after s1): s2
- **Batch 3** (after s2): s3, s4
- **Batch 4** (after s3): s5, s7
- **Batch 5** (after s3 and s4): s6
- **Batch 6** (after s5, s6, and s7): s8

## Notes

- Current blocker: `MenuBarManager.enableAutomaticFileWatcher` is `false`, so post-init freshness has no event source.
- Current risk: broad `~` watching includes `~/Library/Application Support/Prunr`, so filtering after delivery is necessary but not sufficient as the only defense.
- `RecentChangeService` already owns useful working-set update mechanics; this plan keeps that direction instead of making full scans the hot path.
- `DatabaseManager.createSnapshotFromWorkingSet` and `BaselineService.acceptGrowth` already point toward DB-local baseline promotion; verify they do not trigger scan work.
- Full scans are reconciliation only. The user-facing loop is: watcher updates working set, UI shows growth versus baseline, accept growth promotes baseline, scheduled reconciliation corrects drift.
