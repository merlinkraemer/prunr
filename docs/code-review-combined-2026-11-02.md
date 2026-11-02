# Combined review: drain/hands-on-2-2026-11-02 (fa13b78)

Scope: `git diff 85ef096..fa13b78` (O23a-d, O24a-e, O26, O27a-b, O28a-c merged on drain/stack-2026-11-01). Correctness only: interaction bugs that no single branch's tests cover. Read-only review of the source at fa13b78; nothing was compiled or run.

Prior reviews: `docs/code-review-2026-11-02.md`, `docs/perf-app-review-2026-11-02.md`.

## Findings (ranked)

### 1. High - the watcher deletes denied subtrees that the full scan carries forward (O23c x O23b / RecentChangeService)

- `Prunr/Services/RecentChangeService.swift:200` and `:219` - `FileManager.fileExists` returns false when `stat` fails with EACCES or EPERM, so a path inside a permission-denied folder becomes a `.removal`.
- `Prunr/Database/DatabaseManager.swift:1748` and `:1756` - the removal deletes the exact row, or falls back to deleting the whole subtree under that path.
- `Prunr/Services/RecentChangeService.swift:149` and `:168` - a subtree refresh scans with no skip log, so denied folders inside the subtree are just missing from staging. `replaceWorkingSetSubtree` then drops their rows too.
- `Prunr/Services/ScanService.swift:423` - since O23c, a full scan copies denied subtrees forward from the previous complete snapshot, so those rows now exist in the working set and in the snapshot. Before O23c they were dropped on both sides, so the watcher had nothing to remove.

