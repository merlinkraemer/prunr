# Alpha Feedback Funnel

**Date:** 2026-08-19
**Status:** draft
**Target release:** 0.1.5-alpha.10

Supersedes `docs/prunr-feedback-funnel-prd.md` (v0.1 draft) and
`docs/alpha-feedback-funnel-brief.md` (brainstorm context). Both scoped a full
telemetry stack; this plan cuts that down to what is worth building before
testers actually exist.

---

## Problem

Prunr has distribution (notarized DMG + Sparkle) and an email list (Brevo), but
zero visibility into what happens after install. Issue #35 — full-scan failure →
infinite retry → 100% CPU for 42 hours on a tester's machine — was discovered
only because the tester said something, and could not be reproduced locally
because a TCC/Full Disk Access difference meant dev builds never reached the
failing code path.

But there are also **no testers yet**, and marketing to get them is unscheduled.
Building aggregate analytics now instruments nothing: "FDA conversion = 3 of 5"
is noise, not a metric, and at N≤10 every aggregate question is answered better
by emailing the list directly.

So the actual problem to solve today is narrower:

1. A bug that will peg a real tester's CPU for days is still in the shipping build.
2. There is no low-friction way for a tester to say "this is annoying" — email is
   1:1 and high-ceremony, so only complaints big enough to justify writing an
   email ever arrive.

## Solution

**Phase 0 — fix #35.** Ships because it is a bug, not because it is funnel work.
Exponential backoff on repeated full-scan failure, the missing concurrency guard
suspected of triggering the `code=0` error, and failure counters surfaced in the
diagnostics log. Per `docs/cpu-leak-analysis-2026-06-15.md`.

**Phase 0.5 — feedback box.** One text field, one optional email field, one
button, reachable from the menu-bar icon. Posts to a new Vercel function that
relays to your inbox via Brevo transactional email — the same pattern
`website/api/subscribe.js` already uses for its notify mail. The existing
diagnostics blob is **always** attached, so an opinion and a bug report are the
same action for the tester.

No datastore, no dashboard, no new vendor. The read path is your inbox, which at
N≤10 beats any SQL query you could write.

Two blockers must clear before diagnostics can be auto-attached — the blob
currently leaks filesystem paths and grows without bound (see s4, s5). Manual
"reveal in Finder" made both tolerable because the tester could inspect the file
first; auto-attach removes that safeguard.

### Decisions locked during planning

| Decision | Value |
|---|---|
| Consent | Opt-out for alpha; disclosed on the download page (already live) |
| Heartbeat / analytics | **Deferred.** Premature below ~10 testers |
| Backend | Vercel function + Brevo email. Cloudflare Worker + D1 was chosen for the heartbeat's datastore needs; no heartbeat, no datastore |
| Discord | No. Pull-based channels only — no standing presence obligation from SEA |
| In-app email capture | No preemptive field. Broadcast to the Brevo list, and the tester creates the join by sending feedback |
| Diagnostics attach | Always on, no checkbox — gated on s4 + s5 |
| Placement | Menu-bar icon → context menu → Troubleshooting → opens Settings with the input box |

## Out of scope

- **Heartbeat, install UUID telemetry, Cloudflare Worker, D1, retention policy,
  the five metrics, second-snapshot notification.** Parked, designed in
  `docs/prunr-feedback-funnel-prd.md` §5.1/§7/§8. Gate: revisit when ~10+ testers
  are actually incoming. It is a one-day build from that document.
- Diagnostics upload with a `PRUNR-7F3K` correlation code. Collapsed into the
  feedback box — attaching the blob to the message *is* the correlation.
- Discord or any community infrastructure.
- PostHog / Sentry / Mixpanel / Amplitude / crash reporting.
- Redesigning distribution, Sparkle, the website, or the Brevo signup flow.
- Rewriting `DiagnosticsReporter`. Only its content (s4) and its size (s5) change.
- Issues #18, #23–#30, #31, #32, #34. #32 (categories greyed out after initial
  scan) hits first-run impression and is the strongest candidate to pull forward
  if it turns out small — not a blocker here.

## Slices

### s1: Full-scan failure backoff
- **outcome:** A persistently failing full scan backs off exponentially instead of
  retrying in a tight loop; CPU stays flat instead of pegging at ~100%.
- **depends_on:** none
- **likely_files:** `Prunr/Services/MenuBarManager.swift` (bug A: `1274–1276`,
  gate `3139–3146`, escalation paths `2953–2956`, `3040–3044`, `3177`; bug B:
  `1454`, `1479–1499` `scheduleReconciliationBackstop`)
