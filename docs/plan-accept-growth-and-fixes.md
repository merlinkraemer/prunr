# Plan: Accept Growth Feature + Bug Fixes

## Overview

Three changes:
1. **Feature**: "Accept Growth" — dismiss growth indicators via DB-only baseline reset
2. **Bug fix**: Loading spinner stuck permanently on main view
3. **Bug fix**: Trash (and other) categories show stale growth after files are deleted

---

## 1. Accept Growth Feature

### 1a. DatabaseManager — new methods

**`createSnapshotFromWorkingSet(trackedPathId:freeBytes:)`**

Single atomic `dbPool.write` transaction:

```sql
-- Create new snapshot row
INSERT INTO snapshot (trackedPathId, createdAt, freeBytes) VALUES (?, ?, ?);
-- newSnapshotId = last_insert_rowid()

-- Copy working set → snapshot entries (pure in-DB copy, no filesystem I/O)
INSERT INTO snapshotEntry (snapshotId, pathId, sizeBytes)
SELECT ?, pathId, sizeBytes FROM workingSetEntry WHERE trackedPathId = ?;

-- Delete all older snapshots (FK CASCADE cleans snapshotEntry, categorySnapshot, subcategorySnapshot)
DELETE FROM snapshot WHERE trackedPathId = ? AND id != ?;
```

After transaction: call `DatabaseCleanupService.aggregateCategoryTotals(for: newSnapshotId)` to populate `categorySnapshot` + `subcategorySnapshot`.

**`deleteGrowthJournalBuckets(trackedPathId:)`**

```sql
DELETE FROM growthJournalBucket WHERE trackedPathId = ?;
```

### 1b. BaselineService — new method

**`acceptGrowth(for trackedPath:)`**

1. Get `freeBytes` from volume (same pattern as `ScanService`)
2. Call `db.createSnapshotFromWorkingSet(trackedPathId:freeBytes:)`
3. Call `DatabaseCleanupService.shared.aggregateCategoryTotals(for: newSnapshotId)`
4. Call `db.deleteGrowthJournalBuckets(trackedPathId:)` — clears growth stories

### 1c. MenuBarManager — new method

**`acceptGrowth()`**

```swift
func acceptGrowth() async {
    guard !isLoading, !isAutoScanning, !isCheckingGrowth else { return }
    isAcceptingGrowth = true
    defer { isAcceptingGrowth = false }

    let enabledPaths = effectiveTrackedPaths(from: SettingsStore.shared.enabledTrackedPaths)
    for trackedPath in enabledPaths {
        try? await baselineService.acceptGrowth(for: trackedPath)
    }

    // Full refresh — reloads inventory, resets all caches
    await loadInventoryFromLatestSnapshot(
        refreshedAt: Date(),
        invalidateSubcategoryCache: true,
        force: true
    )
}
```

Add `@Published var isAcceptingGrowth = false` property.

### 1d. UI — overviewHeader in MenuBarView.swift

Current (line 1237-1270):
```
          ↗ +500 MB              (orange, when growing)
          ✓ Stable               (green, when stable)
```

New — add dismiss `×` on hover next to the orange growth pill:
```
          ↗ +500 MB  ×           (× appears on hover, triggers acceptGrowth)
          ✓ Stable               (no change when stable)
```

Implementation in `overviewHeader`:

```swift
if overallGrowthBytes > 0 {
    HStack(spacing: 5) {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .semibold))
        Text("+\(formattedBytes(overallGrowthBytes))")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))

        // Dismiss button — visible on hover
        if acceptGrowthHover || isAcceptingGrowthHover {
            if manager.isAcceptingGrowth {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            } else {
                Button {
                    Task { await manager.acceptGrowth() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Accept growth — set current sizes as new baseline")
            }
        }
    }
    .foregroundStyle(.orange)
    .onHover { acceptGrowthHover = $0 }
}
```

Add `@State private var acceptGrowthHover = false`.

### 1e. Growth threshold (1 MB minimum)

In `applyIncrementalDeltas`, only set `recentGrowthStory` when cumulative growth
exceeds 1 MB. Filter in `accumulateGrowthStory`:

```swift
// In accumulateGrowthStory — skip if total delta < 1 MB
let totalDelta = (existing?.deltaBytes ?? 0) + delta
guard totalDelta >= 1_048_576 else { return existing }
```

