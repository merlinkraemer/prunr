# Test gap audit: Prunr/Services + MenuBarManager (2026-11-01)

Source: drain/integration-2026-10-31 @ ce98857, read-only, static analysis (no Swift on box, nothing run).
Method: grep of type and method names across PrunrTests. "Covered" means a test calls the method, not that every branch is hit.

## Test patterns to reuse

- DB isolation: `PrunrTestCase.withTemporaryDatabase { trackedPathId, snapshotId in }` (or `withEmptyTemporaryDatabase`). Each call inits `DatabaseManager.shared` at a temp sqlite file and closes it after. Singleton, so DB tests must not run in parallel.
- Real folders: `createTrackedPathDirectory(named:)`, `FixtureLibrary`, `ReplayHarness` for scripted event runs.
- Pure logic is split out as `static` functions (`startupMaintenancePlan`, `vacuumWorthwhile`, `HistoryStart`, `GrowthJournalService.weekStart`) and tested without a DB. Keep that style.
- Most service tests live in the 2393-line `PrunrSmokeTests.swift`; new files per area are easier to review.

## Per-file map

| File | Responsibility | Covered by | Untested risky paths |
|---|---|---|---|
| ScanService | Orchestrates scan, cancel tokens, failed-scan rollback | Smoke (`testFirstScanFailureKeepsOnboardingBaselineState`), BaselineServiceRegression (cancelled scan) | `cancelScan()`, `scanWithDrilldownIndex`, `restoreWorkingSetAfterFailedInlineScan` (no direct test), `captureVolumeFreeSpace` |
| FileScanner | Traversal, watchdog, skips | FileScannerWatchdog (4), Smoke (FTS errors, unreadable entries, internal files, backpressure) | Symlink loops, permission-denied mid-scan on the root, package/bundle sizing |
| BaselineService | Baseline, growth list, accounting, inventory | BaselineServiceRegression (16), DrilldownIndex, FileDateHistory | `getDiskAccounting` (0 refs), `resetBaseline` (0), `drillDown` (0), `comparableBaselineSnapshotId` (0), `getCategoryInventory` (0) |
| DatabaseCleanupService | Retention, abandoned snapshots, vacuum, backfill | Smoke (abandoned x4, category history cap, `performAutoCleanup`), StartupMaintenancePlan (11, pure) | `cleanupOldSnapshotEntries` (0), `cleanupOrphanedPaths` (0), `backfillRecentCategorySnapshots` (0), `compactDatabaseNow` (0), `aggregateCategoryTotalsForOldSnapshots` |
| GrowthJournalService | Journal buckets, stories, feed, prune, HistoryStart | ChangeFeedStore, GrowthJournalDetail, BaselineServiceRegression, EpisodeBuilder | `deltasSinceLastSnapshot` (0), `oldestCompleteSnapshotDate` (0), `bucketStart` DST edge, `prune` boundary on exact cutoff |
| RecentChangeService | Applies watcher batches to working set/journal | ChangeFeedStore, Smoke (promotion to full scan) | Rename/move pair handling, event for deleted-then-recreated path |
| FSEventsWatcher / NoiseFilter | Live events, scope clamp, filtering | Smoke (real FS test, sidecars, dir-heavy), MenuBarManagerRegression (scope clamp x9) | Stream restart after error, `kFSEventStreamEventFlagMustScanSubDirs` path, overflow |
| DrilldownStore | On-demand drilldown index | DrilldownIndex/OnDemand/NavigationGuard, OwnerGroups | Index rebuild after partial failure |
| EpisodeBuilder | Groups journal into episodes | EpisodeBuilderTests (1203 lines) | Well covered |
| DeltaService | Thin wrapper over `calculateDeltas` | none by name | Delta sign, new/removed/renamed rows (SQL lives in DatabaseManager) |
| DiskSpaceService | Free/total bytes | none | Returns 0 on error (`volumeAvailableCapacity ?? 0`), would show "0 free" silently |
| CategoryDetectionService, FirstDayPreview, FeedbackService | Category rules, preview, feedback upload | FeedbackServiceRegression only | Category rule edge cases (rules are covered via UnitRules*) |
| PermissionsService, DevMode, PrunrInternalPaths | TCC/FDA checks, dev flag, own-file filter | Smoke (scope access), SettingsDevMode | Revoked-permission mid-run |
| AppCatalog, UnitIconResolver | App/unit naming and icons | AppCatalog, UnitIcon, UnitResolver, UnitRules* | Well covered |
| MenuBarManager (3555 lines) | UI state machine, scan scheduling, diagnostics | MenuBarManagerRegression (footer, diagnostics redaction, sort, banner, scope clamp), Smoke (pending refresh, dirty batch retention) | Scheduler: retry/backoff wiring (`FullScanRetryBackoff` covers the pure part), sleep/wake, tracked-path add/remove while scanning |
| MarketingScreenshotRenderer, MarketingSample, E2ETestCommand, StressScanCommand | Dev/marketing tooling | Marketing tests only | Low risk, skip |

