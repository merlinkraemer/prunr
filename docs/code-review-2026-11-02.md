# Code review: bugs and correctness (2026-11-02)

Source: branch drain/stack-2026-11-01 @ 85ef096, `Prunr/` only. Read-only static review on the Linux box (no Swift compiler, nothing run). Line numbers refer to that commit.
Ranked by severity x likelihood. Confidence is about the code path, not about how often users hit it.

## Top 15

### 1. Fake "Trash emptied" rows after every full scan - HIGH, confidence high
- Where: `Services/FileScanner.swift:486` (full scans skip `.trash`), `Services/RecentChangeService.swift:200-214` (watcher does not), `Services/BaselineService.swift:179-200` (residual).
- Failure: user moves 3 GB to the Trash. The watcher records +3 GB on the Trash unit. The next full scan has no Trash rows in either snapshot, so the authoritative Trash delta is 0 and the residual writes -3 GB to the Trash (source `scan`). `EpisodeBuilder.fold` counts only Trash shrinks, so the list shows "Trash emptied 3 GB, found by scan" although nothing was emptied. A real empty after that scan records nothing (the rebuilt working set has no Trash rows).
- Fix: make the scanner and the watcher agree. Either scan `~/.Trash` (the episode logic expects Trash rows) or drop Trash paths in `refreshTargets` and the residual. One shared `ScanScope.shouldSkip(path:)` for both (see 3).

### 2. Partial scans are published as complete and authoritative - HIGH, confidence high
- Where: `Services/FileScanner.swift:387-390` (EACCES/EPERM below the root are skipped), `Services/ScanService.swift:466`, `Services/BaselineService.swift:134-200`, `Services/MenuBarManager.swift:1220` (skip list only feeds a label).
- Failure: Full Disk Access is revoked (or Desktop/Documents access is denied) while the app runs. The next full scan skips those folders, still marks the snapshot complete, rebuilds the working set without them and journals the whole subtree as a shrink ("Documents -80 GB, found by scan"). Re-granting access later journals it again as +80 GB growth. Same on a first scan with TCC denied: the folder later shows up as huge growth.
- Fix: record skipped roots per scan; for each skipped root copy the previous snapshot's rows under that prefix into the new snapshot (or exclude the prefix from `calculateDeltas` and the residual). Also re-check permission before the backstop scan, not only on launch/panel open.

### 3. Watcher counts files the full scan never counts - MED-HIGH, confidence high
- Where: `Services/RecentChangeService.swift:192-214, 266-281` vs `Services/FileScanner.swift:446-496`.
- Failure: the scanner skips Photos libraries, `Library/Mail`, `Saved Application State`, iCloud `Mobile Documents`, and custom-ignored folder names. The watcher refreshes single files with `lstat` and no skip check, and subtree refreshes only check names below the refresh root. Photos or Mail writing a few GB shows live growth, then the next full scan rebuilds the working set without those files and journals the same amount as a shrink. The list shows a grow-then-shrink pair for a place that is not even in the inventory.
- Fix: one skip predicate applied to every path (all ancestors, not only the leaf name) in the scanner, the watcher targets and the noise filter.

### 4. Age-based cleanup can delete every snapshot of a path - MED, confidence high
- Where: `Services/DatabaseCleanupService.swift:690-700` (`createdAt < cutoff` with no "keep newest"), effects in `Services/MenuBarManager.swift:2142` and `Services/BaselineService.swift:140`.
- Failure: no successful full scan for 30+ days (laptop off over a holiday, app quit, or scans failing every time, see 8). On launch, startup maintenance deletes all snapshots. `noBaseline` becomes true, which stops the watcher and the backstop scan, and the UI drops to the first-run state. The next scan counts as a first scan and `deleteGrowthJournalBuckets` wipes the path's history.
- Related: `cleanupOldSnapshotEntries` (`:612-627`) keeps the 2 newest payloads without filtering `lifecycle`, so leftover `scanning` rows can push the latest complete snapshot's entries out. The next diff then reports the whole tree as new growth.
- Fix: never delete, or strip entries from, the newest complete snapshot of each tracked path. Filter both queries to `lifecycle = 'complete'`.

### 5. "Whole disk" scope may skip all user data (FTS_XDEV and firmlinks) - HIGH if confirmed, confidence low-med
- Where: `Services/FileScanner.swift:298` (`FTS_XDEV`), scope from `Models/OnboardingFlow.swift:43`.
- Failure: on APFS, `/` is the sealed system volume. `/Users`, `/Applications`, `/Library` and `/private/var` are firmlinks into the Data volume, which has a different `st_dev`. If fts reports the Data volume's device for them, `FTS_XDEV` prunes them and a whole-disk scan counts only the system volume.
- Verify first (1 minute on the Mac): `stat -f %d / /Users /System/Volumes/Data`, and the file count of a "/" scan against a home scan.
- Fix if confirmed: scan `/System/Volumes/Data` (plus `/` without descending into it) for the whole-disk scope, or allow the Data volume's device as well as the root's.

