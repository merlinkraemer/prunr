# Todo: Cache-owner app icon mapping — 2026-08-22

- [x] Map common vendor cache-owner keys to their installed application bundle IDs.
- [x] Keep native installed-app icons as the preferred result.
- [x] Add resolver regression coverage; build and install.

## Review

`Google`, `Adobe`, and `Steam` now map to their installed application bundles:
Chrome, Creative Cloud, and Steam. Bundle-ID resolution remains preferred, then
known app paths handle delayed Launch Services registration. We intentionally do
not redistribute third-party artwork for stale cache folders after uninstallation.

- Focused resolver regression: **1 test, 0 failures**
- `make test`: **116 tests, 0 failures**
- `make install-app`: installed `/Applications/Prunr.app`

# Todo: Cache drilldown application icons — 2026-08-22

- [x] Identify cache-owner naming variants that bypass the installed-app resolver.
- [x] Resolve those variants to native application icons while preserving the generic fallback.
- [x] Add regressions and run focused/full tests.

## Review

Cache drilldowns now resolve raw app-name cache directories through Launch
Services, and generic `.ShipIt` / `.helper` cache keys retry as their base bundle
IDs. The pre-existing browser fallbacks now also work for apps installed in the
user's Applications directory. Ambiguous vendor/service cache directories retain
the generic app icon.

- Focused resolver regression: **1 test, 0 failures**
- `make test`: **116 tests, 0 failures**

# Todo: Trust plan — 2026-08-21

# Todo: Stable refresh control — 2026-08-22

- [x] Keep automatic watcher refreshes from dimming the manual refresh icon; verify manual refresh joins correctly.

## Review

Automatic watcher work no longer disables the manual refresh button. A manual
check waits for the current short automatic pass, then runs rather than being
dropped. Regression coverage verifies that join behavior.

# Todo: Silent automatic watcher refreshes — 2026-08-22

- [x] Keep short automatic incremental refreshes out of the footer; verify no footer churn regressions.

## Review

Automatic incremental watcher refreshes are intentionally silent. The footer now
reports only manual checks, full-scan work, or exceptional queued reconciliation.

- `make test`: **114 tests, 0 failures**

# Todo: Quiet watcher footer — 2026-08-22

- [x] Hide routine watcher backlogs from the footer and retain a completed update briefly.
- [x] Verify manager presentation rules and the full suite; install only after verification.

## Review

Routine watcher backlog is no longer a footer state. The footer only reports
real work, exceptional queued reconciliation, or idle context; a completed
storage update remains visible for 1.5 seconds to avoid a visual handoff.

- `make test`: **114 tests, 0 failures**

# Todo: Watcher soak and truthful footer — 2026-08-22

- [x] Present concrete footer activity (scan progress, change update, queued reconciliation) from one manager state model.
- [x] Add deterministic sustained-watcher coverage that verifies queued changes drain without a full scan.
- [x] Run the XCTest suite, large static scan stress harness, and an end-to-end watcher check; report the remaining leak-test gap.

## Review

Footer copy now distinguishes scanning (with a reliable percentage), finalizing,
inventory analysis, change updates, queued reconciliation, and normal queued
changes. The watcher stress test injects 1,000 rapid normal batches and proves
one retained deadline, no reschedules, one execution, and an empty queue.

- `make test`: **114 tests, 0 failures**
- `make e2e E2E_FILE_COUNT=50000`: **10/10 phases passed**
- Static scan stress: **250,000 files**, stable repeated scans, then exact
  detection of a **10,000-file / 10.24 GB** mutation. Results:
  `tmp/stress-results/report.json`.

The static harness and XCTest stress prove correctness under load, but do not
measure a long-run RSS or file-descriptor trend. A 5–15 minute real-app watcher
soak with those thresholds remains a separate test-harness addition.

# Todo: Feedback evidence — pending state and CPU — 2026-08-22

- [x] Stop sustained normal FSEvents from indefinitely resetting the refresh debounce.
- [x] Include privacy-safe pending-queue and scheduler state in diagnostics.
- [x] Add a regression for repeated normal watcher batches and run focused/full tests.

## Review

The alpha.12 report `dc4ba2f2-e7a8-472c-ada0-a22c33dacb65` proves 107 watcher
batches / 507 accepted paths in 109 seconds, with pending state and zero
incremental refreshes. It also reports real Prunr CPU (89.1% at submission),
but lacks enough scheduler state to attribute the heat precisely.

