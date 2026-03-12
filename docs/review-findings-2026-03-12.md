# Review Findings - 2026-03-12

## Scope

Full code review focused on:

- scanning correctness
- growth and category correctness
- memory and storage leak regressions
- cleanup behavior

## Findings

### P1 - Cancelled scan producer keeps running

File: `Prunr/Services/FileScanner.swift:51`

The scan stream creates a producer `Task`, but the stream does not cancel that task on termination and the enumeration loop does not check `Task.isCancelled`. When a scan is cancelled, the consumer exits, but the filesystem walk can continue in the background until it finishes. The scan I/O leak is still present.

### P2 - Files without allocated-size metadata vanish from scans

File: `Prunr/Services/FileScanner.swift:171`

The scanner comment says it should fall back from `totalFileAllocatedSize` to file size, but that fallback is missing. Regular files that do not populate `totalFileAllocatedSize` are silently skipped, which can undercount totals and distort category growth.

### P2 - cancelScan() never reaches an in-flight task

File: `Prunr/Services/ScanService.swift:28`

`cancelScan()` calls `currentScanTask?.cancel()`, but `currentScanTask` is never assigned during `scan(...)`. Cancellation currently depends on the manual `isCancelled` flag, so long waits are not interrupted immediately.

### P2 - Live-only categories are dropped from inventory

File: `Prunr/Services/BaselineService.swift:553`

Inventory applies journal deltas only to categories already present in the latest full snapshot. If recent-change refresh introduces a brand-new category after the last baseline, that category does not appear until the next full scan.

### P2 - Auto-cleanup breaks historical snapshot comparison

File: `Prunr/ViewModels/MainViewModel.swift:210`

Cleanup keeps only one raw snapshot payload per path, but the historical comparison flow still requires older `snapshotEntry` rows. After auto-cleanup runs, the main-window comparison path can fall back to current-only mode even though snapshot metadata still exists.

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

Cleanup and storage trimming look mostly correct in the tested paths, but the review still found real regressions in scan cancellation, scan accounting, live category inventory, and snapshot comparison after cleanup.
