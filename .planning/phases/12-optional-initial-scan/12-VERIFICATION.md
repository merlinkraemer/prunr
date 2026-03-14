---
phase: 12-optional-initial-scan
verified: 2026-03-14T08:10:00Z
status: passed
score: 7/7 must-haves verified
re_verification:
  previous_status: gaps_found
  previous_score: 6/7
  gaps_closed:
    - "Subcategory drill-down shows empty screen in deltas-only mode"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Background upgrade timing after app restart"
    expected: "scheduleDeltasOnlyUpgrade() computes max(0, 600 - elapsed) using persisted trackingStartedAt. If 360 seconds already passed before a restart, upgrade fires ~240 seconds after relaunch, not 600."
    why_human: "Timing behaviour requires live testing; cannot be verified statically."
---

# Phase 12: Optional Initial Scan — Verification Report

**Phase Goal:** Allow users to skip the initial full scan entirely. The app starts tracking changes immediately via FSEvents. Categories appear as changes are detected. A background reconciliation scan fills in total sizes later.
**Verified:** 2026-03-14T08:10:00Z
**Status:** passed
**Re-verification:** Yes — after gap closure plan 12-02

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can complete onboarding without any scan (instant) | VERIFIED | `MenuBarView.swift:786` "Start tracking (skip scan)" button calls `startDeltasOnlyTracking()`, which does NOT call `loadInventory()` |
| 2 | FSEvents starts immediately after "Start tracking" | VERIFIED | `MenuBarManager.startDeltasOnlyTracking()` (line 985-996) calls `configureFileWatcherIfNeeded()` before returning |
| 3 | Categories appear as changes are detected | VERIFIED | `noBaseline=true` is preserved so the existing FSEvents incremental delta path is taken; categories accumulate into `growingCategories`/`stableCategories` |
| 4 | Growth indicators show "+X MB since tracking" | VERIFIED | `CategoryInventoryRow` (lines 1001-1015): when `isDeltasOnly && item.currentSizeBytes > 0` renders `"+\(formattedBytes)" / "since tracking"` |
| 5 | Background reconciliation fills in total sizes automatically | VERIFIED | `scheduleDeltasOnlyUpgrade()` fires after `max(0, 600s - elapsed)` via async `Task.sleep`; `upgradeDeltasOnlyToFullInventory()` calls `createBaselines` then `loadInventoryFromLatestSnapshot` |
| 6 | After reconciliation, display switches to normal mode seamlessly | VERIFIED | `endDeltasOnlyMode()` clears `trackingStartedAt` → `isDeltasOnlyMode` becomes false → `CategoryInventoryRow` renders absolute sizes without a restart |
| 7 | Subcategory drill-down is disabled (non-interactive) in deltas-only mode | VERIFIED | Both `CategoryInventoryRow` instantiations now pass `isNavigationReady: !manager.isDeltasOnlyMode && (manager.hasCompletedInitialSubcategoryWarmup \|\| isReady)`. The existing `disabled(!isNavigationReady)` + `opacity(0.78)` modifiers apply automatically. Commit `b22d946`. |

