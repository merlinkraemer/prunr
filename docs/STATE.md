# Prunr — state

_Updated: 2026-10-10 18:10 by orchestrator. Live state only, max ~80 lines. History → docs/journal.md, facts → memory, long-term → docs/product-roadmap-2026-09-07.md._

## Direction
Compass: not iced, design mode, alongside Pad/Bounce. Infrastructure is done (notarized DMG, Sparkle, signup). The core screen is unsettled: answer "where did my storage go" at once, without over-detail. Lens to test: growth as a sentence ("Since last week, 14 GB appeared: 9 in Xcode caches…"). No app code until the core screen is settled. Loose end: fix #35 when a morning opens. Parked: website DMG vs App Store, price (~€5.99 one-time).

## Ship target
A stranger downloads the alpha from the website and gets a one-glance answer to "what grew". Done for the current queue: code runs from lab2 with a green Mac test run, and #35 status is known.

## Rulebook
AGENTS.md ## Unattended. Thread-specific limits: app code frozen (Compass lane rule); holiday 2026-10-30 → 11-16, nothing user-visible lands.

## Waiting on Merlin
1. Push 2 unpushed docs commits on main (f616b88 + init; triggers CI only) — rec: push — branch: main
2. Untracked `.agents/skills/ship-alpha/` and `docs/next-weeks-brief-2026-10-03.html` — rec: commit both — branch: main

## Queue

### Q1 Baseline Mac test run from lab2 [running] [mac]
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

### Q4 Core-screen design prep [queued] [box]
goal: one-page brief for Merlin's design session: the "growth as a sentence" lens, 3 concrete core-screen variants, from docs/product-definition-notes-2026-09-06.md and growth-framing-2026-08-21.md.
acceptance: docs/core-screen-brief-<date>.md, on a branch, unlanded (taste stays Merlin's).
validation: none.
do not touch: app code, website.

## Rundown
- Moved from the Mac: main @ f616b88, 4 branches, 2 untracked files, notes, memory. Matches the Mac.
- Website builds on lab2; API tests 5/5. Preview ports 5180 (dev) / 4180 (review).
- Next: Q1 result (Mac test run), then Q2.
