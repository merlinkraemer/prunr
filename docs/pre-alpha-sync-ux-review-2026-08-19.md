# Pre-alpha sync and UX review — 2026-08-19

## Verdict

**No-go for the next external alpha in the current state.** The ordinary scan,
incremental update, watcher, and database happy paths are well covered and pass
at both 5,000 and 50,000 files. The release is blocked by correctness gaps in
first-run failure handling, pending scope changes, dirty-event recovery,
permission handling, baseline labeling, destructive-operation concurrency, and
the live feedback path.

This review covers the current filesystem, including the uncommitted screenshot
tooling, rather than only `main` at `8be3c8e`.

## End-to-end system flow

1. `AppDelegate` initializes SQLite, starts cleanup, evaluates scan access, and
   restores monitoring (`Prunr/PrunrMenuBar.swift:29-46`,
   `Prunr/Services/MenuBarManager.swift:2030-2037`).
2. Existing data is shown in two passes when the panel opens: working-set
   category totals first, then growth stories, snapshot metadata, disk
   accounting, and path sizes (`Prunr/Views/MenuBarView.swift:447-477`).
3. An FSEvents stream starts at `kFSEventStreamEventIdSinceNow`, filters known
   noise, and classifies batches as normal paths or dirty/dropped
   (`Prunr/Services/FSEventsWatcher.swift:52-120,184-229`).
4. Normal paths debounce for 1.5 seconds, route to the most specific tracked
   root, and become file, subtree, or removal updates
   (`Prunr/Services/MenuBarManager.swift:3005-3225`,
   `Prunr/Services/RecentChangeService.swift:45-128`).
5. Incremental updates replace working-set rows and category totals, append
   minute-bucketed growth deltas, and reload inventory from database truth.
6. Dirty batches and the periodic backstop run a full scan. A completed isolated
   snapshot replaces the working set, provisional journal buckets are reclaimed,
   authoritative deltas are recorded, and the UI reloads
   (`Prunr/Services/BaselineService.swift:90-170`,
   `Prunr/Services/MenuBarManager.swift:1493-1592`).
7. Reset creates a snapshot from the live working set and clears the journal;
   scan-scope Apply deletes all snapshots and realtime data, leaving onboarding
   to create a fresh baseline.

## Actual user flow and visible states

### First run

- The panel starts with a skeleton while access and cached data are checked.
- With no baseline, onboarding has Folder → Access → Scan pages.
- Folder choice is persisted immediately. Access is probed asynchronously.
- Starting Scan calls the same full inventory pipeline as a manual scan.
- A successful scan transitions to the category overview; Stop, permission
  failure, and scan failure currently have broken transitions described below.

### Returning user

- Cached totals render first, then richer snapshot/journal data replaces them.
- The drive bar remains fixed while list/header panes slide between overview,
  category, and file levels.
- Footer priority is: update available → tracking broken → background refresh →
  changes pending → outside-scope context → empty.
- Manual refresh only flushes queued FSEvents paths; it intentionally refuses to
  trigger a full scan.
- Growth Reset is optimistic: the orange pill morphs immediately, then the DB
  baseline operation runs in the background.

### Settings

- Scope controls edit the shared persisted settings immediately and set a
  `hasPendingScopeChanges` flag.
- Apply confirms destructive snapshot deletion, resets state, and tells the user
  to return to the menu bar for a new scan.
- Troubleshooting exposes feedback, diagnostics, compaction, and full data reset.

## P1 — release blockers

### 1. First-scan failure exits onboarding without a baseline

`loadInventory` sets `noBaseline = false` before scanning
(`Prunr/Services/MenuBarManager.swift:1171-1175`). Cancellation, permission
denial, and general scan errors do not restore it (`:1271-1311`). The body then
selects the main category UI instead of onboarding
(`Prunr/Views/MenuBarView.swift:374-393`). Stop can therefore land on partial or
empty inventory; a failed first scan can strand the user on Retry rather than
the folder/access/scan flow.

