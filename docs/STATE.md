# Prunr — state

_Updated: 2026-10-30 by orchestrator (on dev). Live state only, max ~80 lines. History → docs/journal.md, facts → memory, long-term → docs/product-roadmap-2026-09-07.md._

## Direction
Compass: not iced, design mode, alongside Pad/Bounce. Infrastructure is done (notarized DMG, Sparkle, signup). The core screen is unsettled: answer "where did my storage go" at once, without over-detail. Lens to test: growth as a sentence ("Since last week, 14 GB appeared: 9 in Xcode caches…"). Core screen settled 2026-10-11; build per docs/core-screen-episodes-prd-2026-10-11.md. Loose end: fix #35 when a morning opens. Parked: website DMG vs App Store, price (~€5.99 one-time).

## Ship target
A stranger downloads the alpha from the website and gets a one-glance answer to "what grew". Done for the current queue: code runs from dev with a green Mac test run, and #35 status is known.

## Rulebook
AGENTS.md ## Unattended. Thread-specific limits: holiday 2026-10-30 → 11-16, nothing user-visible lands.

## Waiting on Merlin
1. Watch tester feedback on alpha.24 (shipped 2026-10-28) — rec: check-feedback in a few days — branch: none
4. Background reconciliation + watcher pre-arm still gated on Full Disk Access; access loss after a scan would show skipped folders as a big shrink — rec: decide after beta feedback — branch: none
3. Rows of slowly growing places shift by a day as the 30-day window slides — rec: checkpoint table (schema) — branch: none

## Run
status: proposed · since 2026-10-30 · cap 2 workers · autonomy loose (Merlin 10-30: land any green work on local main; never push, no beta/release)
targets: hardening + real-data usefulness. Rows like "folder grew +x" whose drilldown only lists that folder's children must explain what actually grew. Plus perf and test infra.
plan: Q6 → Q7 → Q8 → Q9 (absorbs Q2) → Q10 → Q11, then Q3 if the Mac is idle; skip L6, L3, website, pricing
data: Merlin's Prunr DB may be copied to dev (scratch, gitignored) for analysis; committed fixtures synthetic only
visuals: headless snapshot PNGs via mac-queue anytime; real-app runs batched under ### Visible Mac batch, run only on Merlin's go via Grok

## Queue

### Q1 Baseline Mac test run from lab2 [landed] [mac]
result: green 2026-10-10 (xcodegen + make test PASS).
goal: prove the lab2 checkout builds and tests on the Mac via mac-queue.
acceptance: mac-queue job 20261010-100621-prunr-f616b88c4-test green (117+ tests, 0 failures).
validation: `mac-queue show 20261010-100621-prunr-f616b88c4-test`
do not touch: app code.

### Q2 Pin down #35 status [queued] [box]
goal: is #35 (full-scan failure → infinite retry / CPU) fixed in alpha.22 or still open? Read GitHub issue, docs/cpu-leak-analysis-2026-06-15.md, git log.
acceptance: one-paragraph finding in docs/ with the remaining fix (if any) and its size.
validation: none (read-only).
do not touch: app code.

### Q3 Mac copy recon [queued] [mac]
goal: drop CODE-LIVES-ON-DEV.md into the Mac checkout; list bulky Mac-only files (tmp/stress-tree 11 GB, .build 2 GB, Releases/dist 250 MB) for Merlin to keep or delete.
acceptance: note in place, list in STATE.md.
validation: none.
do not touch: delete nothing on the Mac.

### Q4 Core-screen design prep [landed] [box]
result: design settled on G3 (day-grouped list of named changes) after 8 rounds; mockups https://claude.ai/artifact/UGa7vWtZTh1LmtKvLEVfMX; PRD docs/core-screen-episodes-prd-2026-10-11.md (9 slices).
goal: one-page brief for Merlin's design session: the "growth as a sentence" lens, 3 concrete core-screen variants, from docs/product-definition-notes-2026-09-06.md and growth-framing-2026-08-21.md.
acceptance: docs/core-screen-brief-<date>.md, on a branch, unlanded (taste stays Merlin's).
validation: none.
do not touch: app code, website.

### Q5 Build core screen per PRD [landed] [mac]
goal: v1 slices of docs/core-screen-episodes-prd-2026-10-11.md, one worktree branch per slice. Order {s1, s2a} → {s2b, s5, s6, s7} → s3 → s4 → s9. Drilldown (L0) after v1.
landed: s2a, s5, s6, s7. on branch: s1–s9 (feat/s9-cleanup, installed on Mac, reviewed: too hard to read). s10 1 GB rule + s11 real icons green and combined in feat/v1-review (mac-queue PASS 20261011-131629), installed on the Mac.
followup: feed rebuild ~2.4 s on a worst-case 200k-bucket fixture; accepted for now (off main thread, debounced), re-measure on real alpha data before s9.
acceptance: per slice in the PRD; `make test` green via mac-queue.
validation: mac-queue test Prunr on the slice branch.
do not touch: release/appcast/workflows; nothing user-visible lands without Merlin (holiday 10-30→11-16: nothing lands).
landing: non-UI slices (s1, s2a, s5–s7) land when mac-queue test is green; UI slices (s2b, s3, s4, s9) wait for Merlin.

### Q6 Real-data test infra [queued] [mac]
goal: DB snapshot from the Mac to dev, replay harness that rebuilds feed + drilldowns from a snapshot, headless SwiftUI snapshot tests (panel, drilldown) rendered to PNG via mac-queue.
acceptance: harness + snapshot tests in `make test`; synthetic fixtures modelled on the real snapshot.

### Q7 Real-data usefulness audit [queued] [box]
goal: run the harness on Merlin's data, list rows/drilldowns that don't explain growth (e.g. folder +x, drilldown shows only children), with root causes.
acceptance: docs/real-data-audit-<date>.md with cases (anonymised) + fix proposals.

### Q8 Drilldown explains growth [queued] [mac]
goal: fix Q7's top cases: drilldown shows what grew inside (deltas), building toward L0/L1 per the PRD.
acceptance: failing fixture tests from Q7 go green; snapshot PNGs reviewed by a worker.

### Q9 #35 CPU loop + 24h idle test [queued] [mac]
goal: confirm/fix #35 (absorbs Q2); headless 24h idle CPU run (#31) via mac-queue.
acceptance: finding + fix with test; idle run logs CPU under target.

### Q10 Perf on real data [queued] [mac]
goal: re-measure feed rebuild, scan, drilldown on the real snapshot; fix the worst.
acceptance: before/after numbers in the journal.

### Q11 Old issue triage [queued] [box]
goal: #23–#34 against current code: close obsolete, fix small ones, list the rest.
acceptance: list in STATE; closures wait for a gh-capable step (no outward action without Merlin).

## Rundown
- 2026-10-30: thread moved lab2 → dev. alpha.24 shipped 10-28 (since-install vs estimated history, first-day preview, allocated-bytes fix); main = origin.
- Website: download counter + Download beta button live (10-27).
- Open: Q2 #35 status [box], Q3 Mac recon [mac]. Holiday to 11-16: nothing user-visible lands.
- Later: L0 drilldown detail, L1, L3 names, L4 cleanup awareness, L5 hover-with-click, checkpoint table.