### 6. Sleep or a clock step during a full scan aborts it as "stalled" - MED, confidence med-high
- Where: `Services/FileScanner.swift:62-98, 187-199, 241-258` (watchdog compares `Date()` values).
- Failure: lid closed mid-scan. On wake the watchdog sees more than 30 s since the last progress and finishes the stream with `ScanError.stalled`. That counts as a failed full scan with backoff; on the first-run scan the user sees "Scan failed". An NTP or manual clock jump forward does the same.
- Fix: measure stall time on a clock that pauses during sleep (`SuspendingClock` or `ProcessInfo.systemUptime`), or reset `lastProgressAt` on `NSWorkspace.didWakeNotification`.

### 7. Running Prunr outside /Applications blinds the watcher to that folder - MED, confidence high
- Where: `Services/MenuBarManager.swift:3527-3546`.
- Failure: `autoScanIgnoredRoots` contains the app bundle's parent folder, and the match is `hasPrefix` without a trailing "/". A tester running Prunr from `~/Downloads` (or after a Sparkle update in place there) loses every watcher batch that touches only Downloads. A typical download is such a batch, so Downloads growth only appears later as an approximate scan residual. `~/Downloads-old` matches too. Also, the filter drops a batch only when all of its paths match; mixed batches keep every path, so behavior depends on batching.
- Fix: ignore only the bundle itself; match on `root + "/"`; filter per path, not per batch.

### 8. One unavailable tracked path fails every full scan - MED, confidence high
- Where: `Services/MenuBarManager.swift:1196-1215` (single throwing `withThrowingTaskGroup`).
- Failure: an extra tracked folder on an external drive is unplugged. Its scan throws `invalidPath`, the group cancels the other paths, and no path gets a fresh snapshot. `completedSnapshotsByPath` stays empty, so the journal prune is skipped too, and backoff grows. Left alone for 30 days, this leads into 4.
- Fix: collect per-path results (non-throwing child tasks returning `Result`), skip roots that are missing, and report partial success.

### 9. A root that vanishes mid-scan publishes a near-empty snapshot - MED, confidence med-high
- Where: `Services/FileScanner.swift:433-437` (ENOENT/ESTALE are transient at any level, including level 0).
- Failure: an external volume is ejected, or the tracked folder is moved, during a scan. The remaining entries fail with ENOENT, are skipped, and the scan completes. The whole tree is journaled as a shrink and the working set is emptied; it reappears as growth on the next scan.
- Fix: abort on errors at level 0. Before `markSnapshotComplete`, re-check that the root still exists on the same `st_dev`, and abort otherwise.

### 10. Hard links and clones are counted once per link - MED-LOW, confidence high
- Where: `Services/FileScanner.swift:346-358`, `Services/RecentChangeService.swift:266-281`.
- Failure: pnpm stores, Xcode/simulator data and other tools hard-link files. Every link adds its full `st_blocks`, so place totals, category totals and growth are inflated (a 2 GB store linked into 5 projects reads as 12 GB). APFS clones (Finder duplicate) are counted in full too; that is harder to fix and can be documented.
- Fix: when `st_nlink > 1`, count `(st_dev, st_ino)` once per scan; the watcher path needs the same rule or a scan-time correction.

### 11. Crash or quit after "complete" loses the window's history - MED-LOW, confidence high
- Where: `Services/ScanService.swift:466` marks complete, then `Services/BaselineService.swift:134-219` rebuilds the working set, writes the residual and, on a first scan, the file-date history.
- Failure: the app quits (Sparkle relaunch, logout) after `rebuildWorkingSet` but before the residual is written. The next scan uses the new snapshot as its baseline, so that window's changes are never journaled. On a first scan, a quit before `recordFileHistory` means the pre-install history is never built (later scans are no longer "first").
- Fix: publish last. Write working set, residual and history first, then flip `lifecycle` (ideally the residual and the flip in one transaction).

### 12. Scope change or reset races an in-flight scan - LOW-MED, confidence med
- Where: `Services/MenuBarManager.swift:1092-1119`, `Views/SettingsView.swift:517-540` (Apply is disabled only while scanning, so a scan that starts while the confirmation dialog is open slips through), `Services/BaselineService.swift:93-94`.
- Failure: `resetBaseline` deletes complete snapshots while an old-scope scan runs. That scan finishes, rebuilds the working set for the old scope and diffs against a previous snapshot id that no longer exists, so `calculateDeltas` reports the whole old tree as new growth. The base path keeps the fixed `mainBasePathID`, so this stale snapshot becomes the new scope's baseline.
- Fix: in `applyScopeChanges` and `performReset`, call `ScanService.cancelScan()` and wait for `isLoading`, `isProcessingRecentChanges` and `isReconciling` to clear before deleting.