Normal watcher batches now retain the first 1.5s refresh deadline rather than
restarting it. Diagnostics additionally report queue count, dirty/reconciliation
state, event age, deadline, and schedule/execution/reschedule counters. The
continuous-watcher regression and full suite passed: **108 tests, 0 failures**.

# Todo: Agent-accessible feedback inbox — 2026-08-22

- [x] Persist each accepted feedback submission in Vercel KV before notifying via Brevo.
- [x] Add bearer-authenticated agent list, detail, and triage endpoints.
- [x] Add API-level regression coverage and run app/API tests.
- [ ] Configure the production KV and agent-token environment variables.

## Review

Implemented the Vercel KV-backed inbox, agent API, rate limiting, and API
regressions. Setup and CLI examples: `docs/feedback-agent-api.md`.

- `npm run test:api`: **3 tests, 0 failures**
- `make test XCODE_EXTRA_FLAGS='CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='`:
  **107 tests, 0 failures**

Full plan: `docs/trust-plan-2026-08-21.md`. Context: `docs/ux-review-brief-2026-08-21.md`.
Phases 1-3 are the trust core and block the cleaning feature.

## Phase 0 — decisions — SETTLED
Superseded by `docs/prd-signed-growth-2026-08-21.md` (via `docs/growth-framing-2026-08-21.md`).
- [x] D-1: not a baseline at all — fixed 7-day rolling window, no user-managed mark
- [x] D-2: decoupled — `displayWindowDays = 7`, retention governs pruning only, clamped >= 7
- [x] D-3: one change-ranked list, growth as a signed row delta (no growing/stable split)

## Phase 1 — signed net change over a fixed 7-day window — SHIPPED
Spec: `docs/prd-signed-growth-2026-08-21.md`.
- [x] Slice 1 — signed math: dropped `deltaBytes > 0`; 1 MB floor is presentation-only
- [x] Slice 2 — fixed window: `displayWindowDays`, prune clamp, constant `last 7 days` label
- [x] Slice 3 — one list: change-rank sort (|delta| desc, then size desc)
- [x] Slice 4 — header is not a button; zero state renders literal `0 MB`
- [x] Regression tests (PRD §9): signed sum incl. sub-floor, net-zero -> no story,
      window/retention independence, retention clamp, sort rule, header == Σ deltas

## Phase 2 — typed drilldown outcomes (D4)
- [ ] Result type `loaded | empty | failed | unavailable` through BaselineService's 12 catch blocks
- [ ] Four distinct states in `CategoryGrowthListView`; Retry on failed
- [ ] Non-zero parent + zero rows = contradiction state, not empty state
- [ ] Instrument every empty-under-nonzero to diagnostics

## Phase 3 — refresh means refresh (D5)
- [ ] Promote `checkGrowth()` to real rescan, or remove the button for explicit "Rescan now"
- [ ] One freshness element naming what is stale; delete the footer priority chain
- [ ] Staleness policy (age + pending volume), not a binary
- [ ] Drop "Changes pending"

## Phase 4 — collapse clocks
- [ ] Sample statfs at panel-open
- [ ] Unify all but free space + baseline delta to "as of last scan"
- [ ] Section-level provenance only (no per-row labels)

## Phase 5 — honest accounting gap (D6)
- [ ] Remove the `max(0, ...)` clamp
- [ ] Signed gap with named buckets; never the word "reconciled"

## Phase 6 — named contributors
- [ ] Precompute/hydrate contributors before surfacing in overview
- [ ] Signed named list replaces the rate
- [ ] Per-contributor dismiss/ignore, persisted + visible in Settings

## Phase 7 — cleanup (D7)
- [ ] Delete dead `GrowthBarView.swift` / `SizeBarView.swift`
- [ ] Remove unused rate/trend plumbing
- [ ] Purge "recent" / "just now" timing strings

## Phase 8 — cleaning (gated on zero empty-under-nonzero events over N weeks)
- [ ] Live path revalidation at action time (existence, size, mtime, permissions, scope)
- [ ] Recoverability stated (Trash vs. permanent); abort loudly on mismatch

# Todo: Critical audit fixes — 2026-08-21

