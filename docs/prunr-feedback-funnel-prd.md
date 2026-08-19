# PRD — Prunr Alpha Feedback & Insights Funnel

**Version:** 0.1 · **Date:** 2026-08-19 · **Target release:** 0.1.5-alpha.10
**Audience:** implementing agent. This document is intentionally zoomed out — it fixes
decisions and boundaries, not implementation. Codebase specifics (exact file paths,
service wiring, actor boundaries) are the agent's to determine.

---

## TL;DR

Two tiers of feedback, one backend endpoint.

1. **Heartbeat** — tiny anonymous periodic ping. Always-on once consented. Gives install
   count, activation, retention, version spread, and stuck-scan detection.
2. **Diagnostics upload** — the existing diagnostics blob, uploaded on an explicit button
   press, returning a short human-readable code the tester pastes to Merlin.

Ship the heartbeat together with the #35 CPU fix in alpha.10. Everything else is
alpha.11.

---

## 1. Problem

Prunr has a working distribution pipeline and an email list of testers, but zero
visibility into what happens after install. Issue #35 (full-scan failure → infinite retry
→ 100% CPU for 42 hours on a tester's machine) was discovered only because the tester
said something, and could not be reproduced locally because a TCC/Full Disk Access
difference meant dev builds never reached the failing code path.

**Some bugs in this product are only observable on real user machines.** Widening the
alpha without remote visibility means shipping blind.

## 2. Goals

- Detect hung/failing installs remotely, without the user doing anything.
- Measure the five numbers that would change a decision (§7).
- Give testers a one-click way to send full diagnostics — no Terminal, no Finder, no
  attachments.
- Give testers a low-effort way to send an opinion.
- Preserve the product's privacy premise absolutely.

## 3. Non-goals

- Not a general analytics platform. No PostHog / Sentry / Mixpanel / Amplitude.
- No session recording, no funnels-as-a-service, no dashboards beyond a SQL query.
- No Discord or community infrastructure. At N=20 the qualitative channel is Merlin
  talking to people directly.
- Not redesigning distribution, Sparkle, the website, or the Brevo signup flow. Those
  work.
- Not rewriting `DiagnosticsReporter`. It already produces the right artifact; only its
  delivery changes.

## 4. Decisions already made — do not relitigate

| Decision | Value |
|---|---|
| Sequencing | Funnel and #35 fix ship together as alpha.10 |
| Architecture | Two tiers: small always-on heartbeat + explicit-action diagnostics upload |
| Hang detection | By **failure-state counters**, not by CPU measurement |
| Error reporting | Enum case + numeric code only. **Never** raw error strings |
| Consent | Opt-in, requested **after** first successful scan — never alongside the FDA prompt |
| Qualitative channel | In-app box + Brevo reply-to. No Discord, no reliance on GitHub issues |

**One decision still open — confirm before implementing:** where the endpoint lives.
Default assumption in this PRD is a **Cloudflare Worker + D1**, because Wrangler is
already in the repo, D1 is SQLite (same mental model as GRDB), and the free tier covers
N=500. The alternative is another Vercel serverless function next to the existing
`subscribe.js`, which keeps one vendor but still requires choosing a datastore. Agent
must not add any other vendor or dependency without asking.

## 5. Architecture

### 5.1 Tier 1 — Heartbeat

A periodic outbound POST from the app carrying a small anonymous payload.

**Install identity:** a randomly generated UUID created on first launch and persisted
locally. **Never derive it from hardware, serial number, MAC address, or account.** It
identifies an install, not a person or a machine.

**Cadence:** roughly daily, plus one on app launch. Fire-and-forget: failures are
silent, never retried aggressively, never block the UI, never surfaced to the user. If
the network is down, drop it — this is not accounting data.

**Payload contents (aggregate only):**

- install UUID, app version + build, macOS version
- consent flag / schema version of the payload itself
- Full Disk Access granted (bool)
- snapshot count, days since install
- last scan: outcome (enum), duration, file count **bucketed** (log scale — not exact),
  disk capacity **bucketed**
- `consecutiveFailedFullScans`, `secondsSinceLastCompletedScan`
- last error: enum case + numeric code

**Deliberately excluded:** file names, paths, folder names, category labels derived from
user content, exact file counts, exact disk sizes, hostnames, usernames, IP-derived
geography beyond whatever the edge inevitably sees.

### 5.2 Tier 2 — Diagnostics upload

The existing Settings → Troubleshooting → "Generate Diagnostics Report" button becomes
**"Send Diagnostics"**:

1. Generates the report as it does today.
2. Uploads the blob to the same backend.
3. Displays a short, readable code — e.g. `PRUNR-7F3K` — with a copy button and a line
   telling the tester to send that code to Merlin.
4. Keeps a "Reveal in Finder" fallback for when upload fails.

The code is the correlation key: it resolves server-side to install UUID, app version,
OS version, and the uploaded blob. This is what makes "tester X says it's slow" joinable
with "tester X's log".

Because this is a deliberate user action, it carries its own consent and is available
regardless of heartbeat consent state.

### 5.3 Backend

One Worker, minimal surface:

- `POST /heartbeat` — validate, insert row, return 204
- `POST /diagnostics` — accept blob, generate code, store, return code
- `POST /feedback` — free text + auto-attached version/install UUID (alpha.11)
- Read path: **SQL, not a dashboard.** A handful of saved queries is the deliverable.
  Do not build a web UI for this.

