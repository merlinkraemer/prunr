# Todo

## Drill-down navigation audit

- [x] Inspect menu bar drill-down state and async navigation flow
- [x] Remove view-side transient state reset that can bounce drill-down back to main
- [x] Verify with build/tests
- [x] Add review notes

## Review

- Root cause was two overlapping races in the drill-down flow.
- `MenuBarManager.reconcileDrillDownSelection()` treated an empty subcategory cache during reload as if the selected subcategory had disappeared, which could collapse file-level drill-down mid-refresh.
- The custom slide navigation in `CategoryGrowthListView` and the matching header transition in `MenuBarView` could accept a new transition while the previous one was still active, which let the visible stack skip or snap between inconsistent screens.
- Fix: preserve the current subcategory while its category is actively reloading, and stabilize any in-flight transition to its incoming screen before starting the next one.
- Verification covered `make build` and `make test`. The bug is intermittent, so manual drill-down exercise is still needed in the running app.

## UI audit

- [x] Inspect remaining custom UI transition/state code for similar race conditions
- [x] Record likely residual issues for follow-up
- [x] Fix onboarding transition/state inconsistencies

## UI audit review

- Onboarding now stabilizes any in-flight page transition before starting the next one, matching the hardened drill-down/header pattern.
- Onboarding now re-syncs its visible page state when the popover reopens or the onboarding view tears down, so stale slide state does not linger across closes.
- The step-3 onboarding screen now exposes the same back-navigation affordance as the tappable step bar when scanning is not active.

## Runtime audit fixes

- [ ] Checkpoint current local UI state before runtime fixes
- [ ] Fix incremental refresh escalation so `needsFullScan` actually triggers a refresh path
- [ ] Fix free-space accounting to sample the tracked path volume instead of always `/`
- [ ] Replace snapshot pagination hot paths that currently rely on `OFFSET`
- [ ] Re-run `make build` and `make test`

## Runtime audit notes

- Review findings targeted manager-level refresh fallback correctness, multi-volume accounting correctness, and large-snapshot performance hotspots.
- Existing tests pass, but they do not cover the manager fallback from incremental refresh escalation into an actual full refresh.