**Score:** 7/7 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Prunr/ViewModels/SettingsStore.swift` | `trackingStartedAt: Date?` persistence, `beginDeltasOnlyMode()`, `endDeltasOnlyMode()` | VERIFIED | All three present. `trackingStartedAt` persisted to UserDefaults (lines 103-111, 315-322). Loaded in `init` (line 223). |
| `Prunr/Services/MenuBarManager.swift` | `isDeltasOnlyMode`, `startDeltasOnlyTracking()`, `scheduleDeltasOnlyUpgrade()`, `upgradeDeltasOnlyToFullInventory()`, `checkBaseline()` restart resume | VERIFIED | All functions present and substantive. `isDeltasOnlyMode` computed at lines 334-338. `checkBaseline()` resumes FSEvents + upgrade schedule at lines 1473-1476. |
| `Prunr/Views/MenuBarView.swift` | "Start tracking" button on scan page, `mainCategoryView` shown when `isDeltasOnlyMode` | VERIFIED | Button at line 786. Guard at line 295: `manager.noBaseline && !manager.isDeltasOnlyMode` correctly routes to `mainCategoryView` in deltas-only mode. |
| `Prunr/Views/CategoryGrowthListView.swift` | `CategoryInventoryRow` accepts `isDeltasOnly: Bool`, deltas-only display, `deltasOnlyWaitingView` empty state, navigation gated by `isDeltasOnlyMode` | VERIFIED | `isDeltasOnly` parameter at line 962. Display branches at lines 1001-1015. `deltasOnlyWaitingView` at lines 915-940. Both ForEach loops pass `isNavigationReady: !manager.isDeltasOnlyMode && (...)` at lines 388 and 404. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| MenuBarView "Start tracking" button | `MenuBarManager.startDeltasOnlyTracking()` | Private helper | WIRED | Line 787 calls `startDeltasOnlyTracking()`; line 1526 calls `manager.startDeltasOnlyTracking()` |
| `startDeltasOnlyTracking()` | `SettingsStore.beginDeltasOnlyMode()` | Direct call | WIRED | Line 987 |
| `startDeltasOnlyTracking()` | FSEvents watcher | `configureFileWatcherIfNeeded()` | WIRED | Line 993 |
| `startDeltasOnlyTracking()` | Background upgrade | `scheduleDeltasOnlyUpgrade()` | WIRED | Line 996 |
| `scheduleDeltasOnlyUpgrade()` | `upgradeDeltasOnlyToFullInventory()` | async Task | WIRED | Lines 1008-1019; fires after computed remaining delay |
| `upgradeDeltasOnlyToFullInventory()` | `SettingsStore.endDeltasOnlyMode()` | Direct call | WIRED | Line 1055 |
| `upgradeDeltasOnlyToFullInventory()` | Inventory reload | `loadInventoryFromLatestSnapshot()` | WIRED | Line 1059 |
| `loadInventory()` (full scan path) | `endDeltasOnlyMode()` | Guard on `trackingStartedAt` | WIRED | Lines 819-821 — clears tracking marker when full scan completes |
| `checkBaseline()` restart | Resume FSEvents + upgrade schedule | `configureFileWatcherIfNeeded()` + `scheduleDeltasOnlyUpgrade()` | WIRED | Lines 1473-1476 |
| `manager.isDeltasOnlyMode` | `CategoryInventoryRow.isNavigationReady` | AND-guard in both ForEach loops | WIRED | Lines 388 and 404: `!manager.isDeltasOnlyMode && (...)` |
| `manager.isDeltasOnlyMode` | `CategoryInventoryRow.isDeltasOnly` | Direct pass-through | WIRED | Lines 391 and 407 |
| `manager.isDeltasOnlyMode` | `deltasOnlyWaitingView` empty state | Conditional branch | WIRED | Line 881 |
| `manager.noBaseline && !manager.isDeltasOnlyMode` | Onboarding vs main view routing | MenuBarView body | WIRED | Line 295 |

### Requirements Coverage

No requirement IDs were mapped to phase 12.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Prunr/Services/MenuBarManager.swift` | 800 | `// TODO: Remove once drill-down is migrated to inventory-based` | Info | Pre-existing technical debt unrelated to phase 12. No new anti-patterns introduced by plan 12-02. |

No TODO/FIXME/placeholder patterns found in `CategoryGrowthListView.swift`.

### Human Verification Required

#### 1. Background upgrade timing after app restart

**Test:** Start deltas-only tracking, force-quit the app after 6 minutes, relaunch. Observe when the background upgrade fires.
**Expected:** `scheduleDeltasOnlyUpgrade()` computes `max(0, 600 - elapsed)` using the persisted `trackingStartedAt`. If 360 seconds elapsed before the quit, the upgrade should fire approximately 240 seconds after relaunch — not 600 seconds from relaunch.
**Why human:** Timing behaviour requires live testing with real clock values; cannot be verified statically.

### Re-Verification Summary

**Gap closed:** The single gap from initial verification — "Subcategory drill-down shows empty screen in deltas-only mode" — is fully resolved by plan 12-02.

**Fix applied (commit `b22d946`):** Both `CategoryInventoryRow` instantiations in `CategoryGrowthListView.swift` (growing categories ForEach at line 388, stable categories ForEach at line 404) now compute `isNavigationReady` as:

```swift
isNavigationReady: !manager.isDeltasOnlyMode && (manager.hasCompletedInitialSubcategoryWarmup || isReady)
```

This means `isNavigationReady` is `false` whenever the app is in deltas-only mode, which causes the existing `disabled(!isNavigationReady)` modifier to block taps and the `opacity(isNavigationReady ? 1 : 0.78)` modifier to dim the row. Users cannot navigate to the empty drill-down screen. When `isDeltasOnlyMode` becomes `false` after the background upgrade completes, SwiftUI re-evaluates the expression and rows become interactive automatically — no additional observer or state required.

**No regressions:** All six truths that passed in the initial verification remain verified. The `isDeltasOnly` display parameter (lines 391, 407), `deltasOnlyWaitingView` (line 881), `startDeltasOnlyTracking()`, `scheduleDeltasOnlyUpgrade()`, `upgradeDeltasOnlyToFullInventory()`, `SettingsStore` persistence, and `MenuBarView` routing are all intact and unchanged.

The phase goal — instant onboarding, FSEvents-based delta tracking, "+X MB since tracking" display, non-interactive rows in deltas-only mode, automatic background upgrade, and seamless mode transition — is fully implemented.

---

_Verified: 2026-03-14T08:10:00Z_
_Verifier: Claude (gsd-verifier)_