Requirements: rate-limit per install UUID, cap payload size, reject unknown schema
versions, no auth (the data is anonymous and low-value; a shared static token to deter
casual noise is acceptable if trivial).

**Retention:** define a deletion policy up front — heartbeats and diagnostics blobs
expire after a fixed window (suggest 90 days). Implement the expiry, don't just document
it.

### 5.4 Consent UI

- Asked **after** the first successful scan completes, not during onboarding. FDA is
  already the heaviest ask in the product; do not stack a second ask on top of it.
- One clear sentence, opt-in, plus a link to a page showing the **literal JSON** that
  gets sent. That page is worth more trust than a privacy policy.
- Revocable in Settings at any time. Revoking stops future sends immediately.
- `PrivacyInfo.xcprivacy` must be updated to reflect reality, and the privacy note on the
  website must match. If the manifest and the payload disagree, the payload is wrong.

## 6. Scope

### alpha.10 — required

1. **#35 fix.** Per `docs/cpu-leak-analysis-2026-06-15.md` — exponential backoff, the
   missing `!isReconciling` guard, richer counters. Not redesigned here. Note that item 3
   of that plan (enhanced diagnostics) and this PRD's counters are the same work; do them
   once.
2. Heartbeat client + consent UI.
3. Backend endpoint + store + retention policy.
4. Saved queries for the five metrics.

That is the minimum that makes a wider cohort observable. **Do not invite additional
testers before this ships.**

### alpha.11 — next

5. Diagnostics upload + code.
6. **Second-snapshot notification** (see §8 — high value, easy to underrate).
7. In-app feedback box.
8. Naming reported fixes in Sparkle release notes so testers see their reports land.

### Explicitly deferred

Issues #18, #23–#30, #31, #32, #34. #32 (categories greyed out after initial scan) hits
first-run impression and is the strongest candidate to pull forward if it turns out to be
small — but it is not a blocker for this work.

## 7. Metrics — the five numbers

Each must be answerable with one query. If a proposed field doesn't feed one of these,
it probably shouldn't be collected.

1. **FDA conversion** — installs that granted Full Disk Access ÷ installs seen.
2. **First-scan success rate**, and scan duration against bucketed file count.
3. **Activation: reached a second snapshot.** The single most important number (§8).
4. **Return rate at D7 / D14** — heartbeats still arriving.
5. **Stuck-install rate** — installs reporting `consecutiveFailedFullScans` above a
   threshold. This is the #35 detector and the acceptance test for the #35 fix.

## 8. The activation problem

Prunr's value only exists on the **second** snapshot, days after install. A user who
installs, scans once, and quits has learned nothing about what the product does. Metric 3
will almost certainly show a large drop-off here — that is predictable today, so ship the
countermeasure in the same cycle rather than waiting for the data to confirm it.

**Countermeasure:** when the second snapshot completes and a meaningful delta exists, fire
a local notification stating the delta in plain language — e.g. *"Your Downloads folder
grew 4.2 GB this week."* This is the product's entire thesis, delivered unprompted, at the
first moment it becomes true.

This is a product feature, not instrumentation, and it is plausibly higher leverage than
everything else in this document.

## 9. Privacy rules — hard constraints

These are not guidelines. Violating any of them breaks the product's premise.

1. **No file names, paths, or folder names leave the machine. Ever.** Including inside
   diagnostics blobs, error payloads, and feedback text metadata.
2. **No raw error strings.** Filesystem and GRDB errors routinely embed the path that
   failed. Transmit an enum case plus numeric code. This is the most likely accidental
   leak in the whole system.
3. Install ID is random, never hardware-derived.
4. Counts and sizes are bucketed, not exact.
5. The published "what we send" page must be generated from, or verified against, the
   actual payload schema — not written by hand and left to drift.
6. If a field's value is ambiguous under these rules, do not send it and raise the
   question.

## 10. Acceptance criteria

- A fresh install appears in the backend within one launch cycle, with correct version
  and OS.
- Declining consent results in **zero** outbound requests from the heartbeat path,
  verified by proxy inspection.
- Revoking consent stops sends immediately.
- A simulated repeated scan failure produces a rising `consecutiveFailedFullScans` visible
  in the backend, and the #35 backoff prevents the CPU pegging that motivated it.
- The Send Diagnostics button returns a code, and that code resolves server-side to the
  matching install and blob.
- Payload inspection across a full session shows no path-like or name-like strings.
- The five queries in §7 return sensible results against real data.

## 11. Open questions for Merlin

1. Cloudflare Worker + D1, or Vercel function + a store? (§4)
2. Heartbeat cadence — daily is the assumption; is that right for a cohort that may leave
   the app running for weeks?
3. Retention window — 90 days assumed.
4. Should the consent prompt offer a "yes, and you can email me about bugs" checkbox that
   links the install UUID to the Brevo contact? Useful for closing the loop, but it turns
   anonymous data into pseudonymous data and deserves a deliberate decision rather than a
   default.

## 12. Scope warning

This document could easily become two months of work. The minimum that unblocks a wider
alpha is **#35 fix + heartbeat + one endpoint**. The purpose of this project is to reach
real user feedback quickly; do not let the feedback system become the reason feedback is
delayed. Ship alpha.10 lean.