- [x] Split subcategory and growth-contributor cache generations (CACHE-01).
- [x] Retain the panel hosting view across hide/show (CACHE-02).
- [x] Make path-ID lookup case-insensitive across NOCASE storage (SCAN-02).
- [x] Add bounded producer backpressure to full scans (SCAN-01).
- [x] Keep feedback failures actionable with an email fallback (FB-01 residual).
- [x] Add focused regressions and run build/tests plus the live feedback probe.

## Review

Implemented CACHE-01/02, SCAN-01/02, and FB-01 residual from `docs/prunr-depth-audit.md`.
- `make test`: **101 tests, 0 failures**
- Feedback probe: `POST /api/feedback` with `{}` → **401** `{"error":"Unauthorized."}` (live; not 404)
- Manual still needed: panel close/open (CACHE-02 idle CPU / state retention), drilldown under FSEvents churn (CACHE-01)

# Todo: Growth UX Redesign

## Scan hardening review fixes — 2026-08-21

- [x] B: Continue past transient ENOENT/ESTALE FTS errors; abort on permission/systematic errors.
- [x] A: 15-minute abandoned-scan grace; idle-gated startup cleanup; refuse compact while busy; markSnapshotComplete rowcount check.
- [x] E: Include `isReconciling` and `isInventoryRefreshInProgress` in busy gates.
- [x] C: FileHandle append with rotation only over the diagnostics log cap.
- [x] Minors: explicit Settings notice error state; tilde path redaction; store `scopePathCount`.
- [x] Add/update regressions for fresh/stale scanning cleanup, vanished snapshot publish, FTS policy, tilde redaction.
- [ ] D: Release decision only — respin alpha.11 vs avoid sysdiagnose requests (no code change).

### Review

Implemented findings B/A/E/C plus the listed minors from
`docs/scan-hardening-review-2026-08-21.md`. Finding D remains a release process
decision. `make test` → **91 tests, 0 failures**.

## Cache drilldown batching — 2026-08-20

- [x] Make Google Chrome and browser variants resolve native icons reliably.
- [x] Render no more than 10 cache-owner rows at a time.
- [x] Keep the existing “Show more” progressive disclosure affordance.
- [x] Add coverage for Chrome variant naming.

### Review

Cache-owner rows now use the shared `ExpandableList` with a chunk size of 10,
so scrolling does not instantiate every application row and icon at once.
Chrome, Chrome Canary/Beta/Dev, Firefox, and Safari also have explicit app-path
fallbacks if Launch Services has not refreshed yet.

## Cache application icons — 2026-08-20

- [x] Resolve cache owners to installed app bundles through Launch Services.
- [x] Render native app icons in cache drilldown rows with a generic fallback.
- [x] Expand friendly names for common browser, developer, media, and utility apps.
- [x] Add regression coverage for common cache-owner names.

### Review

Cache drilldown rows now load each owner’s native macOS bundle icon via
`NSWorkspace`, including aliases for helper/WebKit cache owners. Unknown or
uninstalled owners retain the existing SF Symbol fallback.

## Drilldown and Liquid Glass polish — 2026-08-20

- [x] Keep drilldown navigation responsive while uncached details load.
- [x] Group cache drilldown entries by owning application.
- [x] Let the existing Liquid Glass panel show through inner surfaces while
      keeping the macOS 14 fallback intact.
- [x] Run focused regressions, full tests, and a build.

### Review

- Uncached category clicks now enter the drilldown immediately and show the
  existing loading skeleton while database work continues; the same behavior
  applies to drive-bar navigation.
- Cache drilldown groups are derived from `Library/Caches` ownership paths and
  show friendly names such as Safari and Google Chrome. Pagination, growth
  totals, and growth contributors retain the application key.
- The panel already uses `NSGlassEffectView` on macOS 26; inner onboarding and
  scan cards are now translucent instead of flattening the glass. macOS 14
  fallback behavior remains unchanged.
- `make test` passed: 86 tests, 0 failures. `make build` passed.

## Critical pre-alpha sync fixes — 2026-08-20

- [x] Preserve onboarding when a first scan is cancelled or fails.
- [x] Keep dirty filesystem signals pending across active scans and cooldowns.
- [x] Make snapshot publication explicit and ignore/delete incomplete snapshots.
- [x] Fail authoritative scans on unreadable traversal errors.
- [x] Run focused regressions, full tests, and a build.

### Review

