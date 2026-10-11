# Prunr — state

_Updated: 2026-10-10 18:10 by orchestrator. Live state only, max ~80 lines. History → docs/journal.md, facts → memory, long-term → docs/product-roadmap-2026-09-07.md._

## Direction
Compass: not iced, design mode, alongside Pad/Bounce. Infrastructure is done (notarized DMG, Sparkle, signup). The core screen is unsettled: answer "where did my storage go" at once, without over-detail. Lens to test: growth as a sentence ("Since last week, 14 GB appeared: 9 in Xcode caches…"). No app code until the core screen is settled. Loose end: fix #35 when a morning opens. Parked: website DMG vs App Store, price (~€5.99 one-time).

## Ship target
A stranger downloads the alpha from the website and gets a one-glance answer to "what grew". Done for the current queue: code runs from lab2 with a green Mac test run, and #35 status is known.

## Rulebook
AGENTS.md ## Unattended. Thread-specific limits: app code frozen (Compass lane rule); holiday 2026-10-30 → 11-16, nothing user-visible lands.

## Waiting on Merlin
(none — s10 + s11 running; next: one Debug install with both for review)

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
goal: drop CODE-LIVES-ON-LAB2.md into the Mac checkout; list bulky Mac-only files (tmp/stress-tree 11 GB, .build 2 GB, Releases/dist 250 MB) for Merlin to keep or delete.
acceptance: note in place, list in STATE.md.
validation: none.
do not touch: delete nothing on the Mac.

### Q4 Core-screen design prep [landed] [box]
result: design settled on G3 (day-grouped list of named changes) after 8 rounds; mockups https://claude.ai/artifact/UGa7vWtZTh1LmtKvLEVfMX; PRD docs/core-screen-episodes-prd-2026-10-11.md (9 slices).
goal: one-page brief for Merlin's design session: the "growth as a sentence" lens, 3 concrete core-screen variants, from docs/product-definition-notes-2026-09-06.md and growth-framing-2026-08-21.md.
acceptance: docs/core-screen-brief-<date>.md, on a branch, unlanded (taste stays Merlin's).
validation: none.
do not touch: app code, website.

### Q5 Build core screen per PRD [running] [mac]
goal: v1 slices of docs/core-screen-episodes-prd-2026-10-11.md, one worktree branch per slice. Order {s1, s2a} → {s2b, s5, s6, s7} → s3 → s4 → s9. Drilldown (L0) after v1.
landed: s2a, s5, s6, s7. on branch: s1–s9 (feat/s9-cleanup, installed on Mac, reviewed: too hard to read). running: s10 1 GB rule + day list, s11 real icons (both on top of s9).
followup: feed rebuild ~2.4 s on a worst-case 200k-bucket fixture; accepted for now (off main thread, debounced), re-measure on real alpha data before s9.
acceptance: per slice in the PRD; `make test` green via mac-queue.
validation: mac-queue test Prunr on the slice branch.
do not touch: release/appcast/workflows; nothing user-visible lands without Merlin (holiday 10-30→11-16: nothing lands).
landing: non-UI slices (s1, s2a, s5–s7) land when mac-queue test is green; UI slices (s2b, s3, s4, s9) wait for Merlin.

## Rundown
- Core screen v1 built: all 9 slices green on the Mac (225 tests). Names (s2a, s5–s7) on main; the rest stacked in feat/s9-cleanup.
- Onboarding and manual-scan card kept as before (Merlin).
- Blocked: owner visual review before merging data + UI changes.
- Next: L0 drilldown, L2 real app icons, L3 more names; EpisodeBuilder speed if real data needs it.
