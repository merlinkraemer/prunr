# Old issue triage (Q11), 2026-10-30

Read-only pass on main at `adeecc4`. Nothing was commented, labelled or closed on GitHub.

Context: the October rebuild replaced the change list and its drilldown with `PushPager` (`Prunr/Views/ListNavigation.swift`). The old slide machinery (`DrilldownTransitionCoordinator`, `CategoryGrowthListView`, header strip) survives only for the Categories overview, opened by clicking the drive bar (`MenuBarView.swift` `showsCategoryOverview`). Issues #23-#30 all target that surviving code. It is a secondary screen, so impact is lower than the April filing assumed.

| Issue | Verdict | Evidence | Size | User-visible? | Recommended action |
|---|---|---|---|---|---|
| #23 outgoing pane re-binds to live manager state | still real (narrower) | Outgoing pane still reads live state: `CategoryGrowthListView.swift:332` (`manager.subcategoryGroupsByCategory`), `:199-202` (`resolvedSubcategory` -> `manager.selectedSubcategory`, `drilldownFileGroup`); header same in `MenuBarView.swift:1450-1480`. The contributor `.task(id:)` part is gone (`contributorTaskID` removed with the 0f029e0 drilldown rewrite). | M | yes, subtle flicker mid-slide in Categories overview | Keep, retitle to the remaining live reads. Snapshot data into `DrilldownListPane`. Needs Merlin sign-off (UI). |
| #24 cleanup `Task.sleep` equals animation duration | still real | `DrilldownTransitionCoordinator.swift:76` sleeps 280 ms (= `slideMilliseconds`); onboarding `MenuBarView.swift:1085` hardcodes 280; `ListNavigation.swift:230` (new pager) uses the same pattern. Deployment target macOS 14 (`project.yml`), so `withAnimation(_:completionCriteria:_:completion:)` is available. | S | yes, possible end-of-slide snap | Keep. One fix across the three sites; extend the issue to cover the pager. |
| #25 onboarding duplicates the drilldown coordinator | still real, worse | Onboarding state machine intact at `MenuBarView.swift:1049-1120`. A third slide implementation now exists (`PushPager`, `ListNavigation.swift:130-250`). | M | no (refactor) | Keep, low priority. Better framing: collapse onto `PushPager` once the Categories overview moves to it; do not generalize the old coordinator. |
| #26 top-level Group re-mounts `CategoryGrowthListView` | unclear (mostly by design) | Branching is at `MenuBarView.swift:419-431` (`liveContent`) and `:327-339`. The manual-scan takeover is deliberate and commented there. `showsCategoryOverview` and `feedPage` live in `MenuBarView` `@State`, so navigation survives; only list-local slide state resets. Auto scans do not swap the branch. | S | barely | Close as obsolete unless Merlin has seen a real drop. If kept, reduce to: slide state lost when a manual scan starts mid-slide. |
| #27 drilldown entry-point guards inconsistent | still real | `navigateFromDriveBar` at `MenuBarView.swift:2070` checks only `isDrillDownTransitionAnimating`. List taps use `canNavigate` (`CategoryGrowthListView.swift:~405`, also checks `activeTransition`, `pendingTransition`, which are private `@State`). | S | yes (rare double slide on fast drive-bar click) | Keep. Cheapest: expose a single `canStartTransition` flag on the manager, set it from the list. |
| #28 panes lack stable `.id()` | still real | `screenPage` (`CategoryGrowthListView.swift:~205`) and `headerPage` (`MenuBarView.swift:~1503`) apply no `.id`. Only `.id` use in the file is `:1706` (footer ring). Subcategories A -> subcategories B share a branch, so reuse is possible. | S | yes, subtle | Keep. One-line change per site. Bundle with #23. |
| #29 contributor prefetch fires during slide | obsolete | `prefetchGrowthContributors`, `loadGrowthContributors`, `contributorTaskID` no longer exist anywhere in `Prunr/` (removed by 0f029e0 "exact drilldown index"). `drillIntoCategory` (`MenuBarManager.swift:1784`) loads before navigating, not during the slide. | - | - | Close as obsolete (code gone, 0f029e0). |
| #30 header and list sync via separate onChange | still real | Header sync on popover open: `MenuBarView.swift:375-379`; list sync: `CategoryGrowthListView.swift` `onChange(of: manager.isPopoverShown)` (~`:151`). Both still run; the list already drives the header via `onSyncHeaderToListPane`. | S | barely (one-frame glitch on reopen, only on Categories overview) | Keep as a small cleanup. Remove `synchronizeVisibleHeaderToCurrent()` from the popover-open handler. |
| #32 categories greyed after scan | obsolete | Fixed by cac7668 "keep panel categories interactive on open" (May 18). Rows are now hardcoded ready (`isNavigationReady: true, isPreparing: false`, `CategoryGrowthListView.swift:~226`); pending data shows inline status rows instead of greyed rows. The main screen is also the change list now. | - | - | Close as fixed (cac7668). |
| #34 signing failed on v0.1.5-alpha.5 | obsolete (root cause never recorded) | Releases now go through `release.yml`; `docs/appcast.xml` carries signed alpha.24 (build 25). `scripts/release.sh:345-348` verifies codesign, spctl, stapler. 19 signed alphas shipped since alpha.5. `docs/lessons.md:26` records the related CI-signing lesson. | - | - | Close with note: superseded by working pipeline. Unverified: what exactly broke on alpha.5. |
| #18 beta artifact metadata drift | obsolete | No `Prunr.app` is tracked (`git ls-files` finds none). `project.yml` uses `com.prunr.app`, version is bumped per release (`0.1.5-alpha.24`, build 25) and written to the appcast by the release workflow. | - | - | Close. Optional: a CI check that tag version equals `project.yml`, only if it has bitten before. |
| #11 beta release checklist | obsolete (stale umbrella) | Refers to 0.1.3 (2), 50 tests, and #18. Remaining items: manual smoke test (now alpha feedback funnel) and branch protection (`docs/alpha-feedback-funnel-2026-08-19.md:260`, `docs/alpha-feedback-funnel-brief.md:103`). | - | - | Close; track branch protection in `docs/STATE.md` if still wanted. |

## Counts

obsolete 5 (#29, #32, #34, #18, #11), still real 6 (#23, #24, #25, #27, #28, #30), unclear 1 (#26).

## Still-real, in fix order

All six touch the Categories overview or onboarding UI, so each is user-visible or a UI-adjacent refactor and waits for Merlin per `AGENTS.md` "must ask". Order is cheapest and most contained first.

1. #27 guard drive-bar entry (S). Smallest real race, one shared flag.
2. #28 add `.id(screen.id)` to list and header pages (S). One line each.
3. #30 drop header self-sync on popover open (S). One deletion, check reopen behavior.
4. #24 completion-callback cleanup (S). One mechanism for coordinator, onboarding, pager.
5. #23 snapshot panes instead of live manager reads (M). Highest impact on flicker; do after #28 so identity is stable first.
6. #25 unify slide machinery (M). Refactor, no user value alone; fold into moving the Categories overview onto `PushPager`, or drop.

Suggested bundle: #27 + #28 + #30 + #24 as one small branch, #23 separately. #26 closes unless seen in practice.