### 13. Noise filter hides real multi-GB growth of other apps - LOW-MED, confidence high
- Where: `Services/FSEventsNoiseFilter.swift:10-39`.
- Failure: `-wal`, `-shm`, `-journal`, `.tmp` and `~` suffixes, plus `Library/WebKit/` and `Library/Metadata/`, are ignored for every app. SQLite WAL files and WebKit stores can grow by GBs. The full scan counts them, so they only appear as "found by scan" with no time. `PrunrInternalPaths.isInternalPath` already limits the WAL rule to Prunr's own folder; the noise filter undoes that.
- Fix: limit the suffix rules to Prunr's own directories; keep only truly tiny names (`.DS_Store` and similar) global.

### 14. Wall-clock ordering and windows break on clock skew - LOW, confidence med
- Where: `Database/DatabaseManager.swift:878-882` (`ORDER BY createdAt`), `Services/BaselineService.swift:179-183` (window), `Services/DatabaseCleanupService.swift:236-239`.
- Failure: a snapshot taken with the clock set ahead stays "latest" after the clock is corrected. Later windows `(previous.createdAt, now]` are empty, so each residual equals the full delta and double-counts watcher rows. The abandoned-snapshot rule `createdAt > MAX(updatedAt)` can then delete valid complete snapshots at launch.
- Fix: order snapshots by `id`; base the residual window on the previous snapshot's id/sequence; clamp journal writes to `max(now, lastSnapshot.createdAt)`.

### 15. Diagnostics path redaction stops at the first space - LOW, confidence high
- Where: `Extensions/PerfSignpost.swift:111-113`.
- Failure: the pattern ends at whitespace, so `~/Client Name/Contract.pdf` becomes `<redacted-path> Name/Contract.pdf`. Today no code path writes raw paths into the log (only counts and error codes), so this is defense in depth that does not hold.
- Fix: redact from the path start to the end of the token list or line; add a test with spaces and unicode names.

## Also noted (low)

- `BaselineService.acceptGrowth` / `MenuBarManager.acceptGrowth` have no callers. If revived: the snapshot it creates is newer than every working-set `updatedAt`, so `cleanupAbandonedSnapshots` deletes it at the next launch, and older snapshots were already deleted. Remove it or stamp working-set rows.
- A tracked root that is a symlink scans 0 files (`fts_open` without `FTS_COMFOLLOW` returns `FTS_SL` for the root), and watcher paths (FSEvents real paths) never match it. NSOpenPanel normally resolves links, so this is rare.
- Case-sensitive volumes: `paths.path` is `UNIQUE COLLATE NOCASE`, so `A.txt` and `a.txt` share one id and one working-set row (undercount).
- Dead network mount points inside the scope (whole disk, `/Volumes/*`): fts stats an entry before the `FTS_XDEV` check, so a hung SMB mount blocks `fts_read`. The watchdog ends the stream, but the producer thread stays blocked; every retry leaks one.
- `FileScanner` applies `ignoredNames` only to directories; ignored file names (`.DS_Store`) are still counted. Tiny bytes.
- Unverified: GRDB checks foreign keys after migrations by default; v7 copies `snapshotEntry` rows before v9 removes orphans, so a pre-v7 database with orphan rows could fail to migrate. Only matters for very old databases.

## Checked, fine

- Backpressure gate: close on cancel, error and termination; no lost wakeups; producer stops after close.
- Failed or cancelled scan cleanup runs in a detached task that outlives cancellation; `scanning` snapshots are excluded from every read (`fetchAllSnapshots`, `fetchRecentSnapshots`, oldest date, free space); abandoned rows are removed after a 15-minute grace.
- Subtree refresh: staging, diff, delete and insert happen in one write transaction; staging is cleared at launch; per-file replace is atomic.
- Residual math: watcher batches held during a full scan land after `snapshot.createdAt`, so each window's journal total equals the snapshot delta.
- Journal prune: one transaction per local day, fold and delete together, cross-cutoff runs held whole; day math uses `Calendar.date(byAdding: .day)` (DST-safe); `FileDateHistory` drops future-dated files and the Trash.
- Migrations v20-v27: additive; v23/v24 clear the journal and restart `HistoryStart`; drilldown rebuild is flagged per path and runs in write transactions.
- Sendable rule from lessons.md: reviewed reads map `Row` inside the closure.
- FSEvents: dropped/kernel/user/root-changed flags force a rescan; the retain of the callback context is balanced; scheduled on the main queue.
- Inventory refresh gate is always released (`defer`); progress stream is torn down only after all scan tasks return.
- Feedback: diagnostics carry counts and codes only, plus path redaction; transport errors map to a mailto fallback; 30 s timeout. Sparkle: HTTPS feed with an EdDSA key; the updater is disabled when either is missing.
