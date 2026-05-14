# Todo

## Panel-open category reload fix (2026-05-14)

- [x] Reproduce/root-cause the visible category refresh on panel open
- [x] Preserve enriched category rows when quick working-set totals have not changed
- [x] Add a regression test for no-op quick inventory preserving growth state
- [x] Run focused tests and full app verification
- [ ] Reset the installed app and start a fresh long-running monitor

### Review

- Root cause: every freshly-created panel hosting view ran `loadQuickInventory()`, which replaced enriched rows with quick stable-only rows even when the working-set totals were identical.
- Quick inventory now leaves `allCategories` untouched when category totals match the already-visible rows. If totals changed, it updates the sizes/adds/removes categories while preserving existing growth stories for matching categories.
- Regression: `testPanelOpenQuickInventoryPreservesLoadedGrowthRowsWhenTotalsMatch` covers the panel-open no-op path.
- Verification: focused `xcodebuild test` passed for the two panel-open inventory tests. `make test` passed with 63 tests.

## 24h monitor follow-up fixes (2026-05-14)

- [x] Capture soak monitor, live process, DB, and unified log evidence
- [x] Fix debounced recent-change refresh cancellation so active incremental work can drain
- [x] Fix quick-inventory enrichment so growth stories load after panel open
- [x] Keep background scan partial totals from replacing visible category inventory
- [x] Gate dirty/full-rescan escalation by the configured full-scan interval
- [x] Add focused regressions for the changed invariants
- [x] Run build/tests and live monitor verification

### Current Findings

- The 24h monitor shows repeated unexpected full-scan snapshots before the configured 48h interval, plus current PID `25933` pinned near 100% CPU.
- Unified logs show many `RecentChanges` `Swift.CancellationError` failures. New watcher events cancel `recentChangeTask` even when it is already executing the refresh, so pending changes can churn instead of draining.
- Panel open runs `loadQuickInventory()` first, then `loadInventoryFromLatestSnapshotIfStale()` returns early because visible categories already exist. That blocks enrichment and leaves categories looking stable.
- Background scans apply partial category totals into `allCategories`, so visible categories can temporarily disappear and the drive bar reports the missing bytes as outside scan scope.
- Dirty FSEvents fallback still allows a full home-directory scan after the short cooldown instead of respecting the configured full-scan interval.
- The live freshness probe initially failed even while totals advanced because it compared logical file bytes against allocated-byte accounting.
- The remaining CPU spike after probe cleanup came from removal/directory refresh falling back to `replaceWorkingSetSubtree`, whose old `LIKE` query scanned the full working set.

### Review

- Recent-change debounce now clears the scheduled task before executing the refresh and uses a generation token for stale sleeps. New watcher events no longer cancel an active incremental refresh task.
- Panel-open inventory enrichment now only short-circuits after a real snapshot inventory load has populated snapshot IDs. Fast quick inventory can still appear immediately, then the richer growth stories load from DB.
- Background automatic scans no longer publish partial category totals over the existing complete inventory; foreground scans and first empty-state scans still get live category fill-in.
- Dirty/full-rescan escalation now uses the larger of the short dirty cooldown and the configured automatic full-scan interval. Dropped dirty batches no longer leave `pendingDirtyReason` set, so the footer cannot stick on changes pending.
- The watcher now arms after a valid baseline even when protected-location probes are blocked; full traversals remain gated separately.
- File-level updates use exact working-set row replacement, and missing/removal/subtree paths use indexed path-range queries before touching working-set rows. This removes the multi-million-row prefix scan from ordinary file edits and probe cleanup.
- The monitor freshness probe now writes non-compressible data and compares against the probe file's allocated bytes, matching app accounting.
- Verification: focused `xcodebuild test` passed for dirty cooldown, panel enrichment, watcher arming, recent-change inventory, and removal range cases. `make test` passed with 62 tests. Live `npm run monitor -- --freshness-probe --freshness-timeout 90` passed in 4s, and the installed app was idle at 0.0% CPU / ~71 MB RSS after probe cleanup. Final `npm run monitor -- --samples 1 --interval 1` reported `status OK`, zero category/working-set drift, and app CPU 0.6% during sample / 0.0% in `ps`.

## Alpha freshness fixes implementation (2026-05-13)

