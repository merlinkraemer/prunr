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
5. Close obsolete GitHub issues #29 #32 #34 #18 #11 (+ #26 by design) — rec: yes, I close them with a short note — branch: none
6. Category groups net unrelated places ("Developer +9.9 GB" = +44 up, -34 down) and header vs rows don't reconcile — rec: per-place rows inside groups with up/down split + a "smaller changes" row; mockups first — branch: none
7. [accepted 2026-10-30 per rec] Row captions "found by scan" / "found by scan · since Sun 18 Oct"; names drop generic parents ("game · dev" → "game") — review wording — branch: drain/Q8b-2026-10-30
3. Rows of slowly growing places shift by a day as the 30-day window slides — rec: checkpoint table (schema) — branch: none

## Run
status: running · since 2026-10-30 10:15 · cap 2 workers · autonomy loose (Merlin 10-30: land any green work on local main; never push, no beta/release)
targets: hardening + real-data usefulness. Rows like "folder grew +x" whose drilldown only lists that folder's children must explain what actually grew. Plus perf and test infra.
plan: Q6 → Q7 → Q8 → Q9 (absorbs Q2) → Q10 → Q11 → Q12, then Q3 if the Mac is idle; skip L6, L3, website, pricing
mac-queue from dev: LAB2_HOST=dev (default points at lab2). Mac jobs are batched: workers only `mac-queue add`; drains and ssh mbp run only after Grok relays "Mac open" (Merlin 10-30: laptop travels, not always on)
mac batch pending (on Mac open, in order): run integration job 20261031-032538-...-c3a202fcc-test (drain/integration-2026-10-31 = Q9+Q13+Q8b+Q8a+Q6, pbxproj reconciled) → compile fixes on that branch → per-branch jobs only if needed (single-branch jobs miss new test files in pbxproj) → make snapshots-fetch → Q9 idle soak 2h
data: Merlin's Prunr DB may be copied to dev (scratch, gitignored) for analysis; committed fixtures synthetic only
visuals: headless snapshot PNGs via mac-queue anytime; real-app runs batched under ### Visible Mac batch, run only on Merlin's go via Grok
review: https://dev.tail87069a.ts.net:4181 (snapshot PNGs; placeholder until the first Mac open + make snapshots-fetch)

## Queue

### Q1 Baseline Mac test run [landed] [mac] - green 2026-10-10
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

### Q4 Core-screen design prep [landed] - PRD docs/core-screen-episodes-prd-2026-10-11.md
### Q5 Build core screen per PRD [landed] [mac] - v1 + s10-s31 on main, alpha.23/24
### Q6 Real-data test infra [on branch, Mac check pending] - drain/Q6-2026-10-30 5937574: replay harness, synthetic fixtures, PNG snapshot tests, make replay/snapshots-fetch; snapshot ~/dev/projects/prunr-data/prunr-2026-10-30.db (slim, 444); job 20261030-105825-...-593757471-test pending; uncompiled [mac]
goal: DB snapshot from the Mac to dev, replay harness that rebuilds feed + drilldowns from a snapshot, headless SwiftUI snapshot tests (panel, drilldown) rendered to PNG via mac-queue, published on a static phone review page (ports.tsv row, Tailscale URL in ## Run review:).
acceptance: harness + snapshot tests in `make test`; synthetic fixtures modelled on the real snapshot.

### Q7 Real-data usefulness audit [landed] [box] - docs/real-data-audit-2026-10-30.md: only 6/46 rows explained; place page shows sizes not growth (no per-child deltas stored), 43/46 rows lack time/caption, category groups net unrelated places
### Q8a Drilldown explains growth: L1 detail + row-scoped page [on branch, Mac check pending] [mac] - drain/Q8a-2026-10-30 2125c47; v26 growthJournalDetail (top 20/bucket/place), watcher/scan/file-date writes, span-scoped place page, fallback; job 20261031-023301-...-2125c4726-test
goal: audit fixes 1, 2, 4: record per-child deltas (growthJournalDetail, schema migration) at scan/watcher/file-date write points; place page scoped to the row's time span, children sorted by change, removed children shown; honest fallback for rows without detail.
acceptance: unit tests on fixtures; make test green via mac-queue (Mac batch).
### Q8b Row captions + names [on branch, Mac check pending] [mac] - drain/Q8b-2026-10-30 b924a3f; job 20261030-111313-...-b924a3ff2-test
goal: audit fixes 5, 7: "found by scan" / "since <date>" captions; names without parent "dev" or "<inner> · <outer>".
acceptance: unit tests; make test green via mac-queue (Mac batch).
### Q9 #35 CPU loop + 24h idle test [on branch, Mac check pending] - drain/Q9-2026-10-30 aea951c: loop already fixed since Aug; backoff cap 30min→6h, regression + 30s idle-CPU tests, scripts/idle-cpu-soak.sh; job 20261030-101017-...-9a2d41dff-test pending; 24h soak needs a Mac night [mac]
goal: confirm/fix #35 (absorbs Q2); headless 24h idle CPU run (#31) via mac-queue.
acceptance: finding + fix with test; idle run logs CPU under target.

### Q10 Perf on real data [queued] [mac]
goal: re-measure feed rebuild, scan, drilldown on the real snapshot; fix the worst.
acceptance: before/after numbers in the journal.

### Q11 Old issue triage [landed] [box] - docs/issue-triage-2026-10-30.md: 5 obsolete, 6 real (all UI, small), #26 unclear
### Q13 Watchdog ignores backpressure waits [on branch, Mac check pending] [mac] - drain/Q13-2026-10-31 fcd6c02; consumer waits excluded, separate 900 s consumer guard, 4 tests; job 20261031-023033-...-fcd6c0255-test
goal: Reddit tester 10-31: slow DB writer blocks producer in waitToProduce, 30 s traversal watchdog then aborts a healthy scan as stalled (FileScanner.swift); likely the uncaptured #35 failure. Exclude backpressure waits + delayed-consumer test.
### Q12 Navigation bug bundle #27 #28 #30 #24 [running] [mac]
goal: the four small real issues from Q11's triage on one branch; after Q8 (same views).
acceptance: per issue in docs/issue-triage-2026-10-30.md; make test green via mac-queue.

## Rundown
- 2026-10-30: thread moved lab2 → dev. alpha.24 shipped 10-28 (since-install vs estimated history, first-day preview, allocated-bytes fix); main = origin.
- Website: download counter + Download beta button live (10-27).
- Open: Q2 #35 status [box], Q3 Mac recon [mac]. Holiday to 11-16: nothing user-visible lands.
- Later: L0 drilldown detail, L1, L3 names, L4 cleanup awareness, L5 hover-with-click, checkpoint table.

