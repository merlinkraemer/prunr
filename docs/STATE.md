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
8. [accepted 2026-11-01 per rec, merged into stack] Places changing nonstop for >24h now show one change per day instead of one long change (O13 fix so their history still trims) - rec: accept, the feed math stays identical - branch: drain/O13-2026-11-01
9. Land the UI/schema rest after a hands-on session (Merlin 11-02 via PM: "same for prunr", can't judge from mockups) - plan: docs/hands-on-test-plan-2026-11-02.md (~40 min, real data, 10 steps, DB backup + rollback) - rec: run it at the next Mac session, then land on your ok - branch: drain/hands-on-2026-11-02 f5078cb (stack + O23a-d + O24a-e, all green alone; combined Mac green)
3. [accepted 2026-10-31 per rec] Rows drift as the 30-day window slides (root cause + design: docs/checkpoint-table-design-2026-10-31.md): v27 growthJournalCheckpoint, show real "building since" date, expire quiet counts after 90 days — building as Q18


## Run
status: running (non-UI work landed on local main 7cbb6c8; UI/schema rest green on drain/stack-2026-11-01 14be69a, waits on Merlin item 9) · since 2026-10-30 10:15 · cap 2 workers · autonomy loose (Merlin 10-30: land any green work on local main; never push, no beta/release)
targets: hardening + real-data usefulness. Rows like "folder grew +x" whose drilldown only lists that folder's children must explain what actually grew. Plus perf and test infra.
plan: Q6 → Q7 → Q8 → Q9 (absorbs Q2) → Q10 → Q11 → Q12, then Q3 if the Mac is idle; skip L6, L3, website, pricing
mac-queue from dev: LAB2_HOST=dev (default points at lab2). Mac jobs are batched: workers only `mac-queue add`; drains and ssh mbp run only after Grok relays "Mac open" (Merlin 10-30: laptop travels, not always on)
mac batch pending: Q9 idle soak 2h (visible, real Prunr in menu bar; the 11-01 night go has passed, needs the next Mac night go)
data: Merlin's Prunr DB may be copied to dev (scratch, gitignored) for analysis; committed fixtures synthetic only
visuals: headless snapshot PNGs via mac-queue anytime; real-app runs batched under ### Visible Mac batch, run only on Merlin's go via Grok
review: https://dev.tail87069a.ts.net:4181 (snapshot PNGs; placeholder until the first Mac open + make snapshots-fetch)

## Run review
Checked 2026-11-01 12:30 WITA over Tailscale (valid TLS, 200, real content):
- https://dev.tail87069a.ts.net:4181/mockups/category-groups.html - category groups mockups A/B/C (Q15; A is built on branch Q16)
- https://dev.tail87069a.ts.net:4181/app/ - 36 panel snapshots (fixture, replay, real data) from green stack 14be69a

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

### Own priorities (Merlin 11-02: after the visible Mac batch, no reviews: perf analysis, general app performance, detailed bug/code review, then own prios; holiday queue, Merlin 11-01: no reviews, keep working until he says stop; work top down, refill when empty)
- O1 Mac results [done] stack 14be69a green (12 failures fixed; 1 real bug: cancelled scan cleanup); snapshots on review page /app/
- O3 Tester feedback check [done 11-01: 1 positive item, no bugs; Vercel CLI now logged in on dev; recheck weekly]
- O4 Q18 follow-ups [done] Q18 branch ea0304b: harness uses carries, run across cutoff held whole (no day split), first-prune perf test; 17 py tests pass; job 20261101-050228-...-ea0304bf7-test; doubt: always-active place never prunes
- O5 replay drift tests [done] drain/Q18-2026-10-31 8a32284: make audit-test, 14 pass on dev; real data 81 shifts -> 0
- O6 #23 outgoing Categories pane renders from a snapshot [on stack 85ef096, Mac green; visual check later: drill in/out while index loads, no mid-slide flicker]; #25 onboarding onto PushPager dropped for now (refactor, no user value, triage rec)
- O7 Test gap audit [landed: docs/test-gap-audit-2026-11-01.md]; O7b 8 tests for top 5 gaps [on branch] drain/O7b-2026-11-01 66171c8, job 20261101-050252-...-66171c8c7-test; O7c 12 tests gaps 6-10 [on branch] 24eba7c, job 20261101-050622-...-24eba7cab-test
- O9 DiskSpaceService unknown instead of 0 [on branch] drain/O9-2026-11-01 596ce37, 4 tests, job 20261101-050801-...-596ce3735-test; reconciled on stack branch
- O10 abandoned-snapshot cleanup [done, not a bug] only a crash between markSnapshotComplete and rebuildWorkingSet triggers it (clean rollback); 2 pinning tests on drain/O10-2026-11-01 e48ceb2, job 20261101-051000-...-e48ceb2a9-test
- O11 Remove MainViewModel [dropped] only two tests use it; low value, not worth the churn
- O12 One stacked test branch [on branch] drain/stack-2026-11-01 062ef4c (Q18+O7b+O9+O10+main, no conflicts, O7b disk test now expects nil); now d0064bd (O13 + O14 + O16), job 20261101-083527-...-d0064bd93-test replaces ALL prunr jobs incl. integration; keep worktree agent-a8bb3f4b6954f049e until the job ran
- O13 Always-active place never prunes [on branch, real bug] drain/O13-2026-11-01 d2c0d68: runs cut at 24h so held runs stay small (replay: 2868 rows -> <=768 after 120 days); Swift + py tests (18 pass); merged into stack f6c8a3c
- O14 Static compile review of stack [done] 2 certain errors fixed (implicit self in escaping test closures, one from Q10 so the integration job would have failed; superseded); doubts: 4-month hourly test may be slow
- O15 implicit-self sweep [done] no more cases found (heuristic scan)
- O16 Per-path journal clear wipes every path's checkpoints [real, doc called it rare/acceptable; reachable via Accept growth and adding a 2nd path, loses folded history of other paths] fixed on stack d0064bd (deletes only checkpoints whose keys the path's buckets use; folded-away keys stay until the 90-day expiry)
- O17 Test expectations vs 24h run cap [done] 107+ tests screened, none affected (fixtures use short runs; the hourly test compares against the same builder)
- O18 Test host isolation [on branch] stack 14be69a: SettingsStore uses a throwaway defaults suite + empty temp base path under TestHost; fixture home synthetic again (UnitResolver.defaultHome settable for tests); compact-test workaround removed; job 20261101-214156-...-14be69ab3-test
- O19 Land branch [landed on local main 7cbb6c8, Mac green, not pushed]
- O21 App performance review [done] docs/perf-app-review-2026-11-02.md (eb635d2): top: hidden-popover reloads every 1.5 s while home busy; FSEvents on main queue with per-event string work; unused SUM after scans; AppCatalog scan on main; per-target watcher transactions; redundant indexes (schema, ask)
- O22 Code review [done] docs/code-review-2026-11-02.md (3e678b6): top: Trash residual makes fake "Trash emptied" rows; denied folders (FDA loss) journal huge shrink/growth; watcher lacks scan skip rules (Photos/Mail/iCloud pairs); cleanup can delete every snapshot after 30 idle days; #5 firmlink/XDEV checked on the Mac: not real (same device id)
- O23 Fix top findings from O21/O22 (one branch each, Mac-tested, non-UI land on local main): O23a hidden-popover reload deferral + remove unused SUM [on branch drain/O23a-2026-11-02 183ff1a, Mac green; note Settings window category list may be stale while panel hidden]; O23b FSEvents off main + one watcher transaction [on branch drain/O23b-2026-11-02 1ce72f5, Mac green, burst200 80->59 ms; journal now shares the transaction with point targets]; O23c denied folders carried forward from the previous snapshot + cleanup keeps newest complete snapshot [on branch drain/O23c-2026-11-02 effb77a, Mac green; gap: first scan with access denied has nothing to carry]; O23d shared skip rules (ScanSkipRules) for scan + watcher + app-folder watch fix [on branch drain/O23d-2026-11-02 066bc72 (on O23b), Mac green; touches MenuBarManager, merge with O23a later]
- O24 Next review fixes (one branch each off stack, Mac-tested): O24a #6 watchdog on systemUptime + #9 vanishing root aborts [on branch drain/O24a-2026-11-02 2f698d9, Mac green]; O24b #8 per-path results, partial success skips backoff [on branch drain/O24b-2026-11-02 1b7a139, Mac green]; O24c perf #4 AppCatalog scan detached, shared in-flight task, async catalog(resolving:) [on branch drain/O24c-2026-11-02 c0b3b4a, Mac green; locate() still on main, small]; O24d #10 hard links once: scan counts first link, watcher size/nlink [on branch drain/O24d-2026-11-02 8d957dc (on O24a), Mac green]; O24e #11 publish snapshot last: working set, residual, history before markSnapshotComplete; failure deletes the unpublished snapshot [on branch drain/O24e-2026-11-02 3ef5f56, Mac green; residual and flip not one transaction, a quit between relies on abandoned cleanup]; O26 #7 per-path watcher filter + #12 reset/scope change cancels and waits for in-flight scans, blocks new ones meanwhile [on branch drain/O26-2026-11-02 c26ac8e (on hands-on), Mac green; wait loop has no timeout]; #1 Trash covered by O23d (watcher skips Trash too); O27a #13 noise filter: other apps WAL/WebKit/tmp count again, Prunr dirs still ignored + #15 redaction to end of line [on branch drain/O27a-2026-11-02 93239d8, Mac green; doubt: more watcher churn from browser WAL files]; O27b #14 snapshots ordered by id, abandoned cleanup by id, residual skipped when clock went back [on branch drain/O27b-2026-11-02 bab8ebd, Mac green; that one scan adds no scan-only changes]; perf #1-#5 done (O23a-c, O24c); O28a perf #8 drilldown reload skipped when groups unchanged, assign-if-changed + #9 disk accounting limit 2, comparison snapshots resolved once [on branch drain/O28a-2026-11-02 9499092, Mac job queued; one-read batching skipped; checked: snapshot holds per-group size and count, so only a same-size swap or rename keeps old file rows until the next change]; O28b perf #7 scanner reserves 256 gate slots per hop, progress marked every 0.25 s or 512 entries, PERF scan.traversal.10k [on branch drain/O28b-2026-11-02 768400f, Mac job queued]; left: perf #6 indexes (schema, ask); O28c perf #10 DB open + migrations detached at launch, panel/Settings/Feedback clicks and watcher start gated until open [on branch drain/O28c-2026-11-02 51cad7e, Mac job queued; visible: clicks ignored during a long migration (no spinner), Merlin call before landing]
- O8 Perf [done] docs/perf-baseline-2026-11-02.md (dbfba72): real data fast (feed 30 ms); worst: first prune after upgrade blocks writers ~700 ms; 200k-bucket feed rebuild 2.2 s; scan persistence
- O20 Chunked prune [done, on stack 153f4e7, Mac green] longest writer wait 89 ms (was ~700); one-time first prune total 2.5 s (was 0.7, background, Debug); daily prune is one chunk, unchanged

## Rundown
- 2026-10-30: moved lab2 → dev; alpha.24 live since 10-28.
- 10-31: Q6-Q13 coded on one integration branch, waiting for Mac open; headless work continues (Q14, Q15).
