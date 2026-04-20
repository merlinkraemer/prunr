# Beta Audit Phase 1 Handoff

Date: 2026-04-17 18:51 +07
Repo: `merlinkraemer/prunr`
Checkpoint before implementation: `65a3b0e` (`chore: checkpoint before beta audit phase 1`)
Status: parked after manual crash on first scan

## What landed locally

- Excluded app-private watcher roots before watcher stream creation.
- Kept SQLite sidecar filtering (`-wal`, `-shm`, `-journal`) as secondary watcher noise suppression.
- Removed the scan-complete watcher flush.
- Removed the extra `RunLoop.main.perform { MainActor.assumeIsolated { ... } }` wrapper from watcher delivery.
- Replaced `workingSetCategoryTotal` read-modify-write loops with SQL delta updates plus zero-row cleanup.
- Added focused smoke coverage for watcher delivery, SQLite sidecar filtering, and zero-total working-set cleanup.

## Local verification completed

- `make build` passed.
- Focused `xcodebuild test` run passed for:
- `PrunrTests/PrunrSmokeTests/testFSEventsWatcherReportsRealFilesystemChanges`
- `PrunrTests/PrunrSmokeTests/testFSEventsNoiseFilterIgnoresSQLiteSidecars`
- `PrunrTests/PrunrSmokeTests/testRecentChangeRefreshUpdatesVisibleInventoryFromWorkingSet`
- `PrunrTests/PrunrSmokeTests/testRecentChangeRefreshPromotesTrackedRootDirectoryEventToFullScan`
- `PrunrTests/PrunrSmokeTests/testMenuBarManagerRetainsPendingRefreshWhenWatcherRequiresFullRescan`
- `PrunrTests/PrunrSmokeTests/testWorkingSetCategoryDeltasDeleteZeroTotalsWithoutReadback`

## Manual result

- App crashed on the first live scan.
- This happened before validating whether scan completion still triggered an immediate follow-up scan.
- All running `Prunr` instances were killed after the crash so the machine is parked cleanly.

## Current uncommitted files

- `Prunr/Database/DatabaseManager.swift`
- `Prunr/Services/FSEventsNoiseFilter.swift`
- `Prunr/Services/FSEventsWatcher.swift`
- `Prunr/Services/MenuBarManager.swift`
- `PrunrTests/PrunrSmokeTests.swift`
- `docs/todo.md`

## Most likely next step

1. Reproduce the first-scan crash under Xcode or from the installed app with crash logs captured.
2. Check whether the crash is in the new watcher path, scan pipeline, or an unrelated pre-existing first-scan path.
3. Only after crash triage, resume the original manual Phase 1 gate:
   `npm run monitor -- --samples 20 --interval 5`
   then confirm scan completion does not immediately trigger a second scan.

## Notes

- Focused tests still emit pre-existing SQLite misuse / `GrowthJournalService` warnings during `testRecentChangeRefreshPromotesTrackedRootDirectoryEventToFullScan`; that path still passed and was not part of this crash pass.
- No post-implementation commit was created after the checkpoint.