Implemented only the highest-risk data-integrity fixes from the pre-alpha review.
Scope-edit staging, baseline-anchor persistence, reset serialization, feedback
deployment, and release-E2E gating remain separate follow-ups.

## Pre-alpha sync and UX review — 2026-08-19

- [x] Map the sync pipeline end to end: filesystem events, reconciliation,
      scans, database writes, baseline/growth aggregation, and UI publication.
- [x] Audit concurrency, cancellation, retry/backoff, persistence, permissions,
      and lifecycle edge cases.
- [x] Trace every user-visible state and transition, including first run,
      baseline, healthy/stale/error, settings changes, reset, and update states.
- [x] Review motion, timing, reduced-motion behavior, interaction affordances,
      accessibility, and menu-bar lifecycle behavior.
- [x] Run focused regression tests plus the available end-to-end/runtime checks.
- [x] Record severity-ranked findings, release blockers, residual risks, and a
      concrete pre-alpha recommendation.

### Review

- Verdict: no-go for the next external alpha until the P1 findings in
  `docs/pre-alpha-sync-ux-review-2026-08-19.md` are resolved.
- `make test`: 83 tests, 0 failures.
- Headless E2E: 10/10 phases at 5,000 files and 10/10 at 50,000 files.
- Live in-app feedback endpoint: reachable at `https://prunr-web.vercel.app/api/feedback`
  (401 Unauthorized without a valid token — not a 404).
- Runtime E2E was not executed because it deletes the user's app state and its
  watcher miss is currently non-fatal; both limitations are release findings.
- Automated live-panel/animation capture remains blocked by macOS Accessibility
  permissions. Static UI/state/motion review is complete.

## Settings simplification — 2026-08-19

- [x] Remove the broken Scan Rules surface and simplify General to app preferences.
- [x] Replace common-path groups with one coverage-aware, ranked expandable list.
- [x] Build and test the settings window changes.
- [ ] Manually verify the settings window in the launched app.

### Review

- `make build` passed.
- `make test` passed: 83 tests, 0 failures.
- `make run` built, installed, and launched `/Applications/Prunr.app`.
- Automated visual capture is blocked by local macOS screen-access permissions;
  the settings flow still needs a brief manual check in the launched app.

## Alpha feedback funnel — 2026-08-19

- [x] Implement scan failure backoff and concurrency protection (s1–s2)
- [x] Redact and bound diagnostics; add scan-health summary (s3–s5)
- [x] Add and verify the Brevo feedback endpoint (s6)
- [x] Add and verify the in-app feedback flow (s7)
- [x] Run build/tests and document results; do not publish alpha.10 (s8 deferred)

### Review

- `make test` passed: 81 tests, 0 failures.
- `make run` built, installed, and launched the Debug app.
- Endpoint relay was tested with a mocked Brevo API. Deployment and live-email
  verification remain part of the intentionally deferred release slice.

Goal: make the delta-tracker mental model legible. Growth = total accumulation
since a dated baseline anchor, reset on the user's terms, with a footer that is
quiet when healthy and loud when broken.

## Background (why)

- Per-category growth is currently the *single best contiguous burst within 24h*
  (`GrowthJournalService.buildStories`), gated by `recentStoryWindow = 24h`.
  Older or spread-out growth never shows → looks "Stable" when it isn't.
- The journal is cleared on Accept (`BaselineService.acceptGrowth` → line 75), so
  every retained bucket already means "growth since last accept". The 24h window
  and best-segment scoring are legacy restrictions fighting that fact.
- The baseline (reference point) is invisible, so "+X GB" has no "since when"
  anchor. "Dismiss" reads as throw-away, not "set new baseline".
- Footer shows a relative timestamp that looks identical whether the engine is
  alive or dead — the exact reason the root-scope tester saw "stable" not "broken".

## Phase 1 — Growth = total since baseline (drop 24h window)

- [ ] `GrowthJournalService.buildStories`: replace best-segment selection with a
      per-category **sum of all positive bucket deltas** over the retained journal.
      - story.deltaBytes = Σ positive deltas
      - story.startedAt = earliest positive bucket, endedAt = latest
      - keep the 1 MB (`recentStoryThresholdBytes`) floor on the total
      - delete `recentStoryWindow` and the `recentSegments` filter (line 106)
      - `score()` / segment plumbing no longer needed for selection; keep
        `buildSegments` only if still used for span, else remove