**Required:** keep baseline state unchanged until the first snapshot is fully
published. On first-scan cancellation/failure, remain on Scan or Access with a
specific recovery action.

### 2. “Pending” scope edits are already live

`setMainBasePath`, common-location toggles, and enabled-path changes persist
immediately (`Prunr/ViewModels/SettingsStore.swift:54-62,283-334`). All manager
consumers read the same live `enabledTrackedPaths`; the 60-second timer can
reconfigure the watcher before Apply (`Prunr/Services/MenuBarManager.swift:2551-2559,2818-2857`).
The main path UUID is stable, so a relaunch can associate old snapshots with the
new root before the promised reset.

**Required:** stage a draft scope separately and commit it atomically on Apply,
or make changes explicitly immediate and perform the reset as part of each edit.
Closing Settings or relaunching must not produce a new-root/old-snapshot hybrid.

### 3. The “since” label is not anchored to the user reset

Growth journal buckets accumulate until Reset, but the displayed date is chosen
from the latest snapshot's comparable predecessor
(`Prunr/Services/BaselineService.swift:230-251,1015-1047`). After another
reconciliation, that predecessor advances even though older journal growth is
preserved (`:143-169`). Small scopes with at most 100 entries can fall back to
the current snapshot (`:348-373`). The UI can therefore show cumulative growth
from an older reset while saying “since” a much newer automatic scan.

**Required:** persist an explicit per-path user baseline/reset timestamp or
baseline snapshot ID. Automatic reconciliation must never move that anchor.

### 4. Dirty/dropped filesystem events are intentionally lost

A dirty batch during a full scan is ignored outright
(`Prunr/Services/MenuBarManager.swift:2883-2892`), even though the watcher is
armed before the scan to catch concurrent mutations (`:2986-3003`). Dirty
escalation is also dropped during `max(30 minutes, automaticFullScanInterval)`,
which is 24 hours by default (`:3317-3355`,
`Prunr/ViewModels/SettingsStore.swift:41-43`). Tests currently codify both lossy
behaviors (`PrunrTests/PrunrSmokeTests.swift:1897-1936,2000-2015`).

**Required:** retain a durable `needsAuthoritativeReconciliation` bit. If it is
raised during a scan, reconcile after completion. If raised during cooldown,
schedule at cooldown expiry rather than clearing the signal.

### 5. Unreadable subtrees become a successful authoritative scan

The scanner logs `FTS_DNR`, `FTS_ERR`, and `FTS_NS` and continues
(`Prunr/Services/FileScanner.swift:208-222`). The scan is then finalized and its
incomplete snapshot replaces the whole working set
(`Prunr/Services/ScanService.swift:425-470`,
`Prunr/Services/BaselineService.swift:132`). Permission changes or unprobed
protected directories can silently shrink inventory and erase known rows.

**Required:** collect traversal failures and refuse authoritative publication,
or explicitly preserve old rows for failed subtrees and surface partial coverage.

### 6. Permission denial can be interpreted as deletion

Incremental target resolution treats `fileExists == false` as removal, and
subtree refresh replaces a missing root with an empty set
(`Prunr/Services/RecentChangeService.swift:130-156,196-224`). `fileExists` does
not distinguish `ENOENT` from `EACCES`/`EPERM`, so revoking access can delete
previously valid working-set rows and journal a shrink.

**Required:** use an operation that exposes errno. Only `ENOENT` is deletion;
permission failures must preserve old data, mark tracking degraded, and retry.

### 7. Full and incremental scans use different inclusion rules

Full traversal excludes ignored names and problematic roots such as Mail,
Photos, iCloud, and Trash (`Prunr/Services/FileScanner.swift:241-264`). Direct
incremental file targets do not apply the same ignored-name or ancestor rules
(`Prunr/Services/RecentChangeService.swift:79,83-106,196-224`). An event inside
an excluded tree can enter the working set, then disappear on the next full scan,
creating sawtooth totals and false growth.

**Required:** centralize one scope predicate and use it for traversal, watcher
filtering, direct targets, and subtree targets.

