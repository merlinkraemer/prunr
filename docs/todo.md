# Todo

## Beta bugfix round

- [x] Reproduce and root-cause GitHub issues `#5`, `#6`, and `#7`
- [x] Normalize category presentation state so duplicate category rows cannot survive refresh/delta paths
- [x] Fix subcategory growth aggregation so parent drill-down stays consistent with file-level contributors
- [x] Queue page/header/onboarding transitions instead of collapsing in-flight pushes
- [x] Keep scheduled full rescans background-only and show only a subtle footer indicator
- [x] Re-run `make build` and `make test`

## Beta bugfix review

- Duplicate category rows were a state-invariant bug, not just rendering: category items could survive across `growingCategories` and `stableCategories` at the same time after incremental promotions/demotions. The manager now canonicalizes visible category state by category key before the UI sees it.
- Missing subcategory growth with visible file-level growth came from replacing baseline-derived subcategory totals with journal totals wholesale. Journal totals are now applied as an overlay, so subcategories that still only have baseline-backed growth do not disappear.
- Navigation flicker/overlap came from starting a new push while the previous custom transition was still running, then force-stabilizing mid-flight. The drill-down list, header, and onboarding flows now queue the next transition and start it only after the current push finishes.
- Scheduled stale reconciliations already ran in the background, but the footer gave no signal. The main page now keeps that work background-only and shows a subtle footer indicator in the timestamp slot while the quiet full refresh is running.
- Verification: `make build` passed, `make test` passed, and a new regression test covers the partial-journal subcategory case.

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

- [x] Checkpoint current local UI state before runtime fixes
- [x] Fix incremental refresh escalation so `needsFullScan` actually triggers a refresh path
- [x] Fix free-space accounting to sample the tracked path volume instead of always `/`
- [x] Replace snapshot pagination hot paths that currently rely on `OFFSET`
- [x] Re-run `make build` and `make test`

## Runtime audit notes

- Review findings targeted manager-level refresh fallback correctness, multi-volume accounting correctness, and large-snapshot performance hotspots.
- Existing tests pass, but they do not cover the manager fallback from incremental refresh escalation into an actual full refresh.

## Runtime audit review

- `needsFullScan` escalation from incremental refresh now routes into a real inventory scan path instead of being dropped on the floor.
- Snapshot free-space capture now samples the tracked path volume, so external-drive accounting is no longer pinned to `/`.
- Full-snapshot walkers used by drill-down fallback and maintenance now use cursor pagination by row id instead of repeated `OFFSET` scans.
- Drill-down "load more" now queries filtered rows directly from SQL for single-snapshot and working-set paths, and the aggregated multi-path variant only fetches the top requested window per path before merging.
- Verification: `make build` and `make test` both passed after the runtime fixes.

## Beta cleanup round

- [x] Audit stale branches of product logic and dead compatibility code
- [x] Remove unreachable deltas-only onboarding leftovers
- [x] Remove deprecated/unused manager compatibility entrypoints and state
- [x] Tighten stale docs to match current beta flow
- [x] Re-run `make build` and `make test`

## Beta cleanup notes

- Focus this round on code that is no longer part of the product or carries transition-era compatibility without current callers.
- Avoid behavior changes unless the existing branch is already unreachable or redundant.

## Beta cleanup review

- Removed the hidden deltas-only bootstrap mode and its UI/state branches. Onboarding now has a single supported path: pick a folder, then run the first full scan.
- Removed the dead category-growth compatibility layer (`CategoryGrowthItem` and the deprecated manager entrypoint) that was no longer used by the menu bar app.
- Added a small settings migration so legacy `trackingStartedAt` defaults are cleared on launch instead of keeping a dormant hidden mode alive.
- Project cleanup also included removing the deleted model from [project.pbxproj](/Users/merlinkraemer/dev/projects/prunr/Prunr.xcodeproj/project.pbxproj) and cleaning a few stale `MenuBarManager` warnings from unreachable `catch` blocks / unused locals.
- Repo audit note: stale feature branches were cleaned up separately after this pass so `main` remains the only active branch of record.
- Verification: `make build` and `make test` both passed after the cleanup pass.

