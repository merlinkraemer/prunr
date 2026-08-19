# Prunr — Alpha Feedback & Insights Funnel: Brainstorm Brief

**Written:** 2026-08-19 · **For:** a fresh agent kicking off a brainstorm session
**Goal of the session:** design the feedback + insights funnel for a wider alpha/open-beta
push. Not "should we ship" — the distribution side already works. The question is:
*once N strangers are running this, how do I learn where it breaks and what they think,
without hand-holding each one through Terminal?*

---

## 1. What Prunr is

macOS menu-bar app that tracks **disk storage growth over time**. Not a one-shot "what's
big" cleaner (DaisyDisk/GrandPerspective) — it takes periodic snapshots and shows you
*what grew since last week*, with a growth journal and drill-down by category/folder.

- Swift / SwiftUI, actor-based services, GRDB (SQLite) for snapshot storage
- **Not sandboxed** (`com.apple.security.app-sandbox = false`) — needs Full Disk Access
  to traverse the user's home dir. This matters a lot for onboarding friction.
- FSEvents watcher + periodic reconciliation drive incremental refreshes; full rescans on
  escalation
- Direct distribution: notarized DMG, Sparkle auto-update, no App Store
- Current version: **0.1.5-alpha.9 (build 10)**, released 2026-06-06
- Repo: `github.com/merlinkraemer/prunr` — **public**

## 2. What already exists (do not redesign these)

**Distribution pipeline — works, shipped:**
- GitHub Actions release workflow → signed + notarized DMG (with volume icon and window
  layout) and zip
- Sparkle appcast at `https://merlinkraemer.github.io/prunr/appcast.xml` → in-app
  auto-update works
- Landing page + download page: `website/` (static HTML, deployed on Vercel;
  also served from `merlinkraemer.github.io/prunr/`)
- Download page pulls latest release from the GitHub API

**Signup funnel — works, shipped:**
- `website/api/subscribe.js` — Vercel serverless fn
- Email → added to a **Brevo** contact list → transactional welcome email with the alpha
  download link → notification email to `merlinkraemer@gmail.com`
- So: there IS an email list of testers, and a channel to reach them.

**Diagnostics — works, but manual and low-throughput:**
- `Prunr/Extensions/PerfSignpost.swift` → `DiagnosticsReporter`
- Writes a **rolling 30-min window line** to `~/Library/Logs/Prunr/diagnostics.log`
  (FSEvents counts, refresh activity, CPU sampled every 20s via mach `thread_basic_info`,
  scan timings via `Perf.measure` signposts)
- Settings → Troubleshooting → **"Generate Diagnostics Report"** button appends a full
  snapshot and reveals the file in Finder
- The file is dense/structured on purpose — designed to be pasted into Claude, not read
  by a human
- **The tester then has to manually send me that file** (WhatsApp/email). That's the
  bottleneck.

**Hard-won lesson already in `docs/lessons.md` (2026-06-03) — respect it:**
> Telemetry has to reach me *without touching their machine*. `log show` / `log stream`
> instructions were rejected: there's no way to pull logs off an alpha tester's machine
> without hand-holding them through Terminal.

## 3. What does NOT exist

- **Zero analytics.** No PostHog, Sentry, Plausible, Mixpanel, Amplitude, Crashlytics —
  nothing. Confirmed by grep across Swift, JS, HTML, TOML.
- **Zero crash reporting.** Crashes are currently invisible to me.
- **No usage telemetry.** I don't know: how many people installed, how many completed
  onboarding, how many granted Full Disk Access, how many ever saw a second snapshot
  (the entire value prop needs ≥2 snapshots over time), retention, which scopes people
  pick, scan durations in the wild, machine/disk-size distribution.
- **No in-app feedback surface.** No "send feedback" button, no bug-report form, no
  rating prompt. Only the GitHub repo link on the download page.
- **No automatic diagnostics upload.** Fully manual (button → Finder → tester emails it).
- **No install/activation counting.** Sparkle appcast is on GitHub Pages so there are no
  server logs I control; GitHub release asset download counts are the only crude proxy.
- **No structured way to correlate** "tester X reported slow" with "tester X's log file".

## 4. Known state of the product (what testers will actually hit)

**The one real blocker — issue #35, CPU retry loop:**
A tester on alpha.5–9 reported constant 70–100% CPU. Root-caused 2026-06-15, written up
in `docs/cpu-leak-analysis-2026-06-15.md`, **fix not yet implemented**:
- Full scans of a large home dir (2.25M files, ~335s) finish traversal then fail in DB
  finalize with an opaque `code=0` error
- Failure never advances `lastFullScanCompletedAt` → the cooldown gate never closes →
  FSEvents *and* the reconciliation backstop both immediately re-trigger the failing scan
  → 100% CPU indefinitely (observed stuck for 42 hours)
- No failure backoff, no retry budget, no circuit breaker anywhere
- Prescribed fix: exponential backoff + a missing `!isReconciling` guard + richer
  diagnostics counters → ship as alpha.10

**Relevant to the brainstorm:** this is exactly the class of bug the funnel needs to
catch automatically. It burned a real tester's CPU for two days and I only found out
because they told me. Also note: this bug was diagnosed *only* because I could not
reproduce it locally — a Full Disk Access / TCC problem meant a dev-signed debug build
returned 0-file scans and never reached the failing code path. **Some bugs here are only
observable on real user machines.** That's the core argument for real telemetry.