### 8. Reset operations can race active scans/reconciliation

Troubleshooting Reset and Compact are not disabled by `ScanService.isScanning`
(`Prunr/Views/SettingsView.swift:237-266`). `performReset` has no busy guard or
scan cancellation (`Prunr/Services/MenuBarManager.swift:1005-1013`). Growth
Reset also does not guard `isReconciling` (`:1441-1447`), and its button is only
disabled by `isAcceptingGrowth` (`Prunr/Views/MenuBarView.swift:1383-1435`).
Deleting or replacing snapshots while a scan is publishing can produce partial,
surprising, or failed state.

**Required:** serialize reset, scope apply, compaction, incremental refresh, and
full-scan publication through one operation coordinator. Disable destructive UI
while any conflicting operation is active.

### 9. A first-scan process death leaves a partial snapshot looking valid

The snapshot row is created before enumeration
(`Prunr/Services/ScanService.swift:191-202`). Normal errors delete it, but a
crash/kill cannot. Startup cleanup finds abandoned snapshots by joining an
existing working set (`Prunr/Services/DatabaseCleanupService.swift:173`); the
first-ever scan has none. `checkBaseline` then accepts any recent snapshot
(`Prunr/Services/MenuBarManager.swift:2001-2025`).

**Required:** add explicit `scanning`/`complete` snapshot lifecycle state. Every
read must select complete snapshots only; startup must delete all incomplete
rows, including first-run rows with no working set.

### 10. In-app feedback is deployed to a dead endpoint

The client posts to `https://prunr-web.vercel.app/api/feedback`
(`Prunr/Services/FeedbackService.swift:28`), but live OPTIONS and GET return
Vercel `404 NOT_FOUND`. The function exists only in
`website/api/feedback.js`; the Pages workflow deploys static files only
(`.github/workflows/pages.yml:31-37`).

**Required:** deploy the function, verify OPTIONS, send a real feedback message,
and confirm Brevo delivery with the diagnostics attachment before shipping.

### 11. Release verification can pass without verifying live sync or first run

The runtime E2E watcher assertion only warns when the created file is not
observed (`scripts/e2e-runtime.sh:364-394`), so the suite can print ALL PASSED
with broken app-level sync. It also pre-seeds SQLite and launches with an
existing baseline (`:116-193`), bypassing DMG install, quarantine, onboarding,
access denial/grant, initial scanning, cancellation, and recovery. CI does not
run either E2E, and release does not require a green CI SHA
(`.github/workflows/ci.yml:17-67`, `.github/workflows/release.yml:40-139`).

**Required:** make watcher detection fatal, add a real clean-install UI smoke,
and gate publishing on green build/tests plus headless E2E for the exact SHA.

### 12. Runtime permission loss is not reflected immediately

A scan can populate `runtimeBlockedLocations`, but the view only merges those
labels; it does not set `hasRequiredScanAccess = false` or clear
`isPermissionConfirmedForProtectedTraversal`
(`Prunr/Services/MenuBarManager.swift:1300-1305`,
`Prunr/Views/MenuBarView.swift:413-416`). The access banner and broken-tracking
footer can remain absent until a later explicit permission probe.

**Required:** permission failures must update one shared typed tracking-health
state immediately and expose the correct Open Privacy Settings recovery.

### 13. Some automatic full scans look healthy while running

`isBackgroundFullScanRunning` only mirrors `isReconciling`
(`Prunr/Services/MenuBarManager.swift:228-230`), while dirty-root automatic scans
use `isAutoScanning` (`:1161-1169`). The footer's Refreshing branch watches only
the former (`Prunr/Views/MenuBarView.swift:1654-1673`). Because pending flags are
cleared at scan start, a long automatic scan can show normal outside-scope copy.

**Required:** derive all scan/footer/button state from one operation state rather
than partially overlapping booleans.

### 14. Generic Retry can invoke the wrong recovery

