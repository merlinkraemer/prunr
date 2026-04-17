# Prunr Beta Audit — 2026-04-17

Full-stack audit run before beta. Six parallel subagent passes over scan engine, FSEvents pipeline, database layer, concurrency/CPU, UI/SwiftUI, and permissions/lifecycle — cross-referenced against PureMac (`puremac_analysis/ANALYSIS.md`) and Dusk (`dusk_analysis/ANALYSIS.md`) reference patterns.

**Total findings: 89** across 6 domains. 12 P0, 31 P1, 32 P2, 14 pattern-gaps.

---

## 🔥 Must-fix before beta (P0)

### 1. FSEvents self-feedback loop → 150% CPU (Issue #9 root cause)
Three corroborating mechanisms combine. Fixing #1a alone is likely insufficient.

- **1a. DB WAL/SHM sidecars not filtered at watcher creation.** `FSEventsNoiseFilter` filters *after* delivery — the C callback, main-actor hop, and URL allocation costs are paid on every SQLite write. Auxiliary files `Prunr.sqlite-wal`, `Prunr.sqlite-shm`, `Prunr.sqlite-journal` may also slip through the filter's extension check. **Fix:** exclude `~/Library/Application Support/Prunr` from `watcherURLs()` at stream creation, not after delivery. Confirm noise filter explicitly suppresses all three SQLite auxiliary extensions.
- **1b. `FSEventStreamFlushSync` called before `isLoading = false`.** `MenuBarManager.swift:931` flushes synchronously during scan-complete; any events buffered during the scan (including the scan's own WAL writes) are delivered immediately, and a `scheduleRecentChangeRefreshTask(after: 0.5)` fires at line 1030 → back-to-back full scans. **Fix:** move flush after `isLoading = false` or remove it entirely and rely on the 0.5s post-scan schedule.
- **1c. Hot write on `workingSetCategoryTotal`.** `applyWorkingSetCategoryDeltas` (`DatabaseManager.swift:1928-1965`) does a full `SELECT * FROM workingSetCategoryTotal` + N upserts before every subtree replace. **Fix:** replace with single SQL `UPDATE ... SET totalBytes = MAX(0, totalBytes + delta)` — no read required.

### 2. Double-dispatch re-entrancy in FSEvents handoff
`MenuBarManager.swift:2411-2416` wraps `RunLoop.main.perform { MainActor.assumeIsolated { ... } }` despite FSEvents already delivering on the main queue (`FSEventStreamSetDispatchQueue(..., DispatchQueue.main)`). Creates a re-entrancy window where a second callback can fire before the first `perform` block runs — `requiresFullRescan` path at line 2509-2519 bypasses `isInventoryRefreshInProgress` guard. **Fix:** call `recordFileWatcherChangeBatch` directly — drop both wrappers.

### 3. User-customized boundaries ignored at scan time
`BaselineService.swift:263` uses `BoundaryConfig.default.shouldStopDrillDown` — checks only `standardBoundaries`. User toggles in SettingsStore.enabledBoundaries (custom additions, standard disables) have **zero effect** on actual scanning. **Fix:** pass `SettingsStore.shared.enabledBoundaries` into BaselineService at scan time.

### 4. Orphan snapshot on external cancellation
`ScanService.swift:293` — if a Task is externally cancelled between `createSnapshot` (line 201) and the `do` block entry, the catch block never runs and the snapshot is never deleted. **Fix:** wrap snapshot ID + scan body in a single `defer` that deletes on throw.

### 5. Cancellation token not propagated to `RecentChangeService`
`RecentChangeService.swift:154` uses its own `FileScanner` without passing any cancellation token. `ScanService.cancelScan()` has no effect on incremental refreshes — they always run to completion. **Fix:** share the token or give RecentChangeService its own.

### 6. Orphan cleanup races working-set writes
`DatabaseCleanupService.swift:584-651` — orphan deletion can execute between `paths` insert and `workingSetEntry` insert during a concurrent subtree replace. FK cascade kills fresh data. **Fix:** run orphan cleanup inside the same write transaction as entry deletion, or acquire a deferred lock.

### 7. Migration non-idempotency on partial failure
`DatabaseManager.swift:82-480` — v7 (6 DDL) and v10 (full table rewrite) have no savepoints. Crash mid-migration → schema half-mutated, no migration row → next launch re-runs and fails with "table already exists". **Fix:** wrap complex migrations in savepoints; guard every ALTER with column-existence check.

### 8. No sleep/wake or mount/unmount lifecycle hooks
Zero `NSWorkspace` observers anywhere. External drive ejection mid-scan produces silent errors and autoscan keeps retrying gone paths. Machine wakes from sleep → FSEvent flood + stale reconciliation timer fires immediately with no jitter. **Fix:** observe `willSleep`/`didWake`/`DidMount`/`WillUnmount`; gate watcher and scheduler accordingly.

### 9. Silent `SMAppService` failures
`SettingsStore.swift:429` catches launch-at-login register/unregister errors with `print()`. Toggle stays visually enabled while feature is broken. **Fix:** surface `launchAtLoginError: Error?` to UI.

### 10. DELETE+INSERT without UNIQUE constraints — silent duplicates
`DatabaseManager.swift:1033` (`replaceCategorySnapshots`) and `:1140` (`replaceSubcategorySnapshots`) use DELETE+INSERT patterns, but there's **no UNIQUE(snapshotId, category)** on `categorySnapshot` and no UNIQUE on `subcategorySnapshot`. A mid-process kill wipes category history permanently; re-runs can produce duplicate rows. **Fix:** migration adds `UNIQUE(snapshotId, category)` + `UNIQUE(snapshotId, category, subcategory)`, convert to UPSERT. Highest-ROI schema change in the audit.

### 11. Drill-down flicker (Issue #7) — animation/sleep race
`DrilldownTransitionCoordinator.swift:76` uses `Task.sleep(280ms)` to time phase3 against a 280ms `snappy` animation. Wall-clock Task.sleep ≠ CAAnimation duration — phase3 resets `slideOffset=0` with `disablesAnimations=true` while the slide is still rendering its final frame. Compounded by `.animation()` implicit modifiers on `MenuBarView.swift:1427-1428` cascading into descendants during the slide. **Fix:** use `withAnimation(_:completionCriteria:_:body:)` (macOS 14+) or add a 15-30ms fence; remove implicit `.animation()` from `overviewHeader`.

### 12. `PathManager` duplicate UserDefaults key
`PathManager.swift:11` hardcodes `"trackedPaths"` — same key as `SettingsStore.Keys.trackedPaths`. `PathManager` is dead code; if ever activated it corrupts `SettingsStore` data. **Fix:** delete the file (or namespace the key).

---

## ⚠️ P1 — Perf / reliability before beta

### Scan engine
- Scans have **no timeout** (Dusk kills at 300s with partial results). FileScanner can walk forever on pathological trees.
- **No file-count cap** (PureMac caps at 10k/5k). A misconfigured root = scan entire volume.
- **No parallel scanning** of independent tracked paths — all sequential; should use `TaskGroup`.
- `Task.yield()` only every 20,000 files (`FileScanner.swift:144`) — too coarse; starves actors for ~100ms. Use 2-5k or time-based yield.
- `batch` pre-allocated to 50,000 (`ScanService.swift:214`); `subcategoryTotals` dictionary unbounded in RAM for entire scan.
- `SubcategoryAccumulator.add` does O(n) min-search per file (`ScanService.swift:246`) — track `minIndex` field instead.
- **No size-threshold skip** (<1KB). Tiny metadata files bloat DB without size contribution.
- **No `mdfind`/Spotlight fast path** for large-file discovery.
- **No default skip list** for `node_modules`, `.cache`, `Pods`, `DerivedData`, `__pycache__`.
- `coalescedPaths` is O(n²) up to 25k paths.
- `FileManager.fileExists(atPath:isDirectory:)` follows symlinks — asymmetric with `FTS_PHYSICAL` in the main walk. Symlink to dir gets queued for subtree scan.

### FSEvents
- **No batch-size cap** on `ChangeBatch` — a 500k-path burst stalls the main actor for full allocation time.
- `kFSEventStreamEventFlagHistoryDone` unhandled — on stream restart the sentinel is misinterpreted as a real event.
- `kFSEventStreamEventFlagMount`/`Unmount` unhandled.
- Re-arm between `stop()` and new stream loses events — record last event ID, pass as `sinceWhen`.
- `nonisolated(unsafe) fileEventsWatcher` (`MenuBarManager.swift:426`) races with deinit.

### Database
- WAL mode relies on GRDB default — add explicit `PRAGMA journal_mode = WAL`.
- `paths.path` has COLLATE NOCASE, which **disables SQLite's LIKE prefix optimization**. Subtree LIKE scans do full table scan. Use `BETWEEN` range + B-tree.
- `GrowthJournalService.prune()` **never called** from any scheduled path — journal grows unbounded.
- N+1 reads in `DatabaseCleanupService.recentSnapshotIDs`, `aggregateCategoryTotalsForOldSnapshots`, `cleanupOldSnapshotEntries`.
- `resetBaseline` (`BaselineService.swift:178`) deletes in a for-loop of separate write txns — single DELETE statement instead.
- `writeCategorySnapshot` (`DatabaseManager.swift:1019`) is synchronous, blocks caller.
- No corruption recovery — corrupt WAL bricks the app. Rename to `prunr.db.corrupt-<ts>` + reinit.
- No `auto_vacuum = INCREMENTAL`.

### Concurrency / UI
- `performRecentChangeRefresh` busy-polls every 1.5s during long scans (`MenuBarManager.swift:2490`).
- Timer closures at `:2033`, `:2073` capture `self` strongly via `Task { @MainActor in }`.
- `reconcileIfStale` doesn't cancel prior `reconciliationTask` before spawning new one.
- `allCategories` reassigned on every progress tick — no equality guard → SwiftUI body churn.
- `configureFileWatcherIfNeeded` unconditionally spawns a Task even on no-op early-return.
- `DriveBarView.renderedSegments` O(n²) recomputed on every hover.
- `CategoryGrowthListView.fileListView` pre-warm recomputes sort/reduce/Set/filter on every body eval.
- `MenuBarView.driveBarSegments` sort+filter+map on every parent render.
- Two implicit `.animation()` modifiers on `overviewHeader` cascade during drill-down transition.
- `HiddenScrollIndicators` uses `DispatchQueue.main.async` in updateNSView → scroll-indicator flash.

### Permissions / Lifecycle
- `DiskSpaceService` single-method only — no `tmutil listlocalsnapshots` / `diskutil apfs listSnapshots` fallback. APFS local snapshots cause understated free space.
- FDA probe missing `~/.Trash` (always exists, always TCC-gated) — can falsely report granted.
- FDA state never re-checked on `NSApp.didBecomeActive` — user grants FDA, cmd-tabs back, UI stays stale.
- SettingsStore chain fires 3 separate `UserDefaults.set` per base-path change.

---

## 🧭 Patterns worth porting (from PureMac + Dusk)

Prioritized by ROI:

| Pattern | Source | Why |
|---|---|---|
| Spotlight (`mdfind`) fast path for large files | Dusk | Instant vs. full walk; seeds UI pre-scan |
| Timeouts with partial results on scans | Dusk | Prevents UI freeze on slow storage / permission walls |
| File-count safety caps (10k directorySize / 5k large-file) | PureMac | Protects against misconfigured roots |
| Parallel tracked-path scanning via TaskGroup | PureMac + Dusk | Linear speedup for multi-root setups |
| Hardcoded skip lists (`node_modules`, `.cache`, `Pods`, `DerivedData`) | PureMac | Huge noise reduction |
| Protected-path hardlist (`~/Library/Mail`, `~/.ssh`, `/System`) | PureMac | Defense before any destructive action |
| Allowlist-based validation before destructive ops | PureMac | Symlink-attack defense |
| Multi-method disk-space fallback (URLResourceValues + tmutil + diskutil) | PureMac | Correct free-space accounting with APFS snapshots |
| Path probing for FDA (incl. `~/.Trash`) | PureMac | More reliable than API calls |
| Color thresholds on usage bars (70% / 85% / 95%) | Dusk | Dynamic urgency signal (Prunr uses 70/90/100 — close) |
| Per-path scan history pruning + trend queries | Dusk | Unlocks "grew 3 scans in a row" anomaly UI |
| Docker disk analysis as first-class category | Dusk | Dev machines carry 10-50GB |
| WAL mode + FK=ON explicit on every connection | Dusk | Concurrent reads; no corruption on interrupt |
| Scan comparison via basename (survives renames) | Dusk | Trend accuracy under reorgs |
| Unified entry table (is_dir flag) | Dusk | Simpler schema, cross-type queries |

---

## Handoff

All per-domain detailed findings (file:line + fix for each) live in the agent transcripts above this report in the session. The P0 list above is the minimum for beta; P1 is the should-fix list; patterns table is the post-beta roadmap.

Top-3 fastest wins: (a) exclude Prunr DB dir from `watcherURLs()` (one-line fix, likely kills 150% CPU), (b) UNIQUE constraints on `categorySnapshot`/`subcategorySnapshot` (single migration, correctness + 2x read speedup), (c) delete dead `PathManager.swift` (prevents future data corruption).
