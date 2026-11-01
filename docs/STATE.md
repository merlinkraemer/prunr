# Prunr — state

_Updated: 2026-10-30 by orchestrator (on dev). Live state only, max ~80 lines. History → docs/journal.md, facts → memory, long-term → docs/product-roadmap-2026-09-07.md._

## Direction
Compass: not iced, design mode, alongside Pad/Bounce. Infrastructure is done (notarized DMG, Sparkle, signup). The core screen is unsettled: answer "where did my storage go" at once, without over-detail. Lens to test: growth as a sentence ("Since last week, 14 GB appeared: 9 in Xcode caches…"). Core screen settled 2026-10-11; build per docs/core-screen-episodes-prd-2026-10-11.md. Loose end: fix #35 when a morning opens. Parked: website DMG vs App Store, price (~€5.99 one-time).

## Ship target
A stranger downloads the alpha from the website and gets a one-glance answer to "what grew". Done for the current queue: code runs from dev with a green Mac test run, and #35 status is known.

## Rulebook
AGENTS.md ## Unattended. Thread-specific limits: holiday 2026-10-30 → 11-16, nothing user-visible lands.

## Waiting on Merlin
1. Tester feedback on alpha.24: 1 item since 10-28, positive (found a 25 GB app install via the change list); no bugs reported — rec: recheck weekly — branch: none
4. Background reconciliation + watcher pre-arm still gated on Full Disk Access; access loss after a scan would show skipped folders as a big shrink — rec: decide after beta feedback — branch: none
5. Close obsolete GitHub issues #29 #32 #34 #18 #11 (+ #26 by design) — rec: yes, I close them with a short note — branch: none
6. [accepted 2026-10-31 per rec: variant A, building as Q16 on drain/Q16-2026-10-31] Category groups net unrelated places ("Developer +9.9 GB" = +44 up, -34 down) and header vs rows don't reconcile — rec: per-place rows inside groups with up/down split + a "smaller changes" row; mockups first — branch: none
7. [accepted 2026-10-30 per rec] Row captions "found by scan" / "found by scan · since Sun 18 Oct"; names drop generic parents ("game · dev" → "game") — review wording — branch: drain/Q8b-2026-10-30
3. [accepted 2026-10-31 per rec] Rows drift as the 30-day window slides (root cause + design: docs/checkpoint-table-design-2026-10-31.md): v27 growthJournalCheckpoint, show real "building since" date, expire quiet counts after 90 days — building as Q18