## Top 10 gaps (risk x ease)

1. **cleanupOldSnapshotEntries retention** - data loss risk: deletes `snapshotEntry` rows beyond 2 newest per path; wrong order would remove the baseline the drilldown needs. Test `testSnapshotEntryCleanupKeepsTwoNewestPerPathAndSnapshotRows`: seed 4 snapshots with entries on one path plus 3 on an empty-path group; call `performAutoCleanup()`; assert entries remain only for newest 2, snapshot and categorySnapshot rows remain, other path untouched. Ease: high (same shape as `testCleanupCapsSnapshotHistoryByCount`).
2. **cleanupOrphanedPaths** - raw `DELETE FROM paths` referenced by snapshotEntry or workingSetEntry; a wrong NOT EXISTS drops live paths. Test `testOrphanedPathsDeletedOnlyWhenUnreferencedByEntriesOrWorkingSet`: three paths (snapshot-only, working-set-only, none); run cleanup; assert only the third is gone. Ease: high.
3. **BaselineService.getDiskAccounting** - numbers shown to user; 0 test refs. Test `testDiskAccountingThrowsInsufficientWithOneSnapshotAndSumsCategoryDeltas`: 1 snapshot expects `.insufficientSnapshots`; with 2 snapshots with known categorySnapshot totals assert growth/shrink totals and unaccounted remainder equal expected. Ease: high (seed via `DatabaseManager`).
4. **resetBaseline / drillDown / comparableBaselineSnapshotId** - reset must clear snapshots, working set, journal, `HistoryStart`; drillDown parent path math. Test `testResetBaselineClearsSnapshotsWorkingSetAndJournalButKeepsTrackedPaths` plus `testDrillDownReturnsOnlyDirectChildrenWithSummedSubtrees`. Ease: medium-high.
5. **Failed scan rollback** (`restoreWorkingSetAfterFailedInlineScan`) - a failed or cancelled scan must restore the prior working set, else the next diff shows phantom growth. Test `testFailedInlineScanRestoresWorkingSetFromLatestCompleteSnapshot`: complete snapshot A, mutate working set, make scan throw (unreadable root fixture or injected cancel), assert working set equals A and no `scanning` snapshot remains. Ease: medium (needs a throwing scan path; `testCancelledFullScanWritesNoJournalBuckets` is the model).
6. **ScanService.cancelScan** - cancels all tokens, 0 direct tests. Test `testCancelScanStopsActiveScanAndLeavesNoCompleteSnapshot`: start `scan` on a large `FixtureLibrary` tree, call `cancelScan()`, expect `ScanError.cancelled` and no new complete snapshot. Ease: medium.
7. **backfillRecentCategorySnapshots + aggregateCategoryTotalsForOldSnapshots** - missing category totals make charts and accounting wrong after upgrade. Test `testStartupMaintenanceBackfillsMissingCategoryTotalsForRecentSnapshots`: snapshots with entries but no categorySnapshot rows, run `performStartupMaintenance()`, assert rows exist and equal `buildCategoryTotals`. Ease: medium.
8. **GrowthJournalService.deltasSinceLastSnapshot / oldestCompleteSnapshotDate / prune cutoff** - "since last snapshot" window decides what the feed claims. Test `testPruneKeepsBucketOnExactCutoffAndDropsOlder` (calendar injected, UTC) and `testOldestCompleteSnapshotDateIgnoresScanningSnapshots`. Ease: high (pure-ish, calendar parameter exists).
9. **DiskSpaceService silent zero** - error returns 0 free, UI could show "0 bytes free". Extract the nil handling or test `getFreeSpace(for: nonexistentURL)` and assert behavior is explicit (nil or error). Test `testFreeSpaceForMissingVolumeIsNotReportedAsZeroFree`. Ease: high, but needs a small production decision first.
10. **compactDatabaseNow report** - manual vacuum returns `MaintenanceReport`; wrong sizes or failure under busy app unreported. Test `testCompactDatabaseNowReportsBeforeAndAfterSizesAndKeepsData`: seed, delete rows, compact, assert after <= before and row counts unchanged. Ease: medium.

## Notes

- MenuBarManager logic is mostly tested through extracted pure helpers; the large untested remainder is scheduling (sleep/wake, add/remove tracked path during a scan). Not ranked: needs a seam first.
- DeltaService is a pass-through; test the SQL in DatabaseManager (`calculateDeltas`) instead, outside this audit's scope.
- Unverified: coverage claims come from name matches, not a coverage run. Run `xcodebuild -enableCodeCoverage YES` on the Mac to confirm before writing tests.