- [x] Create checkpoint commit for the alpha freshness PRD (`fa1e786`)
- [x] s1: Enforce dirty-root backoff for all full-refresh retry paths
- [x] s2: Hard-exclude Prunr internal paths from FSEvents classification and file accounting
- [x] s3: Move stale reconciliation off menu-open view appearance
- [x] s4: Keep panel-open inventory reads fast and surface pending dirty state
- [x] s5: Keep Accept Growth as pure DB-local promotion
- [x] s6: Strengthen freshness monitor probe for configured tracked root and category totals
- [x] Run build, tests, and monitor-script verification
- [x] Commit implemented fixes in checkpoints

### Review

- Dirty-root full-refresh work now uses one backoff scheduler, including busy retries, explicit refresh deferrals, and events flushed after scans.
- FSEvents classification filters Prunr-internal paths before dropped/large/directory-heavy promotion; `FileScanner` also skips internal files reached at the tracked-root file level.
- Menu opening no longer calls stale reconciliation; `MenuBarManager` owns a background reconciliation backstop scheduled on launch and after completed scans.
- Panel open trusts displayable inventory instead of expiring after five seconds, and the footer shows a pending-changes state while dirty work waits.
- Accept Growth snapshots the current working set with `freeBytes = nil`, preserving the DB-local promotion invariant.
- The monitor freshness probe now derives the active configured root where possible and requires both working-set and category-total byte deltas for the same tracked path.
- Verification: `make build` passed, `make test` passed with 55 tests, `npm run monitor -- --help` passed, `npm run monitor -- --samples 1 --interval 1` ran successfully but reported that Prunr was not running. The live `--freshness-probe` gate still needs the current app build running.

## File watcher birdseye review (2026-05-11)

- [x] Review current `FSEventsWatcher`, noise filter, `MenuBarManager` intake, `RecentChangeService`, DB writes, cleanup, startup lifecycle, and docs.
- [x] Compare current architecture against prior FSEvents storm findings.
- [x] Identify why simply re-enabling the watcher is still risky.
- [ ] Design a replacement freshness architecture before flipping `enableAutomaticFileWatcher`.

### Findings

- P0: Freshness is disabled by construction. `MenuBarManager.enableAutomaticFileWatcher` is `false`, while the UI footer refresh only processes pending watcher paths; with no watcher, new files have no event source.
- P0: The current DB-dir exclusion helper cannot exclude `~/Library/Application Support/Prunr` when the watched root is `~`. The broad home watch still includes Prunr's SQLite DB, WAL, and SHM writes; filtering happens after callback delivery, so the self-feedback storm class remains if the watcher is simply turned back on.
- P1: File watcher ownership is too shallow and leaky. `FSEventsWatcher` emits raw batches, but `MenuBarManager` owns permission gating, root selection, filtering, debounce, cooldown, escalation, DB refresh scheduling, UI state, and cleanup scheduling. This makes the correctness invariant difficult to test as one unit.
- P1: The FSEvents callback still allocates and normalizes every delivered path into a `Set<URL>` on the main queue before any cap is applied. Large event bursts can stall the UI even though downstream pending paths and refresh targets are capped.
- P1: Lifecycle handling is incomplete for a watcher-enabled build. There are no sleep/wake or mount/unmount observers, so wake floods, moved roots, or ejected volumes would flow through the same fragile recent-change path.
- P2: Current docs overstate the implemented state. `docs/OVERVIEW.md` and `docs/STATE.md` describe FSEvents-triggered automatic scans as implemented, while production code has the watcher disabled.

## Monitor analysis and freshness bug (2026-05-11)

- [x] Stop the active monitor soak in `prunr:2`
- [x] Summarize focused + soak monitor data
- [x] Confirm post-init working-set/category timestamps stayed pinned after the initial scan
- [x] Identify why newly added files do not appear after init scan
- [x] Identify why categories reload on each menubar open
- [ ] Fix post-init freshness without reintroducing the FSEvents scan storm
- [ ] Fix panel-open category reload latency
- [ ] Verify with a create-file smoke test and repeated panel open/close timing

### Findings

