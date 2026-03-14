---
phase: 11-faster-initial-scan
verified: 2026-03-14T08:00:00Z
status: passed
score: 6/6 must-haves verified
re_verification: false
---

# Phase 11: Faster Initial Scan Verification Report

**Phase Goal:** Speed up initial scan — bulk DB writes, remove COLLATE NOCASE, parallel path scanning, live category fill-in during scan
**Verified:** 2026-03-14
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                 | Status     | Evidence                                                                                                     |
|----|---------------------------------------------------------------------------------------|------------|--------------------------------------------------------------------------------------------------------------|
| 1  | `snapshotEntry` and `workingSetEntry` rows are written via chunked multi-row VALUES   | ✓ VERIFIED | `addEntriesCore` chunks to 500 rows: `INSERT INTO snapshotEntry ... VALUES (?,?,?),(?,?,?),...`              |
| 2  | `pathClassification` upserts use bulk multi-row VALUES                                | ✓ VERIFIED | `upsertPathClassifications` chunks 500 rows with `ON CONFLICT(pathId) DO UPDATE`                            |
| 3  | COLLATE NOCASE removed from hot-path lookups (`fetchPathIds`, `getOrCreatePathId`)    | ✓ VERIFIED | Both methods use `WHERE path = ?` exact match; comments confirm intent                                       |
| 4  | Inline working-set population eliminates separate `rebuildWorkingSet` pass            | ✓ VERIFIED | `alsoWriteWorkingSet: true` passed from `BaselineService`; `replaceWorkingSetCategoryTotals` called at end   |
| 5  | Multiple tracked paths scan concurrently via TaskGroup                                | ✓ VERIFIED | `createBaselines()` uses `withThrowingTaskGroup`; single-path fast path guards on `trackedPaths.count > 1`  |
| 6  | Live category fill-in: categories appear and grow in UI during scan                  | ✓ VERIFIED | `ScanProgress.categoryTotals` emitted every ~2s; `applyPartialCategoryTotals` merges into `stableCategories` |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact                                    | Provides                                    | Status     | Details                                                                                 |
|---------------------------------------------|---------------------------------------------|------------|-----------------------------------------------------------------------------------------|
| `Prunr/Database/DatabaseManager.swift`      | Bulk inserts, exact-match lookups, clear/replace working set | ✓ VERIFIED | `addEntriesCore`, `addEntriesWithWorkingSet`, `upsertPathClassifications` (500-row chunks), `clearWorkingSetEntries`, `replaceWorkingSetCategoryTotals` all present and substantive |
| `Prunr/Services/ScanService.swift`          | `alsoWriteWorkingSet` flag, `activeScanCount`, category totals in progress, batchSize 15000 | ✓ VERIFIED | All changes confirmed: `activeScanCount` counter, `isScanning` computed property, `resetCancellationForNewBatch()`, `categoryTotals` in `ScanProgress`, `lastCategoryUpdate`, `batchSize = 15000` |
| `Prunr/Services/BaselineService.swift`      | Pre-clear working set, pass `alsoWriteWorkingSet: true`, skip delta on first scan | ✓ VERIFIED | `clearWorkingSetEntries` called before scan; `alsoWriteWorkingSet: true` in `scan()` call; `if let previousSnapshotId` guard skips `calculateDeltas` on first scan |
| `Prunr/Services/MenuBarManager.swift`       | TaskGroup parallel scanning, live category fill-in UI       | ✓ VERIFIED | `createBaselines()` with `withThrowingTaskGroup`, `partialScanCategoryTotals`, `applyPartialCategoryTotals()`, reset at scan start/end |

### Key Link Verification