- [ ] Verify partition (`growingCategories`/`stableCategories`) still keys off
      `recentGrowthStory != nil` — no change needed, behavior now = "any growth
      since baseline" instead of "burst in last 24h".
- [ ] Drop the per-category duration label: `CategoryGrowthListView` line 910
      `+X · <displayLabel>` → just `+X`. The baseline "since <date>" in the top
      bar is the single time anchor for all categories.

## Phase 2 — Surface the dated baseline + relabel Reset (top bar)

- [ ] Thread a baseline date through `InventoryAggregationResult`:
      add `baselineSnapshotDate: Date?`, computed in
      `BaselineService.getInventoryWithTrends(trackedPaths:)` as the **earliest**
      baseline-snapshot `createdAt` across enabled paths.
- [ ] Store it on `MenuBarManager` (set where `latestSnapshotDate` /
      `baselineSnapshotIdsByPath` are consumed); expose `growthBaselineDate: Date?`.
- [ ] `MenuBarView.overviewHeader` (growth > 0 branch):
      `↑ +X GB · since <date>`  + button relabeled **Reset** / **Resetting**.
      - date format: "today" if same calendar day, else short "Jun 1"
      - update `.help(...)` text to match "Reset" wording
- [ ] Keep the "Set as New Baseline!" flash and the "Stable" pill as-is.

## Phase 3 — Footer = health line (quiet when healthy, loud when broken)

- [ ] Add a `growthTrackingHealth` computed state on `MenuBarManager`:
      - `.refreshing`  (isBackgroundFullScanRunning)
      - `.changesPending` (pendingDirtyReason/hasPendingRecentChanges)
      - `.notTracking` — no realtime watcher AND reconciliation gated off
        (the root-scope broken case)
      - `.healthy`
- [ ] `MenuBarView.footerStatusText`: drive off `growthTrackingHealth`.
      - healthy → quiet (no timestamp; subtle/empty)
      - notTracking → `Not watching — needs Full Disk Access` (actionable)
      - keep update-available + refreshing + changes-pending branches
      - drop the always-on "Updated X ago" / "No changes detected" timestamp

## Out of scope here (separate decision)

- Re-enabling realtime/periodic growth for root `/` scope
  (`shouldAutoWatchTrackedPath` exclusion + `isPermissionConfirmedForProtectedTraversal`
  gates on reconciliation). Phase 3's `.notTracking` footer makes the broken state
  visible; the actual re-enable is a follow-up with its own CPU/permission tradeoff.

## Verification

- [ ] `make build`
- [ ] `make test`
- [ ] Manual: grow a tracked folder over >24h span → top bar shows cumulative
      total + "since <date>"; Reset clears it and re-anchors the date to today.

## Review

Implemented all three phases. `make build` ✓, `make test` ✓ (67 tests).

- **Phase 1** — `GrowthJournalService.buildStories` now sums all positive journal
  deltas per category (≥1 MB floor) instead of picking the best 24h burst.
  Removed `recentStoryWindow`, `buildSegments`, `score`, `formattedDuration`,
  `GrowthSegment`. Per-category list drops the `· <duration>` suffix.
- **Phase 2** — `InventoryAggregationResult.baselineSnapshotDate` (earliest
  baseline `createdAt` across paths) via new `DatabaseManager.fetchSnapshotCreatedAt`.
  Threaded through `applyInventory(baselineDate:)` → `MenuBarManager.growthBaselineDate`.
  Top bar: `↑ +X · since <date>` + button relabeled **Dismiss → Reset**.
- **Phase 3** — `MenuBarManager.isGrowthTrackingActive` (false only when a
  baseline exists but nothing is watched AND reconciliation is gated off).
  Footer is health-driven: green dot + "Tracking" when healthy, orange
  "Not tracking — needs Full Disk Access" when broken. Dropped the relative
  timestamp entirely; removed unused `relativeTime(from:)`.

### Known minor
- Brief footer flash possible if read between baseline load and watcher
  configuration (watchedPaths momentarily empty). Transient; resolves on next
  reactive update.

### Manual checks
- Grow a tracked folder over a multi-day span → top bar shows cumulative total
  + "since <date>"; Reset re-anchors the date to today and clears growth.
- Set scan path to `/` without Full Disk Access → footer shows
  "Not tracking — needs Full Disk Access" instead of looking stable.
