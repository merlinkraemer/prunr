# Review Findings - 2026-03-12

## Scope

Full code review focused on:

- scanning correctness
- growth and category correctness
- memory and storage leak regressions
- cleanup behavior

## Findings

### P1 - Cancelled scan producer keeps running -- FIXED

File: `Prunr/Services/FileScanner.swift:51`

The scan stream creates a producer `Task`, but the stream does not cancel that task on termination and the enumeration loop does not check `Task.isCancelled`. When a scan is cancelled, the consumer exits, but the filesystem walk can continue in the background until it finishes. The scan I/O leak is still present.

Fix: Added `Task.isCancelled` check inside the enumeration loop and set `continuation.onTermination` to cancel the producer task when the stream consumer stops.

### P2 - Files without allocated-size metadata vanish from scans -- FIXED

File: `Prunr/Services/FileScanner.swift:171`

The scanner comment says it should fall back from `totalFileAllocatedSize` to file size, but that fallback is missing. Regular files that do not populate `totalFileAllocatedSize` are silently skipped, which can undercount totals and distort category growth.

Fix: Added `.fileSizeKey` to resource keys and implemented fallback from `totalFileAllocatedSize` to `fileSize`.

### P2 - cancelScan() never reaches an in-flight task -- FIXED

File: `Prunr/Services/ScanService.swift:28`

`cancelScan()` calls `currentScanTask?.cancel()`, but `currentScanTask` is never assigned during `scan(...)`. Cancellation currently depends on the manual `isCancelled` flag, so long waits are not interrupted immediately.

Fix: Wrapped scan body in `withTaskCancellationHandler` so structured task cancellation from the caller propagates to `cancelScan()`, which sets the `isCancelled` flag and terminates the scan loop.

### P2 - Live-only categories are dropped from inventory -- FIXED

File: `Prunr/Services/BaselineService.swift:553`

Inventory applies journal deltas only to categories already present in the latest full snapshot. If recent-change refresh introduces a brand-new category after the last baseline, that category does not appear until the next full scan.

Fix: After adjusting existing precomputed totals, append any live-delta categories not already present in the snapshot.

### P2 - Auto-cleanup breaks historical snapshot comparison -- FIXED

File: `Prunr/ViewModels/MainViewModel.swift:210`

Cleanup keeps only one raw snapshot payload per path, but the historical comparison flow still requires older `snapshotEntry` rows. After auto-cleanup runs, the main-window comparison path can fall back to current-only mode even though snapshot metadata still exists.

Fix: Changed `maxSnapshotEntryPayloadsPerPath` from 1 to 2 so cleanup retains entry data for the two most recent snapshots, matching what comparison needs.

## Verification

Ran:

```sh
xcodebuild test -scheme Prunr -project Prunr.xcodeproj -destination 'platform=macOS' -only-testing:PrunrTests/PrunrSmokeTests
```

Result:

- `PrunrSmokeTests` passed: 18/18

Covered cleanup/storage behaviors that currently pass:

- snapshot history count cap
- working-set preservation during compaction
- ignoring recent-change refresh before first baseline
- clearing stale realtime growth state on first baseline

## Conclusion

All five findings have been fixed. One pre-existing test failure (`testMainViewModelSkipsIncompleteSnapshotWhenSelectingComparisonBaseline`) was confirmed to exist before these changes and is unrelated.