Also filter in `getInventoryWithTrends` — only attach `recentGrowthStory` to
`CategoryInventoryItem` when `story.deltaBytes >= 1_048_576`.

---

## 2. Bug Fix: Stuck Loading Spinner

### Root cause

`isBootstrapping` in `MenuBarView.swift` (line 322) is set to `true` at the top
of a `.task` block and only set to `false` at the bottom (line 338). If SwiftUI
cancels the task (popover closes mid-load), `isBootstrapping` stays `true`
permanently. Same issue with `isAutoScanning` in `refreshVisibleInventory` (line 993).

### Fix

**MenuBarView.swift `.task` block** (line 321-339):

```swift
.task {
    isBootstrapping = true
    defer { isBootstrapping = false }
    await manager.checkBaseline()
    manager.updateFreeSpaceIfNeeded()
    await manager.updatePathSize()
    if !manager.noBaseline {
        await manager.loadInventoryFromLatestSnapshot()
        manager.reconcileIfStale()
    }
}
```

**MenuBarManager.refreshVisibleInventory** (line 986-997):

```swift
func refreshVisibleInventory() async {
    guard !isLoading, !isAutoScanning else { return }
    guard !isInventoryRefreshInProgress else { return }
    reconciliationTask?.cancel()
    reconciliationTask = nil
    isReconciling = false
    isAutoScanning = true
    defer { isAutoScanning = false }
    await loadInventory(isAutomatic: true)
    lastReconciliationAt = Date()
}
```

---

## 3. Bug Fix: Stale Growth After Deletion (Trash)

### Root cause

`applyIncrementalDeltas` (line 2374-2437) handles negative deltas for
`currentSizeBytes` (clamped to 0) but **never clears `recentGrowthStory`**.
A category that shrinks stays in `growingCategories` with its stale orange pill
until the next full inventory reload.

### Fix

In `applyIncrementalDeltas`, after applying a negative delta to a growing category,
check if the category should be demoted back to stable:

```swift
// After line 2387, add:
// Demote growing categories whose size hit zero or whose growth story
// is now fully offset by shrinkage
var demotedIndices = IndexSet()
for i in growingCategories.indices {
    if growingCategories[i].currentSizeBytes == 0 {
        growingCategories[i].recentGrowthStory = nil
        demotedIndices.insert(i)
    } else if let delta = categoryDeltas[growingCategories[i].category], delta < 0 {
        // Negative delta — recalculate if growth story is still valid
        if let story = growingCategories[i].recentGrowthStory {
            let newDelta = story.deltaBytes + delta
            if newDelta <= 0 {
                growingCategories[i].recentGrowthStory = nil
                demotedIndices.insert(i)
            } else {
                growingCategories[i].recentGrowthStory = RecentGrowthStory(
                    category: story.category, subcategory: story.subcategory,
                    deltaBytes: newDelta, startedAt: story.startedAt,
                    endedAt: now, duration: story.duration,
                    displayLabel: story.displayLabel
                )
            }
        }
    }
}
for i in demotedIndices.reversed() {
    stableCategories.append(growingCategories.remove(at: i))
}
```

---

## File Changes Summary

| File | Changes |
|---|---|
| `DatabaseManager.swift` | Add `createSnapshotFromWorkingSet`, `deleteGrowthJournalBuckets` |
| `BaselineService.swift` | Add `acceptGrowth(for:)` |
| `MenuBarManager.swift` | Add `isAcceptingGrowth`, `acceptGrowth()`, fix `refreshVisibleInventory` defer, fix `applyIncrementalDeltas` demotion, add 1MB threshold to `accumulateGrowthStory` |
| `MenuBarView.swift` | Add `defer { isBootstrapping = false }`, add `×` dismiss button on growth pill with hover state |

No new tables. No migrations. No filesystem I/O for accept.

---

## Execution Order

1. Bug fix: spinner `defer` guards (MenuBarView + MenuBarManager)
2. Bug fix: stale growth demotion in `applyIncrementalDeltas`
3. Feature: DB methods (`createSnapshotFromWorkingSet`, `deleteGrowthJournalBuckets`)
4. Feature: `BaselineService.acceptGrowth`
5. Feature: `MenuBarManager.acceptGrowth` + `isAcceptingGrowth`
6. Feature: UI — `×` dismiss on growth pill in `overviewHeader`
7. Feature: 1 MB growth threshold in `accumulateGrowthStory`
8. Build + test
