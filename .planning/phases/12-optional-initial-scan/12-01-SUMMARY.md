---
phase: 12-optional-initial-scan
plan: 01
subsystem: ui
tags: [swiftui, fsevents, onboarding, delta-tracking, userdefaults]

# Dependency graph
requires:
  - phase: 11-live-tracking-engine
    provides: FSEvents watcher, incremental delta application, performSilentReconciliation
provides:
  - Deltas-only tracking mode (skip initial scan)
  - Start Tracking onboarding option
  - isDeltasOnlyMode computed property
  - Background auto-upgrade from deltas-only to full inventory
  - trackingStartedAt persistence
affects:
  - Any phase touching onboarding or CategoryGrowthListView

# Tech tracking
tech-stack:
  added: []
  patterns:
    - isDeltasOnlyMode computed from noBaseline + trackingStartedAt state
    - Background upgrade via Task with sleep(remaining) then silent scan
    - Category display mode switching via isDeltasOnly parameter on row component

key-files:
  created: []
  modified:
    - Prunr/ViewModels/SettingsStore.swift
    - Prunr/Services/MenuBarManager.swift
    - Prunr/Views/MenuBarView.swift
    - Prunr/Views/CategoryGrowthListView.swift

key-decisions:
  - "isDeltasOnlyMode is a computed property (noBaseline && trackingStartedAt != nil), not stored state"
  - "Background upgrade fires 10 minutes after trackingStartedAt; surviving app restarts by recalculating remaining time"
  - "noBaseline stays true during deltas-only mode so FSEvents incremental path is taken, but mainCategoryView is shown instead of onboarding"
  - "CategoryInventoryRow accepts isDeltasOnly: Bool to switch between +X / absolute display"

patterns-established:
  - "Deltas-only state: noBaseline=true + trackingStartedAt set — avoids a third state variable"
  - "Upgrade schedule resilient to restarts: max(0, delay - elapsed) calculation in scheduleDeltasOnlyUpgrade"

requirements-completed: []

# Metrics
duration: 7min
completed: 2026-03-14
---

# Phase 12 Plan 01: Deltas-Only Mode (Skip Initial Scan) Summary

**Onboarding skip-scan mode: FSEvents tracking starts immediately, categories show +X GB since tracking, background full scan fills absolute sizes after 10 minutes**

## Performance

- **Duration:** 7 min
- **Started:** 2026-03-14T07:02:34Z
- **Completed:** 2026-03-14T07:09:55Z
- **Tasks:** 5
- **Files modified:** 4

## Accomplishments
- Users can complete onboarding without any scan — "Start tracking" creates tracked paths + starts FSEvents instantly
- `isDeltasOnlyMode` computed property drives display mode across the UI
- Category rows show "+340 MB since tracking" instead of absolute sizes in deltas-only mode
- Empty state shows "Tracking changes — Categories will appear as files change" when no deltas detected yet
- Background reconciliation auto-schedules 10 minutes after tracking starts, survives app restarts, and seamlessly upgrades to full inventory

## Task Commits

Each task was committed atomically:

1. **Task 5: Persist tracking start timestamp** - `8085e5a` (feat)
2. **Task 2+4: isDeltasOnlyMode + background upgrade** - `f615f30` (feat)
3. **Task 1: Start Tracking onboarding option** - `ef3f604` (feat)
4. **Task 3: Adapt category display for deltas-only** - `3ce4b96` (feat)

## Files Created/Modified
- `Prunr/ViewModels/SettingsStore.swift` - Added `trackingStartedAt: Date?` with UserDefaults persistence, `beginDeltasOnlyMode()` and `endDeltasOnlyMode()` helpers
- `Prunr/Services/MenuBarManager.swift` - Added `isDeltasOnlyMode`, `startDeltasOnlyTracking()`, `scheduleDeltasOnlyUpgrade()`, `upgradeDeltasOnlyToFullInventory()`; `checkBaseline()` resumes FSEvents + schedule on restart; `loadInventory()` clears trackingStartedAt on completion
- `Prunr/Views/MenuBarView.swift` - Added "Start tracking (skip scan)" secondary button on scan page; `mainCategoryView` shown instead of `setupOnboardingView` when `isDeltasOnlyMode`; `startDeltasOnlyTracking()` private helper
- `Prunr/Views/CategoryGrowthListView.swift` - `CategoryInventoryRow` accepts `isDeltasOnly: Bool`; deltas-only rows show "+X GB / since tracking" or "watching..." placeholder; `emptyStateView` branches to `deltasOnlyWaitingView` when in deltas-only mode

## Decisions Made
- `isDeltasOnlyMode` is computed (not stored) from `noBaseline && trackingStartedAt != nil`. This avoids a third state variable and means the state self-corrects if either condition changes independently.
- `noBaseline` stays `true` during deltas-only mode so the existing FSEvents incremental code path is used for accumulating deltas. The main view condition was updated from `manager.noBaseline` to `manager.noBaseline && !manager.isDeltasOnlyMode` to show `mainCategoryView` instead of `setupOnboardingView`.
- The background upgrade uses `max(0, upgradeDelay - elapsed)` so after a restart where 10+ minutes have already passed, the upgrade fires immediately (within the next Task scheduling cycle) rather than waiting another 10 minutes.
- Tasks 2 and 4 were committed together since `upgradeDeltasOnlyToFullInventory` is directly called by `scheduleDeltasOnlyUpgrade`.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None - build passed clean on first attempt.

## Next Phase Readiness
- Deltas-only mode foundation is complete
- Background reconciliation integrates cleanly with existing `performSilentReconciliation` pattern
- UI adapts to mode changes reactively via `manager.isDeltasOnlyMode` observation

---
*Phase: 12-optional-initial-scan*
*Completed: 2026-03-14*

## Self-Check: PASSED

- SettingsStore.swift: FOUND
- MenuBarManager.swift: FOUND
- MenuBarView.swift: FOUND
- CategoryGrowthListView.swift: FOUND
- SUMMARY.md: FOUND
- Commit 8085e5a: FOUND
- Commit f615f30: FOUND
- Commit ef3f604: FOUND
- Commit 3ce4b96: FOUND