- Monitor coverage: focused phase ran from `2026-05-11T09:03:21Z` to `09:19:43Z`; soak phase ran from `09:19:45Z` to `12:58:43Z`.
- Initial scan completed once at `2026-05-11T09:04:14.952Z` with `2,402,408` working-set rows and `1,392,361,320,880` bytes.
- During the soak, `workingSetEntry`, `workingSetCategoryTotal`, and latest snapshot timestamps stayed fixed at `2026-05-11T09:04:14.952Z`; row and byte deltas remained `0`.
- CPU/RSS were stable after scan: soak average CPU was ~`0.27%`, max `24.3%`; RSS ranged ~`15 MB` to `130 MB`, ending ~`73 MB`.
- The current app still has `MenuBarManager.enableAutomaticFileWatcher = false`, and the footer refresh button only flushes pending watcher paths. With the watcher disabled, newly added files have no event source and `checkGrowth()` is effectively a no-op.
- Every panel open installs a new `NSHostingView(rootView: MenuBarView(manager: self))`; `MenuBarView.task` then reruns `loadQuickInventory()`, `checkBaseline()`, `updatePathSize()`, and `loadInventoryFromLatestSnapshot()`. Closing the panel can cancel that DB load; unified logs showed `Swift.CancellationError` from category inventory during this path.

## Storm fix Phase 1 (2026-05-09)

- [x] Create checkpoint commit before implementation (`27e656b`)
- [x] Demote `requiresFullRescan` intake with 30-minute cooldown and bounded fallback path queuing
- [x] Apply shared noise/auto-scan filtering at all recent-change intake points
- [x] Cap `pendingRecentChangePaths` accumulation at `50_000` with one-time escalation path
- [x] Remove per-scan synchronous auto-cleanup; defer DB cleanup to delayed background execution
- [x] Build and run focused tests for recent-change and watcher paths

## Storm fix Phase 1 review (2026-05-09)

- `make build` passed.
- Focused tests passed:
- `PrunrSmokeTests/testMenuBarManagerRetainsPendingRefreshWhenWatcherRequiresFullRescan`
- `PrunrSmokeTests/testRecentChangeRefreshPromotesTrackedRootDirectoryEventToFullScan`
- `PrunrSmokeTests/testFSEventsNoiseFilterIgnoresSQLiteSidecars`

## Beta audit triage (2026-04-17)

- Plan moved to [docs/beta-audit-plan.md](/Users/merlinkraemer/dev/projects/prunr/docs/beta-audit-plan.md).

## Beta audit Phase 1 execution

- [x] Create pre-implementation checkpoint commit (`65a3b0e`, `chore: checkpoint before beta audit phase 1`)
- [x] Exclude app-private watcher roots before stream creation and keep SQLite sidecar filtering as backup
- [x] Remove scan-complete FSEvents flush and redundant main-run-loop re-dispatch
- [x] Replace `workingSetCategoryTotal` read-modify-write loops with SQL delta updates
- [x] Run `make build`
- [x] Run focused smoke tests for watcher and recent-change behavior

## Beta audit Phase 1 review

- `make build` passed on the final Phase 1 tree.
- Focused smoke tests passed via `xcodebuild test` for:
- `PrunrTests/PrunrSmokeTests/testFSEventsWatcherReportsRealFilesystemChanges`
- `PrunrTests/PrunrSmokeTests/testFSEventsNoiseFilterIgnoresSQLiteSidecars`
- `PrunrTests/PrunrSmokeTests/testRecentChangeRefreshUpdatesVisibleInventoryFromWorkingSet`
- `PrunrTests/PrunrSmokeTests/testRecentChangeRefreshPromotesTrackedRootDirectoryEventToFullScan`
- `PrunrTests/PrunrSmokeTests/testMenuBarManagerRetainsPendingRefreshWhenWatcherRequiresFullRescan`
- `PrunrTests/PrunrSmokeTests/testWorkingSetCategoryDeltasDeleteZeroTotalsWithoutReadback`
- Manual validation failed: app crashed on the first scan during live testing on 2026-04-17 18:51 +07 before the rescan-loop check could complete.
- Phase 1 is parked pending crash triage and a fresh handoff note in [docs/handoff-beta-audit-phase1-crash-2026-04-17.md](/Users/merlinkraemer/dev/projects/prunr/docs/handoff-beta-audit-phase1-crash-2026-04-17.md).
- Remaining manual gate after crash triage: live app validation that finishing a scan no longer triggers an immediate follow-up scan, plus the monitor pass from `docs/beta-audit-plan.md`.
- Test logs still show pre-existing SQLite misuse / `GrowthJournalService` warnings during `testRecentChangeRefreshPromotesTrackedRootDirectoryEventToFullScan`; that test still passed and this phase did not address that separate issue.

## Beta readiness (current)

