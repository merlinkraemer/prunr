# Prunr — journal

2026-10-10 18:10 orchestrator - init: moved from Mac to lab2 (bundle + notes + memory), rulebook, state, gates; website build + api tests green
2026-10-10 18:10 orchestrator Q1 spawn: mac-queue test Prunr @ f616b88
2026-10-10 18:20 orchestrator - decided: Merlin ok to push main (docs only, CI)
- 2026-10-10 mac-queue f616b88c4 test-Prunr PASS: 10-xcodegen=PASS 20-test-Prunr=PASS
2026-10-11 10:00 orchestrator Q4 landed: 6 core-screen mockups (artifact), rec Ledger + glyph; waiting on Merlin
2026-10-11 11:00 orchestrator Q4 followup: mockups rejected; Fable model (episodes, named places, 30d list + 7d net) in docs/core-screen-communication-model-2026-10-11.md
2026-10-11 12:00 orchestrator Q4 followup: Merlin picked episode list (E1); Fable refined layout (E5) in artifact, review in docs/core-screen-layout-review-2026-10-11.md
2026-10-11 13:30 orchestrator Q4 followup: row layouts C/D/F rejected; Fable G1-G3 (icon+time fused, eyebrow, Finder groups) published; analysis docs/core-screen-row-analysis-2026-10-11.md
2026-10-11 15:00 orchestrator Q4 landed: core screen settled on G3; PRD docs/core-screen-episodes-prd-2026-10-11.md (Opus draft, Fable review applied). Q5 queued, blocked on approval
2026-10-11 15:30 orchestrator Q1 landed: mac-queue test green on main (2026-10-10)
2026-10-11 15:30 orchestrator - decided: Merlin approved PRD, drilldown out of v1 (L0), lifted no-code lane rule; s2 split into s2a (pure names) + s2b
2026-10-11 15:35 orchestrator Q5 spawn: workers s1 (feat/s1-scan-residual) and s2a (feat/s2a-unit-names), worktrees, validation via mac-queue
2026-10-11 16:00 orchestrator Q5 landed: s2a unit names (c46d469, mac-queue PASS 20261011-052455) merged to main
2026-10-11 16:00 orchestrator Q5 blocked: s1 scan residual green (f15e350, mac-queue PASS 20261011-052340) but schema/scan logic = must-ask; branch feat/s1-scan-residual waits for Merlin
2026-10-11 16:20 orchestrator Q5 landed: s7 media names (84bfbd9, mac-queue PASS) merged; followup noted: any '<X> Project' folder reads as Ableton project
2026-10-11 16:30 orchestrator Q5 landed: s6 app/cache names (7533497, mac-queue PASS) merged; orchestrator fixed one stale UnitResolverTests assertion (Widget data -> Widget cache)
2026-10-11 16:50 orchestrator Q5 landed: s5 developer names (8f17bbd) merged after combined test with s6/s7 (mac-queue PASS 20261011-054540)
2026-10-11 17:00 orchestrator Q5 blocked: s2b change feed green (5ccdfeb, mac-queue PASS 20261011-054819, 168 tests); UI → waits for Merlin visual check
2026-10-11 17:00 orchestrator Q5 answered: s2b perf question (2.4 s worst-case rebuild) → accept for now, re-measure on real data before s9
2026-10-11 17:00 orchestrator Q5 spawn: s3 header + categories view, stacked on s2b (feat/s3-header)
2026-10-11 17:30 orchestrator Q5 blocked: s3 header + categories green (afa47ce, mac-queue PASS 20261011-060237, 207 tests); UI → waits for Merlin
2026-10-11 17:30 orchestrator Q5 spawn: s4 adaptive rows/30 days/states, stacked on s3 (feat/s4-feed-states)
2026-10-11 18:00 orchestrator Q5 blocked: s4 adaptive rows/30d/states green (5cc040f, mac-queue PASS 20261011-062635, 223 tests); UI → waits for Merlin
2026-10-11 18:00 orchestrator Q5 followup: s4 left tests writing real UserDefaults, no panel Stop during manual scan, measure line missing → folded into s9 (same scope)
2026-10-11 18:00 orchestrator Q5 spawn: s9 remove old overview + followups, stacked on s4 (feat/s9-cleanup)
2026-10-11 18:10 orchestrator Q5 decided: Merlin keeps onboarding + manual-scan full-screen card as before; s9 restores the card s4 removed (no footer Stop)
2026-10-11 19:00 orchestrator Q5 blocked: s9 cleanup green (b15237e, mac-queue PASS 20261011-071132, 225 tests); full v1 stack in feat/s9-cleanup waits for Merlin review; measure 4.5 s worst case
2026-10-11 19:00 orchestrator - cleanup: removed finished worktrees and merged/agent branches; stacked slice branches kept
- 2026-10-11 mac-queue b15237e8d mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-11 12:10 orchestrator Q5 spawn: Debug build of feat/s9-cleanup installed on the Mac (mac-queue 20261011-120614 PASS) for Merlin's review
2026-10-11 13:30 orchestrator Q5 followup: Merlin review of v1 build: hard to read at a glance; direction = plain chronological day list; Fable proposed one 1 GB rule (docs/core-screen-simple-list-model-2026-10-11.md), mockups S1/S2
2026-10-11 13:45 orchestrator - decided: Merlin picked the 1 GB rule (s10) and real icons now (s11, hybrid app/file icon + category fallback)
2026-10-11 13:50 orchestrator Q5 spawn: s10 one 1 GB rule (feat/s10-one-rule) and s11 real icons (feat/s11-icons), both from feat/s9-cleanup
- 2026-10-11 mac-queue 4432402f1 mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-11 14:10 orchestrator Q5 blocked: s10 (b2bf6e3) + s11 (df67108) merged into feat/v1-review (conflict in EpisodeBuilder resolved, mac-queue PASS 20261011-131629); Debug install PASS 20261011-132233 (2nd attempt, after box reset); waits for Merlin review
2026-10-11 14:30 orchestrator Q5 followup: Merlin review of v1-review build: too heavy, opaque date headers, non-native fade, coloured tiles, heavy header; drop "free of" (menu bar shows it). Icons root cause: only 12/247 journal buckets on his Mac have unit keys (pre-update data) → category icons. Polish mockups V1–V3 spawned.
2026-10-11 15:00 orchestrator Q5 spawn: s12 polish (V1 rows single-line, no tiles, no date band, native bottom edge, header bar + divider + This week row, no free-of), branch feat/s12-polish from feat/v1-review
2026-10-11 15:05 orchestrator Q5 dropped: s12 polish build stopped at Merlin's request (mockups first); partial branch feat/s12-polish (2 commits, untested) parked
2026-10-11 15:10 orchestrator Q5 decided: list is a pure log for v1 (no click/hover); cleanup awareness (gone rows, current size) noted as PRD L4
2026-10-11 15:20 orchestrator Q5 spawn: Merlin approved W2 + icons option 1 (old coloured category glyphs, real app icon where known, no tiles, pure log); worker continues feat/s12-polish, test + Mac install
2026-10-11 15:30 orchestrator Q5 blocked: s12 polish green (57537da, mac-queue PASS 20261011-145703, 234 tests) and installed on the Mac (20261011-150321); waits for Merlin review
2026-10-11 16:00 orchestrator Q5 followup: Merlin review of s12 build: no hover, non-sticky dates, real bottom fade, old-app spacing, max 3 per date + Show all, category-per-day groups with drilldown, header → week by category → subcategories; mockups X1–X4 spawned; hover-with-click noted as L5
2026-10-11 16:30 orchestrator Q5 spawn: Merlin approved X1+X2 (week breakdown dropped; This week row not clickable; bar full-width hover → categories; per-category bar hover on categories view); worker s13 on feat/s13-grouped from feat/s12-polish
2026-10-11 16:45 orchestrator Q5 blocked: s13 grouped list green (01228b3, mac-queue PASS 20261011-154259, 240 tests), installed (20261011-161807); waits for Merlin review
2026-10-11 17:00 orchestrator Q5 followup: smoother bottom fade under footer (70f09c6, mac-queue PASS 20261011-163548), installed (20261011-163953)
2026-10-12 03:55 orchestrator Q5 landed: core screen v1 merged to main (7cd0350; s1–s13 + fade fix), Merlin approved; merged-main Mac test queued 20261012-035415
2026-10-12 04:10 orchestrator - spawn: mockups Y1/Y2 (top number) + settings review (docs/settings-review-2026-10-12.md) and mockups Z1–Z3 incl. hidden Developer tab, published page 'Top number + settings'
- 2026-10-12 mac-queue 7cd03508c test-Prunr PASS: 10-xcodegen=PASS 20-test-Prunr=PASS
2026-10-12 04:30 orchestrator - spawn: s14 settings rework + Developer tab (feat/s14-settings; tab 'Folder' instead of 'Watching', keep Change… + folder name in copy); balance mockups B1–B3 (used storage top right, ↑↓ arrows)
2026-10-12 05:00 orchestrator - spawn: s15 balance header C3 (used of capacity, scroll-linked historic values from snapshots, bar shows historic fill, Now ↑) + ↑/↓ row arrows (feat/s15-balance)
2026-10-12 05:25 orchestrator - landed on Mac: settings (s14) + balance (s15) combined in feat/review-s14-s15 (mac-queue PASS 20261012-050224), Debug install PASS (isolated queue, battery override on Merlin's go); waits for review
2026-10-12 06:00 orchestrator - decided: Merlin approved beta flow F1–F5 (↗/↘ arrows, hover Finder icon replaces amount, categories by size, footer states; idle footer default 'Updated N min ago'); build waits for balance-flag worker
2026-10-12 06:20 orchestrator - landed on branch: balance header behind flag 'balanceHeader' (default off), This week back (656ade9, mac-queue PASS 20261012-052558, 266 tests) → feat/review-s14-s15; spawn s16 beta flow F1–F5 (feat/s16-beta-flow)
2026-10-12 06:45 orchestrator - landed on branch: s16 beta flow (b9452fd, mac-queue PASS 20261012-054608, 272 tests), installed (20261012-055216); skipped footer states: Catching up (no state), Update ready (Sparkle has no download state)
2026-10-12 07:10 orchestrator - decided: groups with 1 place show the place directly, chevron stays and turns into the Finder icon on hover; 2+ places drill down; rows without a path: no chevron/hover. Slow categories drill → read-only review spawned. Build waits for banner-removal worker.
2026-10-12 07:30 orchestrator - review: slow categories drill = top-20 queries scan 4M working-set rows (no sqlite_stat1, planner ignores pc index), ~35 s cold; rec fix A (pc-driven join + PRAGMA optimize + warm only biggest) → docs/slow-category-drilldown-2026-10-12.md
2026-10-12 07:35 orchestrator - spawn: s17 drill perf option A (pc-driven join, PRAGMA optimize after scans/launch, warm largest only) on feat/s17-drill-perf
2026-10-12 08:05 orchestrator - landed on branch: privacy banner removed, footer opens Folder tab (6d4a993, mac-queue PASS 20261012-060156), installed; spawn s18 group rows (1 place inline + Finder on chevron hover, 2+ drill, no-path inert) on feat/s18-group-rows
2026-10-12 08:40 orchestrator - landed on branch: s17 drill perf option A (f68adec, mac-queue PASS 20261012-062626, 278 tests). Real DB already had planner stats: videos 0.20→0.01 s, photos 3.1→2.8 s; remaining cost = disk reads + GROUP BY 1.3 s + growth totals 1.5 s → option B needed for big categories
- 2026-10-12 mac-queue 1f403832a mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-12 09:00 orchestrator - landed on branch: s17 + s18 combined in feat/review-2 (mac-queue PASS 20261012-070928), installed (20261012-071629); waits for review
2026-10-13 orchestrator - review feedback round (6 items, .agent/task.md): +/- back, all-or-none click, no Finder hover, drilldown rebuild (Fable logic, schema OK), bar affordance + scan indicator mockups
2026-10-13 orchestrator - decided: R1 rows (all clickable) + right-click Show in Finder/Copy Path, T1 bar chevron on hover, S2 scan ring, D1–D3 categories drill; Fable fast-drilldown design saved (docs/fast-drilldown-design-2026-10-13.md, schema v23 drilldown index)
2026-10-13 orchestrator - decided: per-row drilldown (category row → places → place contents by size), right-click Show in Finder/Copy Path only on place/content rows, no migration (fresh start, drop legacy code), keep per-app cache groups; spawn s19 drill index (data, schema) on feat/s19-drill-index; UI slice follows
2026-10-13 orchestrator - landed on branch: s19 drill index + fresh start (a4fda7d, mac-queue PASS 20261013-104550, 283 tests; schema v23, subcategorySnapshot dropped, journal cleared, legacy code removed; one-time index build ~2–3 min). Followup: checkpointWalTruncate runs inside a transaction → SQLite refuses (pre-existing bug)
- 2026-10-13 mac-queue 54acf65c8 mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-13 19:40 orchestrator - landed on branch: s20 drill UI (54acf65, mac-queue PASS 20261013-110421, 289 tests), installed (20261013-113132); Merlin's DB + prefs reset (moved to Prunr-backup-20261013-1936) for a fresh onboarding scan
2026-10-14 orchestrator - spawn: day-one research (docs/firstrun-patterns-2026-10-14.md) + mockups P1–P4 firstrun on 'Day one' page
2026-10-14 orchestrator - decided: day one = reconstruction from written-once files (creation≈mtime), This week from same rows, no labels (Q4/Q5); single-line category rows; orange from +5 GB (fixed)
2026-10-14 orchestrator - spawn: s21 history from file dates (written-once files, first baseline only, source 'files', no labels) + orange from 5 GB, on feat/s21-recon
- 2026-10-14 mac-queue 495319256 mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-14 orchestrator - landed on branch: s21 file-date history + orange 5 GB (4953192, mac-queue PASS 20261014-052309, 301 tests), installed (20261014-052958); Merlin's DB + prefs reset again (backup folder Prunr-backup-<date>)
2026-10-14 orchestrator - decided + spawn: onboarding polish (O1 Home/Desktop/Full disk, O2 variant B, O3, O4 pill Stop), s22 on feat/s22-onboarding
- 2026-10-14 mac-queue 077b922e1 mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-14 orchestrator - landed on branch: s22 onboarding (077b922, mac-queue PASS 20261014-062327, 306 tests), installed (20261014-063811), Merlin's data reset again with backup
2026-10-14 orchestrator - decided + spawn: s23 onboarding tweaks (custom folder row white, access icon in step 2 card) + scans skip unreadable folders so 'Not Now' works (feat/s23-onboard-skip)
- 2026-10-14 mac-queue 5c0e2e668 mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-14 orchestrator - landed on branch: s23 onboarding tweaks + scans skip unreadable folders (5c0e2e6, mac-queue PASS 20261014-065346), installed (20261014-070416)
2026-10-14 orchestrator - spawn: s24 drill fixes (place→contents push transition bug; single-place rows / single-subcategory categories skip a level) on feat/s24-drill-fixes
- 2026-10-14 mac-queue 62828ba0b mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-14 orchestrator - landed on branch: s24 drill fixes (62828ba, mac-queue PASS 20261014-101348, 313 tests; root cause: nested if/else page branches with differing transitions → single shownPage + PushTransition), installed
2026-10-14 orchestrator - landed on branch: s25 drill push pager + skipped-level category title (13ae10b, mac-queue PASS 20261014-121708), installed (20261014-122304)
2026-10-14 orchestrator - landed on branch: s26 Show in Finder, solo-place row titles, main list kept alive, Clear history (80debfb, mac-queue PASS 20261014-134551), installed (20261014-134942)
2026-10-15 orchestrator - landed on branch: s27 Finder reveal for hidden iCloud containers + leaf rows open in Finder (f87558c, mac-queue PASS 20261015-060408), installed (20261015-060810); decided: group by app (plan in scratchpad app-grouping-plan.md, Q1–Q5 all rec), mockups next
2026-10-15 orchestrator - decided: build group-by-app per docs/app-grouping-plan-2026-10-15.md (mockups r20 approved, short names A6); spawn O1–O3 logic on feat/s29-owners
2026-10-15 orchestrator - landed on branch: s28 single-item drills open Finder (cf6b842, mac-queue PASS 20261015-061600), installed (20261015-063630)
2026-10-15 orchestrator - landed on branch: s29 owner logic O1–O3 (e010f46, PASS 20261015-070128, 357 tests) + s28 combined as feat/s29-combined (2649cf0, PASS 20261015-070630), installed; v24 migration clears journal
2026-10-15 orchestrator - landed on branch: s30 owner UI O4–O5 (89fbd70, mac-queue PASS 20261015-084728), installed (20261015-085257)
2026-10-15 orchestrator - merged feat/s30-owner-ui into main locally (baa0d96), not pushed; found: unit-test host opens the real DB and locks Merlin's app — fix spawned
2026-10-15 orchestrator - landed on main: fix/test-host-db (7e0d02f, PASS 20261015-091953): test host isolated from real DB/prefs, busy timeout 10s, WAL checkpoint outside transaction
2026-10-15 orchestrator - landed on branch: s31 no indexing page + rebuild 2x faster (fad2914; merged with main 262dadc, PASS 20261015-095954), installed
2026-10-15 orchestrator - merged feat/s31-no-indexing-page into main locally, not pushed
2026-10-15 orchestrator - landed on main: fix/startup-vacuum (2c6319b, PASS 20261015-101233): VACUUM only when ≥18% free; installed main 775be4b
2026-10-17 orchestrator - shipped: 0.1.5-alpha.23 build 24 (Release run 39022946840 green); main pushed (49763ca); logs healthy 2 days
2026-10-21 orchestrator - landed on main: new app screenshots + website hero (reddit-screenshots, website-screenshots, website-mobile-gap a1abd83); pushed (Merlin: go live)
2026-10-21 orchestrator - landed on main + pushed: fix/ci-green (CI green again, run 39577487938); reminder set 10-22 12:00 for more subreddit posts
2026-10-26 orchestrator - social demo GIF/MP4 made (chore/social-gif d22e12f, PASS 20261026-100337, not merged); MIT license pushed; Mac→lab2 ssh mux stale + taskpolicy -b throttling slowed mac-queue checkout (follow-up in lab-infra)
2026-10-27 orchestrator - shipped: download counter (/api/download + /api/download-stats, Vercel prod deployed), download.html routed through it; social-media/ gitignored
2026-10-28 github-actions - shipped: 0.1.5-alpha.24 build 25 (26f6d6d; since-install vs estimated history, first-day preview, allocated-bytes fix); journaled late on 10-30
2026-10-30 orchestrator - moved: thread lab2 → dev (repo, branches, worktrees, transcripts identical); box refs in STATE/AGENTS/CLAUDE now dev; lab2 copy to be renamed *.moved-to-dev-2026-10-30
2026-10-30 orchestrator - decided: two-week run plan via Q&A with Merlin (hardening + real-data usefulness, Q6–Q11, loose, land green on local main, no push/release); ## Run proposed
2026-10-30 10:15 orchestrator - run-start: holiday queue (PM relayed Merlin: "start all projects on the holiday queue now"); seat subagents, cap 2, loose
2026-10-30 10:15 orchestrator Q6 spawn: real-data test infra + phone review page (sonnet high, seat worktree)
2026-10-30 10:15 orchestrator Q9 spawn: #35 CPU loop finding/fix + 24h idle test (sonnet high, seat worktree)
2026-10-30 orchestrator - decided: Mac jobs batched, drained only after Grok relays "Mac open" (Merlin: laptop travels); workers told; AGENTS rule added
2026-10-30 orchestrator Q9 on branch: drain/Q9-2026-10-30 aea951c; #35 loop fixed since Aug (backoff), cap 30min→6h + tests + soak script; mac-queue job pending (Mac batch); doc docs/issue-35-status-2026-10-30.md
2026-10-30 orchestrator Q11 spawn: old issue triage #23-#34, report only (sonnet medium, seat worktree)
2026-10-30 orchestrator Q6 on branch: drain/Q6-2026-10-30 5937574 replay harness + fixtures + PNG snapshots, uncompiled; slim DB snapshot on dev; review page :4181 (lab-infra ports.tsv a1076d6, local); Mac job pending
2026-10-30 orchestrator Q7 spawn: real-data audit straight from the snapshot DB with sqlite (Mac replay pending) (sonnet high, seat worktree)
2026-10-30 orchestrator Q11 landed on main: issue triage doc (1c6bb30, docs only); Q12 queued for the 4 small nav bugs; issue closes added to Waiting on Merlin (outward)
2026-10-30 orchestrator Q7 landed on main: real-data audit + scripts/audit (0edd755, docs/scripts only)
2026-10-30 orchestrator - decided: L1 growthJournalDetail schema per audit rec (loose run, Merlin: land what you want; reversible migration, on branch until Mac-green)
2026-10-30 orchestrator Q8a spawn: L1 detail + row-scoped place page + fallback (opus medium, seat worktree)
2026-10-30 orchestrator Q8b spawn: row captions + names (sonnet medium, seat worktree)
2026-10-30 orchestrator Q8b on branch: drain/Q8b-2026-10-30 b924a3f scan captions + generic-parent names, uncompiled, job queued; wording in Waiting on Merlin [accepted per rec]
2026-10-31 orchestrator Q8a resumed after usage limit (reset 12:10 UTC)
2026-10-31 orchestrator Q13 spawn: watchdog counts backpressure waits as stall (Reddit tester report, confirmed in FileScanner.swift:148/303) (sonnet medium, seat worktree)
2026-10-31 orchestrator Q13 on branch: drain/Q13-2026-10-31 fcd6c02 watchdog skips backpressure waits + 900 s consumer guard, uncompiled, job queued
2026-10-31 orchestrator Q8a on branch: drain/Q8a-2026-10-30 2125c47 L1 detail table + span page + fallback, uncompiled, job queued
2026-10-31 orchestrator - decided: hold new code until Mac open (Q6/Q8a/Q8b/Q9/Q13 all uncompiled; Q10/Q12 need the Mac or overlap Q8a)
2026-10-31 orchestrator - resumed: PM nudge (don't idle on Mac nights); spawn integration branch drain/integration-2026-10-31 merging Q9/Q13/Q8b/Q8a/Q6 for one Mac job (sonnet medium) + Q12 nav bugs on top of Q8a (sonnet medium)
2026-10-31 orchestrator - integration branch drain/integration-2026-10-31 c3a202f: 5 branches merged clean, 8 test files added to pbxproj, job queued; Mac open runs this first
2026-10-31 orchestrator Q10 spawn: perf prep on box (EXPLAIN on snapshot, perf tests for Mac open, low-risk fixes) on top of integration (sonnet high)
2026-10-31 orchestrator Q12 on branch: drain/Q12-2026-10-31 1dd6672 four nav fixes; merged into integration (6e8c1b8, clean), job queued
2026-10-31 orchestrator Q10 on branch: drain/Q10-2026-10-31 655d108 place-page read fix + perf baseline tests; merged into integration d3f2a98, job queued
2026-10-31 orchestrator - all run items coded; holding for Mac open (stacking more uncompiled Swift raises compile-fix risk)
2026-10-31 orchestrator - resumed: PM relayed holiday mode (keep going headless, take recs on reversible branch work)
2026-10-31 orchestrator Q2 landed on main: #35 status doc from Q9 branch (docs only); Q2 closed, absorbed by Q9
2026-10-31 orchestrator Q14 spawn: static compile review of integration d3f2a98 (sonnet medium, seat, integration worktree)
2026-10-31 orchestrator Q15 spawn: category-group HTML mockups, 3 variants, review page only (sonnet medium, seat)
2026-10-31 orchestrator Q15 done: 3 category-group mockups on review page :4181 (rec A: up/down split line); preview restarted (was down); no app code
2026-10-31 orchestrator Q14 done: static review of integration, 1 compile error fixed (FileDateHistoryTests path:), head ce98857, job 20261031-161437-...-ce9885791-test queued; d3f2a98 job superseded
2026-10-31 orchestrator - decided: Waiting item 6 accepted per rec (variant A) on PM holiday-mode relay; reversible branch, unlanded
2026-10-31 orchestrator Q16 spawn: category groups variant A off integration ce98857 (sonnet high, seat worktree); Q17 checkpoint table queued after (shares feed code)
2026-10-31 orchestrator Q16 on branch: drain/Q16-2026-10-31 d814a88 variant A (EpisodeBuilder split/smaller-changes + 7 tests, 3 views), uncompiled, job queued
2026-10-31 orchestrator Q17 spawn: checkpoint table design doc only, code waits for Mac compile (schema on top of uncompiled v26) (opus medium, seat)
2026-10-31 orchestrator Q17 landed on main: checkpoint table design (f86244b, docs only); recs accepted (v27, real start date, 90-day expiry); Q18 build queued after integration compiles
2026-10-31 orchestrator Q18 spawn: checkpoint table 4 slices off Q16 d814a88, own branch so integration stays clean; replay.py check on box (sonnet high, seat worktree)
2026-10-31 orchestrator Q18 on branch: drain/Q18-2026-10-31 8f77404 v27 checkpoints, 4 slices + tests, uncompiled; replay.py 81 shifts/16 places -> 0, matches full history; job queued
2026-10-31 orchestrator - holding: headless queue empty; remaining triage items #23 #25 are UI refactors on the same uncompiled views, deferred to after Mac compile; Q7/Q11 worktrees removed
2026-11-01 orchestrator - Mac open (Grok relay, Merlin 12:18 WITA); 7 superseded prunr jobs moved to done; drain started (ce98857 integration, d814a88 Q16, 8f77404 Q18); Q8b b924a3f job had already PASSED
2026-11-01 orchestrator - Merlin using the Mac (PM relay 12:21 WITA): headless test jobs continue; idle soak (real app instance) held for tonight's visible go
2026-11-01 orchestrator - Merlin: holiday queue, no reviews, keep working; own priorities O1-O8 added to STATE; review-page service dropped (not wanted)
2026-11-01 orchestrator Q3 done: note in Mac checkout, bulky list in STATE (13 GB regenerable); nothing deleted
2026-11-01 orchestrator O3 blocked: no FEEDBACK_AGENT_TOKEN on dev (with-secrets map) and Vercel CLI logged out; Waiting item 8
2026-11-01 orchestrator O5 spawn: replay.py drift tests on Q18 branch (sonnet medium, seat)
2026-11-01 orchestrator O7 spawn: test gap audit doc (sonnet medium, seat)
2026-11-01 orchestrator O7 landed on main: test gap audit (c8a5951, docs only); top gaps cleanup retention, orphan paths, disk accounting, baseline reset, failed-scan rollback
2026-11-01 orchestrator O7b spawn: tests for top 5 gaps off main (sonnet medium, seat worktree)
2026-11-01 orchestrator O5 done: scripts/audit/test_replay.py + make audit-test on Q18 branch (8a32284), 14 pass on dev
2026-11-01 orchestrator O4 spawn: Q18 follow-ups on Q18 branch (sonnet medium, seat)
2026-11-01 orchestrator O3 done: feedback API read (Vercel login on dev), 1 item since alpha.24, positive, no bugs
2026-11-01 orchestrator O4 done: Q18 branch ea0304b harness carries + cutoff-run hold + first-prune perf test; 17 py tests pass; job queued
2026-11-01 orchestrator O7b on branch: 8 tests for top 5 gaps (66171c8), tests only, job queued; possible bug noted: resetBaseline leaves scanning snapshots
2026-11-01 orchestrator O7c spawn: tests for gaps 6-10 on O7b branch (sonnet medium, seat)
2026-11-01 orchestrator O7c on branch: 12 tests for gaps 6-10 (24eba7c), job queued; resetBaseline/scanning snapshot is by design (15 min abandoned cleanup); new bug O9 DiskSpaceService 0-free on error
2026-11-01 orchestrator O9 spawn: DiskSpaceService nil on failure + call sites (sonnet medium, seat worktree)
2026-11-01 orchestrator O9 on branch: 596ce37 DiskSpaceService nil on failure, manager keeps last values, 4 tests, job queued
2026-11-01 orchestrator O10 spawn: abandoned-snapshot cleanup fragility check (sonnet medium, seat)
2026-11-01 orchestrator O10 done: cleanup fragility is not data loss (crash-window rollback only); 2 tests e48ceb2
2026-11-01 orchestrator O11 spawn: remove dead MainViewModel (haiku low, seat worktree)
2026-11-01 orchestrator O11 dropped: MainViewModel only used by 2 tests; cleanup not worth churn
2026-11-01 orchestrator O12 spawn: stacked test branch Q18+O7b+O9+O10 (sonnet medium, seat worktree)
2026-11-01 orchestrator O13 spawn: always-active place never prunes check (sonnet medium, seat worktree)
2026-11-01 orchestrator O12 on branch: drain/stack-2026-11-01 062ef4c, one Mac job replaces 7 per-branch jobs (marked superseded)
2026-11-01 orchestrator O13 on branch: d2c0d68 real bug, nonstop-active place never pruned; fix cuts runs at 24h (user-visible episode split, Waiting item 8); job queued
2026-11-01 orchestrator decided item 8 per rec (PM holiday relay): O13 merged into stack f6c8a3c, job requeued; untracked pycache
2026-11-01 orchestrator O14 spawn: static compile review of stack vs integration (opus medium, seat)
2026-11-01 orchestrator O14 done: stack 5320785, 2 implicit-self compile errors fixed (one from Q10); integration + f6c8a3c jobs superseded by 5320785 job
2026-11-01 orchestrator O15 O16 spawn: implicit-self sweep (sonnet), checkpoint clear check read-only (sonnet)
2026-11-01 orchestrator O16 checked: per-path clear deletes all checkpoints, real (other paths lose folded history); fix queued on stack after O15, per rec (holiday relay)
2026-11-01 orchestrator O15 done: no further implicit-self cases
2026-11-01 orchestrator O16 spawn: per-path checkpoint delete fix on stack (sonnet medium)
2026-11-01 orchestrator O16 fixed on stack d0064bd: per-path clear keeps other paths' checkpoints, 1 new test; job requeued (5320785 superseded)
2026-11-01 orchestrator O17 spawn: align test expectations with 24h run cap on stack (sonnet medium)
2026-11-01 orchestrator O17 done: no test expectations affected by the 24h run cap; dev-side own priorities exhausted until the stack Mac job reports
2026-11-01 orchestrator answered: Mac go for the night (Merlin 19:53 WITA via PM, visible allowed); stack job 20th in shared queue, soak after it passes
2026-11-01 orchestrator answered: Mac go 21:42 WITA (everything incl. visible/overnight); queue draining, prunr stack job 17th
2026-11-01 orchestrator blocked: mac-queue starvation (demos exclusive jobs block parallel claims, lab-infra dispatch_round); told Grok with fix rec, not editing lab-infra
2026-11-01 orchestrator O1: stack d0064bd Mac run compiled, 487 tests 12 failures; fix worker spawned (opus medium, seat)
2026-11-01 orchestrator O1 fix on branch: stack 8b830ce, 12 failures addressed (1 real bug: cancelled scan cleanup), job queued; O18 test host isolation queued
2026-11-01 orchestrator O18 on branch: stack 14be69a test host isolation, job queued
2026-11-01 orchestrator O1 Mac: stack 8b830ce 487 tests, 2 failures left (compact appBusy x2, workaround did not help); O18 job 14be69a pending decides
2026-11-02 orchestrator O1 done: stack 14be69a green on Mac (all tests); snapshots fetched to review /app/
2026-11-02 orchestrator O19 spawn: non-UI land branch off main (sonnet medium, seat worktree)
2026-11-02 orchestrator O19 on branch: drain/land-2026-11-02 8519b7a non-UI subset, job queued
2026-11-02 orchestrator O19 landed: drain/land-2026-11-02 merged into local main 7cbb6c8 after green Mac job (not pushed); UI/schema rest waits on item 9