## Run
status: running (Mac open 11-01 headless only; working own priorities O1-O8) · since 2026-10-30 10:15 · cap 2 workers · autonomy loose (Merlin 10-30: land any green work on local main; never push, no beta/release)
targets: hardening + real-data usefulness. Rows like "folder grew +x" whose drilldown only lists that folder's children must explain what actually grew. Plus perf and test infra.
plan: Q6 → Q7 → Q8 → Q9 (absorbs Q2) → Q10 → Q11 → Q12, then Q3 if the Mac is idle; skip L6, L3, website, pricing
mac-queue from dev: LAB2_HOST=dev (default points at lab2). Mac jobs are batched: workers only `mac-queue add`; drains and ssh mbp run only after Grok relays "Mac open" (Merlin 10-30: laptop travels, not always on)
mac batch pending (on Mac open, in order): run the integration job 20261031-161437-...-ce9885791-test on ce98857 (d3f2a98 job superseded) (drain/integration-2026-10-31 = Q9+Q13+Q8b+Q8a+Q6+Q12+Q10; older integration jobs superseded) on an idle Mac (perf tests) → compile fixes on that branch → per-branch jobs only if needed (single-branch jobs miss new test files in pbxproj) → then Q16 job d814a88 and Q18 job 8f77404 (stacked on integration) → make snapshots-fetch → Q9 idle soak 2h (runs a real Prunr instance with a menu bar icon: hold until Merlin's visible go tonight, PM 11-01 12:21)
data: Merlin's Prunr DB may be copied to dev (scratch, gitignored) for analysis; committed fixtures synthetic only
visuals: headless snapshot PNGs via mac-queue anytime; real-app runs batched under ### Visible Mac batch, run only on Merlin's go via Grok
review: https://dev.tail87069a.ts.net:4181 (snapshot PNGs; placeholder until the first Mac open + make snapshots-fetch)

## Run review
Checked 2026-11-01 12:30 WITA over Tailscale (valid TLS, 200, real content):
- https://dev.tail87069a.ts.net:4181/mockups/category-groups.html - category groups mockups A/B/C (Q15; A is built on branch Q16)
- https://dev.tail87069a.ts.net:4181/ - index; app snapshot PNGs appear here after the Mac test run + make snapshots-fetch (not yet)

## Queue
Done: Q1 baseline · Q2 #35 status (absorbed by Q9, docs/issue-35-status-2026-10-30.md on main) · Q4 PRD · Q5 core screen · Q7 audit (docs/real-data-audit-2026-10-30.md) · Q11 triage (docs/issue-triage-2026-10-30.md)

On branch, Mac check pending (all merged into drain/integration-2026-10-31 ce98857, uncompiled):
- Q6 real-data test infra - drain/Q6-2026-10-30 5937574: replay harness, fixtures, PNG snapshots, make replay/snapshots-fetch
- Q8a drilldown explains growth - drain/Q8a-2026-10-30 2125c47: v26 growthJournalDetail, span-scoped place page, fallback
- Q8b captions + names - drain/Q8b-2026-10-30 b924a3f
- Q9 #35 backoff cap 6h + idle CPU tests - drain/Q9-2026-10-30 aea951c; 2h soak on Mac open
- Q10 perf - drain/Q10-2026-10-31 655d108: place page 344→~12 ms, PerfBaselineTests
- Q12 nav bugs #27 #28 #30 #24 - drain/Q12-2026-10-31 1dd6672
- Q13 watchdog ignores backpressure waits - drain/Q13-2026-10-31 fcd6c02 (Reddit tester 10-31)

### Q3 Mac copy recon [done 11-01] [mac] - CODE-LIVES-ON-DEV.md in the Mac checkout (stale at f616b88); bulky: tmp/stress-tree 11 GB, .build 2.1 GB, tmp/stress-results 176 MB (regenerable, delete is Merlin's call); Releases/dist already gone

### Q14 Static compile review of integration [done] [box] - 1 compile error fixed (ce98857); doubts: Q12 Task captures in withAnimation completion, String(format:%@), PanelSnapshot drawing closure (warnings at worst in Swift 5 mode), exact-string test expectations
goal: read the integration diff vs main for likely compile errors (Swift 6 / Xcode 16.4 Sendable, missing pbxproj entries, signature drift between merged branches) and fix them on drain/integration-2026-10-31, so the first Mac window spends less time on compile fixes.
acceptance: fixes committed, list of remaining doubts in the report. validation: Mac job on Mac open.

### Q15 Category groups mockups [done, review] [box] - https://dev.tail87069a.ts.net:4181/mockups/category-groups.html, 3 variants, rec A (up/down split line under group header)
goal: Waiting item 6 rec: per-place rows inside groups with up/down split + "smaller changes" row, header reconciles with rows. HTML mockups from real snapshot numbers on the review page :4181. Nothing lands in the app.

### Q16 Category groups variant A [on branch, Mac check pending] [mac] - drain/Q16-2026-10-31 d814a88, job 20261031-172802-...-d814a88dc-test; split line on group row, size-sorted rows with arrows on group page (no inline expansion), smaller-changes row; review: split line hyphen vs U+2212 in amounts
goal: Q15 variant A in the panel (up/down split line, per-place rows, "smaller changes" row reconciling with header), tested grouping logic; branch drain/Q16-2026-10-31 off integration ce98857; unlanded (UI, holiday).
### Q17 Checkpoint table design [landed] [box] - docs/checkpoint-table-design-2026-10-31.md on main; drift visible from ~14 Nov on real data
### Q18 Checkpoint table build [on branch, Mac check pending] [mac] - drain/Q18-2026-10-31 8f77404 (on Q16), job 20261031-193012-...-8f77404fb-test; replay.py on real data: 81 row shifts in 16 places -> 0; doubts: first prune after upgrade folds whole journal (unmeasured), midnight-spanning run splits

### Own priorities (holiday queue, Merlin 11-01: no reviews, keep working until he says stop; work top down, refill when empty)
- O1 Mac results: fix compile/test failures on integration, then Q16, Q18; land green non-UI work on local main [mac, now]
- O3 Tester feedback check [done 11-01: 1 positive item, no bugs; Vercel CLI now logged in on dev; recheck weekly]
- O4 Q18 follow-ups [done] Q18 branch ea0304b: harness uses carries, run across cutoff held whole (no day split), first-prune perf test; 17 py tests pass; job 20261101-050228-...-ea0304bf7-test; doubt: always-active place never prunes
- O5 replay drift tests [done] drain/Q18-2026-10-31 8a32284: make audit-test, 14 pass on dev; real data 81 shifts -> 0
- O6 #23 outgoing pane live reads, then #25 onboarding onto PushPager (after integration compiles) [mac]
- O7 Test gap audit [landed: docs/test-gap-audit-2026-11-01.md]; O7b 8 tests for top 5 gaps [on branch] drain/O7b-2026-11-01 66171c8, job 20261101-050252-...-66171c8c7-test; O7c 12 tests gaps 6-10 [on branch] 24eba7c, job 20261101-050622-...-24eba7cab-test
- O9 DiskSpaceService returns 0 free/0 total on missing folder or read error, panel can show "Zero KB free"; make it optional/throw and handle at call sites [box -> mac]
- O8 Perf: scan + feed rebuild on the real snapshot via PerfBaselineTests, fix the worst [mac]

## Rundown
- 2026-10-30: moved lab2 → dev; alpha.24 live since 10-28.
- 10-31: Q6-Q13 coded on one integration branch, waiting for Mac open; headless work continues (Q14, Q15).