Status at 2026-04-25: build green, 50 tests pass, CI configured. Idle CPU fixed (~0.01%), RSS stable (~50 MB).

### ✅ Done

- [x] Architecture fixes Phase 6-7 (single allCategories source of truth, FSEvents NoDefer + post-scan flush)
- [x] Drill-down navigation hardening (queued transitions, preserved subcategory state during reloads)
- [x] Permission gating fix (deferred FSEvents watcher startup until after onboarding/baseline)
- [x] Control affordances (clickable drive-bar segments, shallow-only footer refresh)
- [x] Scan indicator fix (narrowed footer to scheduled background reconciliations only, with subtle pulse)
- [x] Test suite expansion (split into focused regression files, fixed 3 red baseline tests, 50 tests green)
- [x] CI setup (GitHub Actions: repo checks, SwiftLint, build+test)
- [x] Live scan monitor (`npm run monitor`)
- [x] Legacy UI cleanup (removed dead windowed shell and unreachable code)
- [x] Beta cleanup (removed deltas-only onboarding, dead category-growth layer, legacy settings migration)
- [x] Runtime audit (incremental refresh escalation, free-space multi-volume, cursor pagination)
- [x] #15 Full scan freezes mid-run on large home directories
- [x] #16 Cancelled or failed full scan leaves partial working-set data
- [x] #17 Silent reconciliation can hang without visible cancel path
- [x] #12 Crash on first scan during beta audit Phase 1 validation
- [x] #22 Improve cancellation responsiveness during large scan DB writes
- [x] #21 Use `pathClassification` SQL for snapshot subcategory breakdown
- [x] #19 Add app privacy manifest before beta distribution
- [x] #20 Replace production `print()` diagnostics with `Logger`
- [x] #13 Drill-down file view: cap grown items list at 10 with expand action
- [x] #14 Drill-down file view: growth contributor list stalls after initial files are visible
- [x] #9 Investigate CPU 150% when app runs for extended periods
  - Root cause: FSEvents watcher loop → DB → full working-set replacement
  - Fix: disabled automatic file watcher, lazy NSHostingView teardown
  - Validated: CPU ~0.01%, RSS ~50 MB at idle

### 🟡 Remaining before broad beta

- [ ] #18 Release artifact metadata — source aligned, artifact still needs rebuild/sign/notarize
- [ ] Manual smoke test: clean install → onboarding → first scan → Stop during scan → drill-down → settings
- [ ] Manual smoke test: leave app running overnight, check CPU/RSS next day
- [ ] Enable GitHub branch protection on `main` (requires GitHub Pro or public repo)

### Post-beta backlog

- Investigate CacheDelete/GetAPFSVolumeRole log noise (likely benign, 30 occurrences in monitor)
- Category-vs-working-set drift monitoring (-5.79 MB observed)
- Update tech-stack.md to reflect actual AppKit shell (not SwiftUI MenuBarExtra)
- Re-enable file watcher post-beta with coalescing/debouncing to prevent idle CPU loops
- Address drilldown polish issues #23–#30 (p3-medium, not beta blockers)

---

## Completed work (archive)

### Apple platform pattern audit

- [x] Review product docs and implementation to extract the dominant Apple-platform patterns
- [x] Validate each dominant pattern against current Apple documentation
- [x] Record findings, mismatches, and follow-up recommendations

## Apple platform pattern audit review