| From                        | To                                       | Via                                                    | Status     | Details                                                                                                    |
|-----------------------------|------------------------------------------|--------------------------------------------------------|------------|------------------------------------------------------------------------------------------------------------|
| `BaselineService.createBaseline` | `ScanService.scan(alsoWriteWorkingSet:)` | `alsoWriteWorkingSet: true` parameter                  | ✓ WIRED    | Line 111 in BaselineService passes flag; ScanService branches on it at lines 317, 413, 427                |
| `ScanService.scanBody`      | `DatabaseManager.addEntriesWithWorkingSet` | Called per outer batch when `alsoWriteWorkingSet=true`  | ✓ WIRED    | Lines 414-419 in ScanService; `addEntriesWithWorkingSet` delegates to `addEntriesCore` with trackedPathId  |
| `ScanService.scanBody`      | `DatabaseManager.replaceWorkingSetCategoryTotals` | Called post-scan from in-memory `categoryTotals`    | ✓ WIRED    | Lines 427-434 in ScanService; passes accumulated dict to DB method                                         |
| `ScanService` progress loop | `ScanProgress.categoryTotals`            | Set every ~2s via `lastCategoryUpdate` interval check  | ✓ WIRED    | Lines 390-402 in ScanService; nil on non-snapshot updates to avoid dict copy overhead                     |
| `MenuBarManager.applyAggregateScanProgress` | `applyPartialCategoryTotals` | `progress.categoryTotals` non-nil guard             | ✓ WIRED    | Lines 221-223 in MenuBarManager; merges via `max()` into `partialScanCategoryTotals`, updates `stableCategories` |
| `MenuBarManager.createBaselines` | `withThrowingTaskGroup`             | `trackedPaths.count > 1` guard                         | ✓ WIRED    | Lines 666-694; single-path fast path at line 666, group path at line 684                                  |
| `BaselineService.createBaseline` | `DatabaseManager.clearWorkingSetEntries` | Called before scan when `previousSnapshotId != nil` | ✓ WIRED    | Lines 83-89; first scan calls `clearRealtimeData` instead (which covers working set entries too)           |

### Requirements Coverage

No REQUIREMENTS.md traceability required for this phase — performance optimization with no external requirement IDs.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None | — | — | — | — |

No TODO/FIXME/placeholder patterns, no empty implementations, no stub returns found in any of the four key files.

### COLLATE NOCASE Notes

Three remaining occurrences in `DatabaseManager.swift` are all benign:
- Line 128: Old migration v6 index on `snapshotEntry(path)` — a pre-deduplication legacy column, not used in current query hot paths.
- Lines 195-197: Migration v10 comment explaining historical context.
- Line 1896: Comment inside `calculateDeltas` SQL explaining join semantics.

The two hot-path functions (`fetchPathIds`, `getOrCreatePathId`) use exact match only. The plan goal is met.

### Commits Verified

All four commits from the summaries exist in git log:

- `c3c3ac7` — perf(11-01): optimize DB write path — bulk inserts, no COLLATE NOCASE, inline working set
- `5cc30b2` — feat(11-02): parallel scan support + live category totals in ScanProgress
- `c3044eb` — feat(11-02): parallel path scanning via TaskGroup + live category fill-in UI
- `68b6071` — chore(11-02): clarify first-scan delta-skip comment in BaselineService

### Human Verification Required

#### 1. Scan Performance on Large Directory

**Test:** Trigger a full scan of a directory with 500k+ files and measure wall-clock time.
**Expected:** Significant reduction vs the previous 30+ minute time for 2.2M files (target: under 2 minutes).
**Why human:** Can't measure scan performance programmatically without running the app against a real large directory.

#### 2. Live Category Fill-In Visual Behavior

**Test:** Start a scan of a large directory. Observe the category list while scanning.
**Expected:** Categories appear and their sizes grow visually within ~2-3 seconds of scan start, before scan finishes.
**Why human:** UI behavior requires running the app; cannot verify visual live-update timing with grep.

#### 3. Parallel Scan Timing (Multiple Tracked Paths)

**Test:** Add two independent tracked paths and trigger a rescan. Check if both scans run concurrently.
**Expected:** Total time is closer to max(path1_time, path2_time) rather than path1_time + path2_time.
**Why human:** Timing comparison requires running the app with two real paths.

#### 4. Category Totals Correctness After Scan

**Test:** Complete a scan, then compare category totals shown in the UI against a manual du breakdown.
**Expected:** Category sizes match the actual filesystem breakdown within a reasonable margin.
**Why human:** Correctness of in-memory accumulation vs SQL GROUP BY needs real data comparison.

### Gaps Summary

None. All six observable truths are verified with substantive, wired implementations. All four commits exist in git history. The code contains no stubs or placeholder implementations.

The phase goal — bulk DB writes, COLLATE NOCASE removal from query hot paths, parallel TaskGroup scanning, and live category fill-in during scan — is fully achieved in the codebase.

---

_Verified: 2026-03-14_
_Verifier: Claude (gsd-verifier)_