## Legacy UI cleanup round

- [x] Identify dead legacy windowed UI files versus still-tested comparison code
- [x] Move shared scroll-indicator helper out of legacy `ContentView`
- [x] Remove dead legacy windowed views and action singleton from the project
- [x] Re-run `make build` and `make test`

## Legacy UI cleanup notes

- Keep `MainViewModel`, `Delta`, and related comparison services while tests still exercise them.
- Remove only the unused windowed shell and view tree that is no longer reachable from the app entrypoint.

## Legacy UI cleanup review

- Extracted the shared hidden-scroll-indicator helper into [HiddenScrollIndicators.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Helpers/HiddenScrollIndicators.swift) so the active menu bar UI could keep using it after removing the legacy shell.
- Removed the dead windowed app shell, comparison picker/views, and the old action singleton from the project because they are no longer reachable from the menu bar app entrypoint.
- Kept `MainViewModel`, `Delta`, and `DeltaService` because the comparison model/service layer is still exercised by tests and is separate from the deleted windowed UI shell.
- Removed one dead category-trend snapshot path from `BaselineService` and `DatabaseManager` that was no longer called by the live inventory flow.
- Verification: `make build` and `make test` both passed after the legacy UI cleanup.

## Permission gating fix

- [x] Audit how onboarding decides Full Disk Access is granted
- [x] Replace the weak TCC-only probe with scan-relevant protected-path probes
- [x] Update onboarding/settings copy to stop claiming success when key protected locations are still blocked
- [x] Defer file watcher startup until a real baseline exists
- [x] Re-run `make build` and `make test`

## Permission gating review

- The remaining launch-time prompts were caused by the eager FSEvents watcher, not the explicit permission probe alone.
- On first launch, the app was still arming a watcher against the default tracked home path before onboarding completed, which was enough for macOS to request Desktop/Documents/iCloud-class access immediately.
- Fix: do not start the watcher in `MenuBarManager.init()`, stop any existing watcher while `noBaseline` is true, and only configure watching after baseline state is confirmed or a successful scan creates one.
- Verification: `make build` passed. `make test` is not a strong signal for this bug because the real behavior must be confirmed by relaunching the installed app with a clean TCC state.

## Control affordances round

- [x] Keep the footer refresh action shallow-only
- [x] Make drive bar category segments clickable
- [x] Re-run `make build` and `make test`

## Control affordances review

- The footer refresh button used to seed tracked roots when there were no pending file-watcher events, which could escalate into a full refresh path. It now only flushes pending watcher state and re-arms the watcher if needed, so it remains a user-controlled shallow refresh.
- Drive bar category segments now support direct click-through to the matching category drill-down while preserving the existing hover-linked highlighting. Filler segments such as outside-scan-scope and uncategorized remainder stay non-navigable.
- Verification: `make build` passed. An initial parallel `make test` hit Xcode's shared `build.db` lock; the serial rerun passed cleanly.

## Control affordances follow-up

- [x] Re-check the actual footer refresh runtime path after user reported it still triggered a full rescan
- [x] Rework drive bar taps as real button interactions instead of relying on shape gestures
- [x] Re-run `make build` and `make test`

## Control affordances follow-up review

- The first footer fix only removed the manual root seeding, but the shared recent-change pipeline could still escalate pending watcher events into `loadInventory()`. Manual footer refresh now explicitly runs the recent-change path with full-refresh escalation disabled.
- The first drive-bar tap wiring used a gesture on the rendered rectangle segments. The interaction is now attached to real plain buttons per segment so category clicks are routed reliably while filler segments remain inert.
- Verification: `make build` passed and `make test` passed after the follow-up fix.