- Dominant shipped patterns are: SwiftUI `App` scenes with a menu bar shell, AppKit-backed menu bar presentation (`NSStatusItem` + `NSPopover`/`NSPanel`), `@MainActor` + `@Observable` state containers, Swift concurrency with actors / `TaskGroup` / `AsyncStream`, CoreServices `FSEventStream` bridging, `UserDefaults` + `SMAppService` settings persistence, and Foundation volume-capacity queries.
- Strong alignment: the scan pipeline now uses structured concurrency more defensibly than older review docs suggest. [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L451) routes scan progress through `AsyncStream`, [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L800) uses `withThrowingTaskGroup`, and [ScanService.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/ScanService.swift#L168) uses `withTaskCancellationHandler`.
- Strong alignment: filesystem monitoring follows Apple's FSEvents lifecycle and safety flags. [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L95) creates the stream, [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L150) schedules it, [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L157) starts it, [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L181) stops / invalidates / releases it, and [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L196) exposes `FSEventStreamFlushSync`.
- Medium mismatch: project docs still claim the app uses SwiftUI `MenuBarExtra`, but runtime code is an AppKit shell built around [NSStatusBar.system.statusItem](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L541), [NSPopover](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L552), and a custom [NSPanel](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L8); see [tech-stack.md](/Users/merlinkraemer/dev/projects/prunr/documentation/tech-stack.md#L7).
- Medium mismatch: product docs also list `UserNotifications` and `SwiftUI Charts`, but the shipped app code does not currently use those frameworks. [tech-stack.md](/Users/merlinkraemer/dev/projects/prunr/documentation/tech-stack.md#L7)
- Medium mismatch: settings persistence is correct but not especially idiomatic SwiftUI. [SettingsStore.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/ViewModels/SettingsStore.swift#L53) and nearby properties hand-roll `UserDefaults` read/write instead of using `@AppStorage` where scene-level or view-level preferences would be sufficient.
- Follow-up status: the watcher bridge is now explicit and main-actor-bound in the current worktree. [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L10) declares the watcher `@MainActor`, [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L124) delivers the C callback via `MainActor.assumeIsolated`, and [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L2411) records batches on the same actor boundary.
- GitHub issue alignment: `#5` and `#6` are stale relative to `main` because the current code already uses `allCategories` as the source of truth and re-hydrates subcategory drill-down state on refresh; `#7` is partially stale because the code queues transitions and guards against mid-slide collapse, but it still wants a manual UI repro before we treat it as fully closed.

## Apple platform audit follow-up

- [x] Replace the FSEvents callback `Task` hop with a tighter callback-to-actor handoff
- [x] Re-run focused verification for the watcher change
- [x] Reassess issue `#7` against current code and record whether this pass closes it or leaves a manual repro gap
- [x] Add follow-up review notes with what was proven and what remains manual

## Apple platform audit follow-up review

- `FSEventsWatcher` now matches the stream's actual execution model instead of pretending the callback arrives on an arbitrary executor. The watcher is `@MainActor`, the stream is scheduled onto `DispatchQueue.main`, and the callback delivers batches through `MainActor.assumeIsolated` rather than an unstructured hop. [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L10)
- `MenuBarManager` was aligned to the same boundary by removing the extra watcher `await`s and recording change batches directly on the main actor. [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L2396)
- Verification: `xcodebuild -project Prunr.xcodeproj -scheme Prunr -destination 'platform=macOS' build` passed.
- Verification: focused smoke tests were run directly against the watcher and recent-change paths:
- `PrunrSmokeTests/testFSEventsWatcherReportsRealFilesystemChanges`
- `PrunrSmokeTests/testMenuBarManagerRetainsPendingRefreshWhenWatcherRequiresFullRescan`
- `PrunrSmokeTests/testMenuBarManagerRecentChangeRefreshUsesLiveSubcategoryStructureForAffectedCategory`
- Result: the first two focused tests passed, and `testMenuBarManagerRecentChangeRefreshUsesLiveSubcategoryStructureForAffectedCategory` still fails in the current worktree with `XCTUnwrap` on a missing `SubcategoryGroup`. That leaves the repo not fully green for this verification pass.
- Issue `#7` remains a manual verification item. The current code still matches the intended fix shape, and the issue tracker already notes that the remaining gap is a fresh UI repro rather than a known code defect.

## Prunr reset skill

- [x] Add a repo-local `prunr-reset` skill for clean reinstall testing
- [x] Implement a deterministic reset script for app uninstall, state purge, rebuild, and reinstall
- [x] Validate the script wiring and document usage

## Prunr reset skill review

- Added a repo-local skill at [.agents/skills/prunr-reset/SKILL.md](/Users/merlinkraemer/dev/projects/prunr/.agents/skills/prunr-reset/SKILL.md) with UI metadata in [.agents/skills/prunr-reset/agents/openai.yaml](/Users/merlinkraemer/dev/projects/prunr/.agents/skills/prunr-reset/agents/openai.yaml).
- The bundled script at [.agents/skills/prunr-reset/scripts/reset-prunr.sh](/Users/merlinkraemer/dev/projects/prunr/.agents/skills/prunr-reset/scripts/reset-prunr.sh) stops the app, removes `/Applications/Prunr.app`, clears `~/Library/Application Support/Prunr`, clears standard per-user cache/state paths for bundle id `com.prunr.app`, then runs `make install-app`.
- Verification: `bash -n .agents/skills/prunr-reset/scripts/reset-prunr.sh` passed and the script was marked executable.

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
- Remove only the unused windowed app shell and view tree that is no longer reachable from the app entrypoint.

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

## Merge review: architecture fixes Phase 6-7

- [x] Inspect latest merge commit and isolate the merged Phase 6 / Phase 7 changes
- [x] Compare merged code against `docs/action-plan-architecture-fixes.md`
- [x] Run project verification for the merged state
- [x] Document review findings and manual test coverage

## Merge review notes

- Reviewed merge `f0b6c9a` (`refactor/phase7-fsevents-coalescing`), which contains `90bb0cf` (Phase 6 single-source-of-truth refactor) and `cb6f93e` (Phase 7 FSEvents `NoDefer` + post-scan flush).
- Phase 6 code shape largely matches the plan: `allCategories` is now the stored source of truth, `growingCategories` / `stableCategories` / `stableTotalBytes` are computed, and `normalizeVisibleInventoryState()` plus the merge helpers were removed.
- Phase 7 code shape also matches the plan: `kFSEventStreamCreateFlagNoDefer` was added and `MenuBarManager` now flushes the watcher after a successful scan.
- Verification:
- `make build` passed.
- `make test` failed with 3 smoke-test failures:
- `testFirstBaselineClearsStaleRealtimeGrowthState`
- `testMenuBarManagerRecentChangeRefreshUsesLiveSubcategoryStructureForAffectedCategory`
- one additional failure in the same recent-change path (`XCTUnwrap` on the missing `node_modules` subgroup inside that test)
- Review findings:
- The Phase 6 refactor changed category sorting semantics. Before the refactor, `normalizeVisibleInventoryState()` used a stable secondary sort by category display name when byte sizes were equal. The new computed properties sort only by byte size. Equal-sized categories can now reorder between refreshes, which violates the phase goal of preserving identical UI behavior and risks visible list/segment jitter.
- Independent of root cause, the merged state does not pass the project test suite, so the phase cannot be considered validated against the implementation doc's regression expectations yet.

## Scan indicator audit

- [x] Document `npm run monitor` in repo-local agent guidance
- [x] Audit footer scan-indicator behavior without changing runtime code
- [x] Record the likely cause and next fix boundary

## Scan indicator audit review

- Added concise monitor usage notes to [AGENTS.md](/Users/merlinkraemer/dev/projects/prunr/AGENTS.md) and [CLAUDE.md](/Users/merlinkraemer/dev/projects/prunr/CLAUDE.md) because the repo did not previously contain project-local copies.
- Category bloat appears addressed in the current refactor path: the live scan no longer exposes repeated category-row growth, and the refactor now derives visible lists from `allCategories` instead of mutating duplicate presentation arrays.
- The footer indicator is broader than the intended product behavior. [MenuBarView.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Views/MenuBarView.swift#L1582) shows the footer whenever `isBackgroundFullScanRunning || isAutoScanning`.
- `isBackgroundFullScanRunning` is just `isReconciling` in [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L152), which matches the scheduled stale full-rescan path in [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L1179).
- But `isAutoScanning` is also set for other automatic full-scan paths that are not the periodic background reconcile:
- [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L836) marks any `loadInventory(isAutomatic: true)` run as auto-scanning.
- [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L1086) uses that path for `refreshVisibleInventory()`.
- [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L2516) and [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L2575) use that same path when recent-change refresh escalates into a full refresh.
- That means the footer can stay active during watcher-driven automatic rescans or post-scan escalations, even if the user expectation is “only show during the recurring scheduled full scan”.
- The footer also is not animated today beyond the menu-bar title pulse. [MenuBarView.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Views/MenuBarView.swift#L1590) renders a static dot plus text, while the only scan pulse is the status-item alpha effect in [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L2015).
- Settings already support a dynamic recurring full-scan interval, but it is inferred from first-scan wall-clock duration, not directly from scan-path size. See [SettingsStore.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/ViewModels/SettingsStore.swift#L241) and [SettingsView.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Views/SettingsView.swift#L124). The user can then override it with fixed presets in Settings.
- Recommended fix boundary for the next pass: separate “scheduled background full reconciliation” state from generic “automatic full refresh” state, then key the footer indicator and subtle animation only off the scheduled background state.

## Test suite expansion

## Scan indicator fix

- [x] Commit the current checkpoint before changing runtime behavior
- [x] Narrow the footer scan indicator to scheduled background full reconciliations only
- [x] Add a subtle footer-only animation for scheduled background full reconciliations
- [x] Re-run focused verification for scan-indicator state selection and UI rendering

## Scan indicator fix review

- Checkpoint commit created before the runtime change: `43fe976` (`chore: checkpoint refactor and monitor tooling`).
- The footer indicator now keys only off the scheduled background reconciliation state instead of the broader `isAutoScanning` bucket. [MenuBarView.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Views/MenuBarView.swift#L1581) now shows the footer status row only when `manager.isBackgroundFullScanRunning` is true.
- Automatic full refreshes triggered by watcher escalation or other `loadInventory(isAutomatic: true)` paths no longer keep the footer status visible by themselves. That preserves the audit boundary without changing those runtime paths elsewhere.
- The footer now adds a subtle pulse to the dot and label only while the scheduled background reconciliation indicator is visible. [MenuBarView.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Views/MenuBarView.swift#L1593)
- Verification: `make build` passed.
- Verification: `xcodebuild -project Prunr.xcodeproj -scheme Prunr -destination 'platform=macOS' test -only-testing:PrunrTests/MenuBarManagerRegressionTests` passed.
- Manual runtime verification still matters for product feel: confirm the footer stays quiet during long initial/manual scans and recent-change refreshes, then briefly appears with the new pulse only when the recurring stale reconciliation fires.

- [x] Audit the current local suite and GitHub CI status
- [x] Fix the red baseline/incremental-refresh regressions on `main`
- [x] Split coverage into focused XCTest files by subsystem instead of one monolithic smoke file
- [x] Add targeted regression coverage for ordering stability and first-baseline/live-working-set behavior
- [x] Regenerate the Xcode project so new test files are included
- [x] Re-run focused tests and the full `make test` suite

## Test suite review

- GitHub CI is not red because of a failing workflow; this repo currently has no app-owned GitHub Actions workflow configured. `gh run list` returned no runs, the repo has no top-level `.github/workflows`, and the merge commit had no attached status contexts.
- The local suite was the real blocker. `main` started red with 3 failing tests around first-baseline cleanup and post-refactor incremental drill-down behavior.
- Runtime fixes landed in the scan/journal path and manager refresh path:
- first successful baseline now rebuilds the tracked-path working set from the new snapshot and clears stale growth-journal buckets
- single-snapshot realtime growth is now allowed to surface in inventory when there is exactly one valid baseline snapshot
- incremental recent-change refresh now marks the manager as working-set-backed, invalidates cached drill-down data, and reloads inventory from DB ground truth
- category ordering now restores the deterministic secondary sort by category display name when byte totals are equal
- Test-suite expansion:
- added shared test harness in [PrunrTestCase.swift](/Users/merlinkraemer/dev/projects/prunr/PrunrTests/TestSupport/PrunrTestCase.swift)
- added focused regression coverage in [BaselineServiceRegressionTests.swift](/Users/merlinkraemer/dev/projects/prunr/PrunrTests/BaselineServiceRegressionTests.swift)
- added focused regression coverage in [MenuBarManagerRegressionTests.swift](/Users/merlinkraemer/dev/projects/prunr/PrunrTests/MenuBarManagerRegressionTests.swift)
- regenerated [project.pbxproj](/Users/merlinkraemer/dev/projects/prunr/Prunr.xcodeproj/project.pbxproj) with `xcodegen generate` so the new test files are part of `PrunrTests`
- Verification:
- targeted regression run passed after the fixes
- `make test` passed with 45 tests, 0 failures

## CI setup

- [x] Add a GitHub Actions workflow for PRs and main-branch pushes
- [x] Add a repo-owned SwiftLint configuration for CI linting
- [x] Verify the workflow inputs locally where possible

## Live scan monitor

- [x] Inspect the current live scan state, persisted runtime surfaces, and recent refactor behavior to define monitor checks
- [x] Add a repo-local `npm run monitor` command for live scan inspection
- [x] Sample live process CPU/RSS, SQLite snapshot/category state, autoscan defaults, and permission/log anomalies
- [x] Run the monitor against the current home-directory scan and validate the output shape
- [x] Record review notes and any follow-up bugs found

## Live scan monitor review

- Added a dependency-free CLI at [scripts/monitor.mjs](/Users/merlinkraemer/dev/projects/prunr/scripts/monitor.mjs) plus [package.json](/Users/merlinkraemer/dev/projects/prunr/package.json) so the repo now supports `npm run monitor`.
- The monitor samples the live `Prunr` process with `ps`, reads autoscan/root config from `defaults export com.prunr.app -`, inspects `~/Library/Application Support/Prunr/prunr.db` with `sqlite3 -json`, and scrapes unified logs with `/usr/bin/log show`.
- Current checks cover:
- scan progress on the newest snapshot via `snapshotEntry` row/byte deltas
- CPU / RSS growth and simple leak / stall heuristics
- category-total inflation or staleness versus `workingSetEntry`
- autoscan interval / adaptive scheduling visibility
- permission-related and repeated CacheDelete log anomalies
- Verification against the active full-home scan:
- `npm run monitor -- --help` passed
- `npm run monitor -- --samples 2 --interval 2` reported the live process and current snapshot growth correctly
- `npm run monitor -- --samples 1` reported snapshot `#7`, active CPU around `100%`, RSS in the `126-310 MB` range during sampling, and a persistent warning that category totals lagged working-set updates by about `3m22s`
- Follow-up bug candidate: during the active full scan, `workingSetEntry.updatedAt` advanced with snapshot `#7` while `workingSetCategoryTotal.updatedAt` stayed pinned to the prior timestamp for multiple monitor samples. That may be an expected end-of-scan batch boundary, but it is the first runtime signal worth validating once this scan completes.
- [x] Document branch-gating guidance

## CI review

- Added [ci.yml](/Users/merlinkraemer/dev/projects/prunr/.github/workflows/ci.yml) to run on pull requests to `main`, pushes to `main`, and manual dispatch.
- The workflow has three required-quality jobs:
- `repo-checks`: installs `xcodegen`, regenerates the project, and fails if [project.pbxproj](/Users/merlinkraemer/dev/projects/prunr/Prunr.xcodeproj/project.pbxproj) is out of sync with [project.yml](/Users/merlinkraemer/dev/projects/prunr/project.yml)
- `lint`: installs `swiftlint` and runs the repo-owned config from [.swiftlint.yml](/Users/merlinkraemer/dev/projects/prunr/.swiftlint.yml)
- `build-and-test`: regenerates the project, runs `make build`, then runs `make test`
- The lint config is intentionally narrow and repo-owned so CI enforces consistent hygiene without introducing a large surprise rule set all at once.
- To make the lint job green, trailing whitespace and double-blank-line violations were cleaned across the tracked Swift sources.
- Local verification:
- `swiftlint lint --strict --config .swiftlint.yml` passed
- workflow YAML structure parsed successfully
- re-running `xcodegen generate` left [project.pbxproj](/Users/merlinkraemer/dev/projects/prunr/Prunr.xcodeproj/project.pbxproj) byte-identical
- `make test` passed with 45 tests, 0 failures
- Branch gating recommendation: in GitHub branch protection for `main`, require the `Repo Checks`, `SwiftLint`, and `Build And Test` status checks before merge. That part is repository settings, not code, so it still needs to be toggled in GitHub.

## Beta idle/scrollbar fix pass

- [x] Identify root cause of idle CPU spike (FSEvents watcher loop)
- [x] Disable automatic file watcher (`enableAutomaticFileWatcher = false`)
- [x] Fix drilldown scrollbar visibility (recursive `HiddenScrollIndicators`)
- [x] Implement lazy NSHostingView teardown on popover close
- [x] Validate idle CPU/RSS with `npm run monitor`
- [x] Re-run `make build` and `make test`

## Beta idle/scrollbar fix review

- Root cause: `FSEventsWatcher` continuously delivered filesystem events to `RecentChangeService`, which triggered database writes and full working-set replacement even when no meaningful changes occurred. This created a sustained ~100% CPU background loop.
- Fix: set `enableAutomaticFileWatcher = false` in `MenuBarManager` to stop background processing while idle.
- Fix: enhanced `HiddenScrollIndicators` to recursively find sibling `ScrollViews` in the window hierarchy and trigger updates on layout changes, ensuring scrollbars stay hidden in drilldown even if the view hierarchy shifts.
- Fix: uninstall the panel's `NSHostingView` when the popover closes, eliminating SwiftUI display-cycle overhead while the panel is hidden.
- Validation: `npm run monitor` confirmed CPU dropped from ~100% to ~0.01% at idle and RSS stabilized around ~50 MB.
- Verification: `make build` passed, `make test` passed.