- **acceptance:**
  - [ ] `lastFullScanAttemptAt` advances on **every** attempt, success or failure —
        today `lastFullScanCompletedAt` only advances on success, so the cooldown
        gate never closes on persistent failure
  - [ ] `consecutiveFailedFullScans` increments on failure, resets to 0 on success
  - [ ] Backoff 1 → 2 → 4 min, capped at 30 min, keyed on the attempt timestamp
  - [ ] Same treatment for `lastReconciliationAt` so the reconciliation backstop
        cannot compute `delay ≤ 0` and spin
  - [ ] With a forced-failure scan, CPU stays flat and the log shows increasing
        gaps between attempts

### s2: Concurrency guard on recent-change refresh
- **outcome:** An incremental refresh can no longer run concurrently with a
  reconciliation, removing the suspected trigger for the `code=0` finalize error.
- **depends_on:** none
- **likely_files:** `Prunr/Services/MenuBarManager.swift:2934`
  (`performRecentChangeRefresh`), `Prunr/Services/ScanService.swift` (`35`,
  `56–60` shared `isCancelled` / `cancellationToken`; `1029`
  `resetCancellationForNewBatch()`)
- **acceptance:**
  - [ ] `performRecentChangeRefresh` bails when `isReconciling` is true
  - [ ] Cancellation token is scoped per scan, not shared across concurrent scans —
        one scan can no longer clobber another's token
  - [ ] Heavy FSEvents churn during a reconciliation produces no overlapping
        DB write path

### s3: Failure counters in the diagnostics window line
- **outcome:** Every rolling-window line carries scan health, so a stuck install is
  legible from the log alone without needing to ask the tester questions.
- **depends_on:** s1
- **likely_files:** `Prunr/Extensions/PerfSignpost.swift`
  (`windowSummaryLine`, `DiagnosticsAppContext`), `Prunr/Services/MenuBarManager.swift`
- **acceptance:**
  - [ ] Window line includes `scans(success/failed/cancelled)`,
        `consecutiveFailures`, `lastScanError` (enum case + numeric code only),
        `lastFullScan` + `secsSinceLastFullScan`
  - [ ] `lastScanError` is never a raw error string — filesystem and GRDB errors
        routinely embed the failing path
  - [ ] Item 3 of `docs/cpu-leak-analysis-2026-06-15.md` is satisfied by this slice;
        do not implement it twice

### s4: Redact paths from the diagnostics blob
- **outcome:** A generated diagnostics report contains no filesystem paths,
  usernames, or folder names — making it safe to transmit automatically.
- **depends_on:** none
- **likely_files:** `Prunr/Extensions/PerfSignpost.swift:51`
  (`DiagnosticsAppContext.scopePaths`), `:246` (`appendManualSnapshot`),
  `Prunr/Services/MenuBarManager.swift:710` (`generateDiagnosticsReport`)
- **acceptance:**
  - [ ] `scope: paths=[...]` is replaced with counts and flags, e.g.
        `roots=3 defaultScope=true` — today this line writes literal paths such as
        `/Users/jane/Work/Clients/AcmeCorp`
  - [ ] Also audit `blockedLocations` from
        `PermissionsService.ScanScopeAccessReport` — these are path labels; only
        the `isGranted` bool may be transmitted
  - [ ] `grep -E '/Users/|/Volumes/'` over a freshly generated report returns nothing
  - [ ] Optional: bucket `disk: used/total/free` instead of exact byte counts

### s5: Bound the diagnostics log
- **outcome:** `diagnostics.log` stops growing forever, so auto-attaching it can't
  silently fail on exactly the long-lived install whose log matters most.
- **depends_on:** none
- **likely_files:** `Prunr/Extensions/PerfSignpost.swift` (`append`, `logFileURL`)
- **acceptance:**
  - [ ] File is capped (rotate at ~1MB, or attach only the tail ~200KB)
  - [ ] Currently `append()` only ever appends — 57KB after ~5 days of local use,
        unbounded over months
  - [ ] Rotation preserves the most recent window lines, not the oldest
  - [ ] Attached payload has a hard ceiling regardless of file size on disk

### s6: `/api/feedback` endpoint
- **outcome:** A POST to the deployed endpoint lands a formatted feedback email in
  your inbox — verifiable by `curl` before any Swift code exists.
- **depends_on:** none
- **likely_files:** `website/api/feedback.js` (new),
  `website/api/subscribe.js` (pattern: `brevoHeaders`, `senderConfig`, notify mail)