Scenario: `~/Library/Containers/X` was readable in snapshot N. Then access is lost (Full Disk Access was reset by a re-signed alpha update, or the folder's mode changed). Scan N+1 carries X's entries forward. The app inside X writes a file, and FSEvents reports `~/Library/Containers/X/Data/foo`. `fileExists` returns false, so the change becomes a removal. If `foo` is in the working set its row is deleted, and a directory event removes the whole subtree. The journal records a shrink of X's size, and the next full scan carries X forward again and books the same amount back as growth. This repeats every cycle, so the change feed shows fake shrink and growth pairs for exactly the folders O23c meant to protect.

Fix: in `refreshTargets`, call `lstat` and branch on errno. Only ENOENT and ENOTDIR mean the path is gone. For EACCES and EPERM, skip the path and leave its working-set rows alone. In `applySubtreeRefresh`, pass a `ScanSkipLog` to `scanner.scan`. If anything was denied, either keep the existing rows under the outermost denied roots (exclude them from the subtree replace) or return `.needsFullScan`.

### 2. High - hard links are counted three different ways (O24d scanner vs watcher, plus subtree refresh)

- `Prunr/Services/FileScanner.swift:242` and `:406` - a full scan gives the first link it sees (in FTS order) the full size and every later link 0.
- `Prunr/Services/RecentChangeService.swift:276` - a file-level watcher refresh gives each link `size / st_nlink`. The link count includes links outside the tracked root and links in skipped folders.
- `Prunr/Services/RecentChangeService.swift:149` - a subtree refresh runs the scanner with a fresh `seenLinks`, so the first link inside the subtree gets the full size even if the full scan already counted the other link elsewhere.

Scenarios:
- A file has 2 links, both under the root. The full scan stores A=S and B=0. Editing A in place gives a watcher delta of S'/2 - S, which is a fake shrink of about S/2. Editing B gives a fake growth of S/2.
- pnpm or a local `git clone` hard-links a store into `node_modules`. The full scan counts the store copies in full and the `node_modules` copies as 0. A subtree refresh of `node_modules/foo` (for example, a folder moved in) now counts every file in full again, which double-counts in the working set until the next full scan.
- Deleting the first-seen link removes S from the working set while the disk still holds the data under the other link.
- Across full scans the full size moves to whichever link FTS reaches first. When links are added, the size can jump between categories or units, producing paired fake growth and shrink.

Fix: use one rule that does not depend on traversal order, everywhere. The simplest is `size / st_nlink` in `FileScanner.countedBytes` as well. It is additive across partial refreshes and matches the watcher. If the full scan must stay first-seen, then the watcher has to look up the existing working-set value for every other link of that inode, which needs an inode index. That is much heavier.

### 3. Medium - partial multi-path success hides per-path failures and drops their pending work (O24c x watcher dirty refresh / backoff)

- `Prunr/Services/MenuBarManager.swift:1242-1260` - a failed path is only logged. `recordFullScanSuccess()` still runs and `loadInventory` returns `true` (`:1487`).
- `Prunr/Services/MenuBarManager.swift:1313` - `loadInventory` clears `pendingRecentChangePaths` for every path when it starts.
- `Prunr/Services/MenuBarManager.swift:3131-3143` - the dirty refresh clears pending state and `needsAuthoritativeReconciliation` before calling `loadInventory`. It restores them only when `loadInventory` returns `false`.

Scenario: there are two tracked paths. Path B gets an FSEvents must-rescan (dirty), and the full scan of B aborts on the O24a watchdog (`ScanError.stalled`) or O24a root-vanished check, or fails with permission denied at the root. Path A succeeds, so the call counts as success. B's dirty flag and pending paths are already gone. No failure is recorded, so the backoff and cooldown don't engage, and `lastAutomaticScanAt` moves forward. B keeps its old working set until the next scheduled interval. `runtimeBlockedLocations` and `errorMessage` are never set for B's permission error. Before O24c, the whole call threw, so the dirty refresh re-armed and `recordFullScanFailure` ran.

Fix: return the failed paths (`[UUID: Error]`) from `createBaselines`. In `loadInventory`, when any path failed: keep or re-arm `pendingRecentChangeRequiresFullRefresh` and `needsAuthoritativeReconciliation` for those paths, call `recordFullScanFailure`, map `.permissionDenied` into `runtimeBlockedLocations`, and don't advance `lastAutomaticScanAt` for the failed paths.

### 4. Low - the drilldown no-op skip leaves file lists stale (O28a/perf 9499092)

- `Prunr/Services/DrilldownStore.swift:57` - `reload` skips everything, including re-reading the loaded file lists of expanded categories, when the group rows are equal. Rows only hold `totalBytes`, `fileCount` and `isTopShort` per group.

Scenario: the user has a category expanded, and a file in it is renamed (same size), or one file grows by X while another in the same group shrinks by X. The group totals and counts don't change, so the list keeps showing the old path or the old top-N order. Reveal in Finder then points at a path that no longer exists. This persists until some other change alters a group total.

Fix: only skip when `loadedFileCategories` is empty. Otherwise, still re-read the files of the loaded categories (keeping the cheap group skip), or add a working-set change counter to `DrilldownGroupsSnapshot`.

## Checked and clean (the pairs named in the brief)

- O24e publish-last x O23c carry-forward x O27b id order: carry-forward reads `fetchRecentSnapshots(limit: 1)`, which is complete-only and ordered by id. The in-flight snapshot is pending, so the source is the true previous snapshot. Entry cleanup (`maxSnapshotEntryPayloadsPerPath = 2`, complete-only by id) keeps that snapshot's payload. Pagination in `fetchEntries` (root row first, then `> afterPath`) is correct.
- O24e partial publish: if a step after `rebuildWorkingSet` throws (including a GRDB `CancellationError` when the reconcile task is cancelled), the snapshot is deleted but the working set stays rebuilt. The next scan's residual (authoritative minus recorded since the previous complete snapshot) still reconciles, so this is not counted as a bug.
- O26 quiesce x O28c gated open: quiesce waits on the MenuBarManager flags, which cover the whole `createBaseline` call including publish. All UI entry points and the 60 s timer go through `isDatabaseOpening`. No path touches `dbPool` while it opens off-main.
- O28b chunked reservation x O24a watchdog: the producer only waits when its reserved slots are used up, so `outstanding` never holds unused slots at a wait. No deadlock with `maxOutstanding = 2 * batchSize`. Consumer-wait timing and the uptime clock are consistent. Carried-forward batches over-release after the gate is closed, which is harmless because `release` clamps at 0.
- O27a noise filter x O23b batch transaction: the dropped suffix rules are covered by `PrunrInternalPaths.isInternalPath` for Prunr's own DB. Each point change runs in its own savepoint, so a bad path rolls back alone.
- O23b FSEvents on its own queue: `stop()` blocks on `queue.sync` until in-flight callbacks finish, and late `main.async` batches are dropped by `guard isRunning` on the old watcher instance. No deadlock, because callbacks never wait on main.
- Xcode 16.4 (Swift 5 mode): checked by reading only, not compiled. The new async DB closures return `Sendable` values (tuples, `WorkingSetPointBatchResult`), not `[Row]`, and the `Task.detached` and `TaskGroup` result types are `Sendable`. No blockers found.