**Other open work:**
- #18 release artifact metadata drift; #34 an old signing failure; #32 categories greyed
  out after initial scan (p2-high, hits first-run impression); #31 a 24h idle baseline
  test; #23–#30 a cluster of drilldown/animation polish issues (p3)
- Beta checklist (#11) is otherwise green: swiftlint clean, 50/50 unit tests, e2e 10/10,
  stress passing, `PrivacyInfo.xcprivacy` present
- Branch protection on `main` was previously blocked on the repo being private — the repo
  is now **public**, so that's unblocked

## 5. Constraints the brainstorm must respect

- **Solo dev.** Whatever gets designed has to be maintainable by one person. No ops-heavy
  stack.
- **Infra:** Vercel (already used for the signup fn), Cloudflare (Wrangler present in the
  repo), GitHub Pages, Brevo for email. Prefer reusing these over adding a new vendor.
- **Privacy is a product value.** This app reads the user's entire filesystem tree.
  Shipping anything that transmits file names or paths would be a betrayal of the premise
  and a trust-killer. Aggregate/anonymous only, and it must be honest in
  `PrivacyInfo.xcprivacy` and a privacy note. Opt-in vs opt-out is a real decision to make
  — not a detail to hand-wave.
- **Not sandboxed + needs Full Disk Access** → onboarding already asks a lot. Any consent
  prompt for telemetry adds a second ask. Sequencing matters.
- **Non-technical testers.** No Terminal, no `log show`, no "run this command". If a step
  needs explaining over WhatsApp, it's already failed.
- **Small N first.** Right now it's a handful of testers from the email list. Design should
  work at N=20 and still work at N=500 without a rewrite.
- **User's global rules:** concise output, no fluff, always lead with a TL;DR. Don't add
  dependencies without discussing first. Simplicity first — minimal code impact.

## 6. Questions worth attacking in the brainstorm

Not a checklist to fill in — the interesting shape of the problem:

1. **Crash + hang visibility.** A hang (the #35 case) is not a crash — no crash report is
   generated. How do I detect "this install has been pegged at 100% CPU for an hour"
   remotely? A heartbeat? A watchdog that self-reports? What's the minimum payload?
2. **Automatic vs. assisted diagnostics upload.** Is there a middle ground between the
   current manual Finder→email dance and full silent telemetry? (e.g. a button that
   uploads and returns a short code the tester pastes to me.)
3. **What are the 5 numbers I'd actually act on?** Resisting the urge to instrument
   everything. Candidates: install→FDA-granted conversion, first-scan success rate,
   scan duration vs. file count, D7 retention (did they ever see a second snapshot?),
   crash/hang rate per install.
4. **Qualitative channel.** Where do opinions land? In-app feedback box → where? Email
   reply-to → Brevo? A Discord/Telegram group? GitHub issues (public repo now, but that's
   a high bar for non-technical users)? Scheduled check-in emails via the existing Brevo
   list?
5. **The activation problem specific to Prunr.** The value only appears on the *second*
   snapshot, days later. A user who installs, scans once, and quits has learned nothing
   about the product. How does the funnel measure and fight that? (This may be the single
   most important insight to instrument.)
6. **Version-aware feedback.** Sparkle auto-updates mean testers drift across versions.
   Any report needs to carry app version + build, OS version, and ideally whether the
   #35 backoff fix is present.
7. **Closing the loop.** When a tester reports something, how do they hear it got fixed?
   Release notes in Sparkle? Brevo blast? This is what keeps a small alpha cohort engaged.

## 7. Sequencing question to resolve

Two orders are defensible, and the session should pick one deliberately:

- **(A) Fix #35 first, ship alpha.10, then build the funnel.** Rationale: don't invite more
  users onto a build with a known CPU meltdown.
- **(B) Build the funnel first, ship it with alpha.10.** Rationale: the funnel is exactly
  what would have caught #35 in hours instead of days, and shipping both at once means the
  wider cohort is observable from day one.

My current lean is (B) with #35 folded into the same release — but the fix and the
diagnostics work are already coupled in `docs/cpu-leak-analysis-2026-06-15.md` (item #3
of that plan *is* enhanced diagnostics), so the two threads may just be one thread.

---

## Key files to read

| Path | What's in it |
|---|---|
| `docs/cpu-leak-analysis-2026-06-15.md` | Full root-cause of #35 + prescribed 3-part fix |
| `docs/lessons.md` | The remote-telemetry lesson (2026-06-03) — read this one |
| `Prunr/Extensions/PerfSignpost.swift` | `DiagnosticsReporter`, rolling window, CPU sampling |
| `Prunr/Views/SettingsView.swift:280` | The "Generate Diagnostics Report" button |
| `website/api/subscribe.js` | Existing Brevo signup funnel |
| `website/download.html` | Download page (pulls latest release from GitHub API) |
| `docs/brevo-welcome-email.md` | Welcome email setup |
| `docs/session/handoff.md` | Last session's state (2026-06-11) |
| `Prunr/PrivacyInfo.xcprivacy` | Current declared privacy posture |