- **acceptance:**
  - [ ] `curl -X POST .../api/feedback` with a JSON body delivers an email
        containing the message, app version, macOS version, install UUID
  - [ ] Diagnostics blob arrives as an attachment when present
  - [ ] Optional reply-to email, when supplied, is set as the mail's reply-to
  - [ ] Payload size cap and a static shared token compiled into the app —
        `ALLOWED_ORIGINS` from `subscribe.js` does not apply, the client is not a browser
  - [ ] Reuses existing Brevo env vars; no new vendor, no new dependency

### s7: In-app feedback sheet
- **outcome:** A tester types a sentence, hits send, and it arrives in your inbox
  with the diagnostics log attached — no mail client, no Terminal, no Finder.
- **depends_on:** s4, s5, s6
- **likely_files:** `Prunr/Views/MenuBarView.swift` (context menu item),
  `Prunr/Views/SettingsView.swift:280,287` (Troubleshooting section, existing
  "Generate Diagnostics Report"), `Prunr/Services/MenuBarManager.swift:710`
- **acceptance:**
  - [ ] Menu-bar icon → context menu → Troubleshooting opens Settings focused on
        the input box
  - [ ] Fields: message text + optional email. No diagnostics checkbox — always attached
  - [ ] Random install UUID generated on first launch and persisted in
        `UserDefaults`; never derived from hardware, serial, MAC, or account
  - [ ] Send is non-blocking; failure shows a clear error and keeps the typed text
  - [ ] "Reveal in Finder" survives as the fallback when the POST fails
  - [ ] End-to-end: type on a clean install → email arrives with a readable,
        path-free attachment

### s8: Ship alpha.10
- **outcome:** A notarized alpha.10 is live on the appcast and existing installs
  auto-update to it.
- **depends_on:** s1, s2, s3, s7
- **likely_files:** `project.yml:42–43`, `Prunr/Info.plist:31–32`,
  release workflow, appcast
- **acceptance:**
  - [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bumped and consistent
        across `project.yml` and `Info.plist`
  - [ ] Notarized DMG + zip published, appcast updated
  - [ ] Clean-install smoke test: onboarding → FDA → first scan → send feedback
  - [ ] Sparkle update from alpha.9 succeeds
  - [ ] Release notes name the #35 fix

## Dependency graph

```
s1 → s3
s2 → (none)
s4 → s7
s5 → s7
s6 → s7
s3 → s8
s7 → s8
```

## Parallel batches

- **Batch 1** (all independent): s1, s2, s4, s5, s6
- **Batch 2** (after Batch 1): s3 (needs s1), s7 (needs s4, s5, s6)
- **Batch 3** (after Batch 2): s8

s6 is JavaScript in `website/`; s1–s5 are Swift in `Prunr/`. No file overlap —
they parallelize cleanly.

## Notes

**Uncommitted work needing a decision.** `Prunr/Services/ScanService.swift:~522`
carries a temporary diagnostic patch that unredacts the `code=0` error. It was
never exercised on a real full scan because TCC blocked local reproduction. It
conflicts with s3's "enum case + numeric code, never raw strings" rule. Either
revert it, or keep it only until one real `code=0` is captured and treat it as
explicitly not-for-release.

**The `code=0` root cause is still unknown.** Ruled out: `EncodingError` (4866),
`CancellationError` (1), GRDB/SQLite codes. The only reachable enum-first-case is
`DatabaseError.directoryNotFound`, thrown solely in `initialize()` and never on
the write path — an unresolved contradiction. s1 and s2 make the *symptom*
survivable (no CPU peg, no infinite loop) without proving the cause. That is the
correct trade: ship the containment, keep hunting.

**Local reproduction is blocked.** Dev-signed Debug builds don't get Full Disk
Access, so traversals return 0 or 167 files and never reach the failing write
phase. Capturing a real `code=0` requires patching a **Release** build that has
FDA. See `docs/session/handoff.md`.

**Cleanup:** `/Applications/Prunr.app.bak` still needs restoring to
`/Applications/Prunr.app`.

**Deferred UI question:** a `?` or feedback affordance inside the main app panel
(not just the menu-bar context menu). Decide during the s7 build session.

**Repo is now public** (`gh repo view` → `isPrivate: false`), which unblocks
branch protection — previously blocked on GitHub Pro for private repos.

**Optional split.** s8 can ship twice if you'd rather not wait: alpha.10 with just
s1–s3 (the #35 fix), then alpha.11 with s7 (the feedback box). Default is one
release containing both.