Every operation writes one `errorMessage`, and the only Retry always runs a full
filesystem scan (`Prunr/Views/MenuBarView.swift:1498-1513`). A failed growth
reset, for example, sets “Couldn't accept growth”
(`Prunr/Services/MenuBarManager.swift:1473-1477`), but Retry starts a scan instead
of retrying/dismissing the baseline operation.

**Required:** use a typed error plus typed recovery action: retry scan, retry
reset, open access settings, dismiss, or reveal diagnostics.

### 15. The drive bar presents deliberately distorted proportions as capacity

The bar enforces a minimum 42% used display, caps outside-scope/filler at 38%,
and gives each category at least 3% (`Prunr/Views/DriveBarView.swift:38-39,
162-228`). A 10%-used disk can look 42% used and a dominant unscanned portion is
visually suppressed, without an adjacent used/free legend explaining that this
is schematic.

**Required:** render truthful proportions, or label the view clearly as a
categorical composition and surface exact used/free/outside-scope values.

## P2 — important follow-ups

### Sync and persistence

- **Downtime gap:** FSEvents starts at `SinceNow` and no event ID is persisted.
  Changes while Prunr is quit can remain stale until the daily reconciliation
  (`Prunr/Services/FSEventsWatcher.swift:227`,
  `Prunr/Services/MenuBarManager.swift:1575-1592`). Reconcile once at launch or
  persist/resume an event ID.
- **Incremental failures are consumed:** per-target and snapshot-check failures
  return `noChanges` after the manager has removed paths from its pending set;
  working-set mutation and journal append are separate transactions
  (`Prunr/Services/RecentChangeService.swift:49-55,83-127`,
  `Prunr/Services/MenuBarManager.swift:3072-3081`). Requeue failed targets and
  publish working set plus journal atomically.
- **Full-scan publication is multi-step:** working-set rebuild, journal deletion,
  delta calculation, and journal append can be interrupted between commits
  (`Prunr/Services/BaselineService.swift:132-169`). Snapshot completion should be
  the final atomic status transition.
- **Same-minute double count:** journal timestamps are floored to a minute, while
  reconciliation deletes only buckets strictly newer than the precise previous
  snapshot date (`Prunr/Services/GrowthJournalService.swift:13-23,129-133`,
  `Prunr/Database/DatabaseManager.swift:564-577`). A realtime change seconds
  after a snapshot can survive and be counted again.
- **False healthy watcher state:** `watchedPaths` is set before watcher startup
  succeeds, while `isGrowthTrackingActive` trusts the array
  (`Prunr/Services/MenuBarManager.swift:566-570,2854-2879`). Return startup status,
  clear the array on failure, and retry visibly.
- **Multi-root publication is not all-or-nothing:** sibling scans run concurrently;
  one can publish a new snapshot/working set before another throws and causes the
  task group to fail (`Prunr/Services/MenuBarManager.swift:1085-1142`). Define and
  test whether partial root success is allowed; otherwise stage and commit the set.

### UI states, motion, and accessibility

- **Reset success is optimistic and can be false:** the growth pill shows “Set as
  New Baseline!” before the DB operation succeeds, and Settings data reset shows
  success even though manager errors are only logged
  (`Prunr/Views/MenuBarView.swift:1383-1403`,
  `Prunr/Views/SettingsView.swift:337-349`,
  `Prunr/Services/MenuBarManager.swift:1006-1012`). Tie success motion/copy to the
  actual result and expose failure.
- **Scope Apply failures are silent:** its catch block preserves pending state but
  gives no error (`Prunr/Views/SettingsView.swift:640-662`). The success text says
  “Snapshot reloaded” even though the baseline was deleted and the user must scan
  again (`:556-566,603-607`).
- **Cached inventory is hidden when permission probing fails:** the panel returns
  before `loadQuickInventory` (`Prunr/Views/MenuBarView.swift:454-465`), leaving a
  returning user with an empty main view instead of last-known data plus a clear
  stale/blocked banner.
- **Reduced Motion is ignored:** there is no `accessibilityReduceMotion` handling.
  Pane slides, onboarding slides, pulsing status indicators, skeleton shimmer,
  hover morphs, and status-item alpha loops always animate. Route all meaningful
  motion through one policy and replace repeating pulses/slides with static state
  under Reduce Motion.
- **Accessibility coverage is sparse:** the drive bar and toolbar icons have
  explicit labels, but the custom onboarding progress controls, growth-reset
  morph, status text, category/drilldown state, and progress changes need a full
  VoiceOver pass and identifiers for UI automation.
- **Feedback disclosure:** Send always attaches diagnostics, app/macOS version,
  and an install UUID, but visible copy does not disclose that
  (`Prunr/Views/SettingsView.swift:179-205,294-310`). Disclose attachment content
  before sending; add server-side rate limiting because the shared token is public.

### Release operations and diagnostics

- Diagnostics can report success after a suppressed write failure
  (`Prunr/Extensions/PerfSignpost.swift:200-212,338-350`). Propagate the result.
- Temporary path-unredacted unified logging remains in release code
  (`Prunr/Services/ScanService.swift:514-516`,
  `Prunr/Services/FileScanner.swift:107,208-221`). Remove it before external use.
- Sparkle banner state has unit coverage, but no previous signed alpha → candidate
  update test exists. Release tooling uses Sparkle 2.6.4 while the app resolves
  2.9.2 (`.github/workflows/release.yml:37-39`, package resolution).

## What is already strong

- Bounded FSEvents callback allocation, drop/root detection, internal DB noise
  filtering, dirty backoff, generation-based debounce cancellation, and pending
  path caps.
- Per-scan cancellation tokens, a traversal watchdog, isolated scan snapshots,
  failed-scan cleanup, and staged transactional subtree replacement.
- Working-set category totals update in the same transaction as normal file and
  subtree changes.
- The panel avoids hidden SwiftUI hosting views, which keeps observed idle CPU at
  0% in the existing installed app during this review (about 83 MB RSS).
- UI hierarchy and ordinary motion are coherent: fixed drive context, coordinated
  pane/header slides, live scan feedback, explicit pending/background/broken
  footer states, and useful hover affordances.
- Unit coverage is broad for happy-path scan, watcher, incremental refresh,
  cancellation, cleanup, backoff, working-set restoration, prefix-safe removals,
  allocated-byte accounting, and ordinary reconciliation de-duplication.

## Verification performed

- `make test`: **83 tests, 0 failures**.
- `scripts/e2e.sh --file-count 5000`: **10/10 phases passed**, 6.8 seconds.
- `scripts/e2e.sh --file-count 50000`: **10/10 phases passed**, 65.0 seconds.
- Live feedback endpoint OPTIONS: **404 NOT_FOUND**.
- Existing installed Prunr idle sample: **0.0% CPU, ~83 MB RSS**.
- Accessibility scripting is disabled on this Mac, so automated inspection of the
  live status-item panel and animation capture was not possible.
- `scripts/e2e-runtime.sh` was inspected but not executed because it explicitly
  deletes `~/Library/Application Support/Prunr`, clears app defaults, replaces
  `/Applications/Prunr.app`, and still treats watcher failure as non-fatal.

## Minimum next-alpha gate

1. Fix P1 items 1-15; at minimum do not ship with first-run, dirty-event,
   permission, scope/baseline, reset-race, or feedback correctness unresolved.
2. Add focused regressions for every fixed state, especially crash during first
   scan, unreadable subtree, permission-revoked target, dirty event during/after
   scan, same-minute reconciliation, relaunch with pending scope, and reset while
   scanning.
3. Make runtime watcher detection fatal and add a clean-user first-run smoke.
4. Run unit tests, 5k/50k headless E2E, a non-destructive runtime E2E, VoiceOver +
   Reduce Motion checks, signed DMG/Gatekeeper install, Sparkle upgrade from the
   previous alpha, and live feedback delivery.
5. Release only the reviewed clean commit and require green checks for that SHA.
