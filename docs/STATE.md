# Prunr — state

_Updated: 2026-11-02 by orchestrator (on dev). Live state only, max ~80 lines. History → docs/journal.md, facts → memory, long-term → docs/product-roadmap-2026-09-07.md._

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
9. Land the UI/schema rest after a hands-on session (Merlin 11-02 via PM: "same for prunr", can't judge from mockups) - plan: docs/hands-on-test-plan-2026-11-02.md (~40 min, real data, 10 steps, DB backup + rollback) - rec: run it at the next Mac session, then land on your ok - branch: drain/hands-on-2-2026-11-02 723d4cf (stack + O23-O36 fixes, Mac green)
10. Drop 2 redundant DB indexes (v28 migration, schema) - Mac green; not faster, but your real DB is 3.47 GB and these 2 indexes are 343 MB (10%) - rec: land with the hands-on batch (changed from park after O37 measured it); merged into hands-on-2 with v28 FK check skipped - branch: drain/O32a-2026-11-02 7141ff4
11. Prunr's own DB is 3.47 GB on your Mac; full path text stored twice (table + unique index) is 1.41 GB (41%) - rec: plan a parent-id + name path store after the holiday, a schema + storage redesign - doc: docs/db-size-review-2026-11-03.md - branch: none
3. [accepted 2026-10-31 per rec] Rows drift as the 30-day window slides (root cause + design: docs/checkpoint-table-design-2026-10-31.md): v27 growthJournalCheckpoint, show real "building since" date, expire quiet counts after 90 days — building as Q18


## Run
status: running · since 2026-10-30 10:15 · cap 2 workers · autonomy loose (Merlin 10-30: land green non-UI work on local main; never push, no beta/release)
targets: hardening, real-data usefulness, perf, bug/code review (Merlin 11-02), then own prios; keep working until Merlin says stop
mac-queue: LAB2_HOST=dev; Mac go given 11-02, orchestrator drains (MAC_QUEUE_IGNORE_BATTERY=1)
mac batch pending: Q9 2h idle soak + hands-on session (item 9), both on the next visible Mac go via Grok
data: Merlin's DB may be copied to dev (scratch, gitignored); committed fixtures synthetic only
review: https://dev.tail87069a.ts.net:4181 (mockups/category-groups.html, app/ snapshots)

## Queue
Done Q1-Q18 (history: docs/journal.md). Landed on local main 7cbb6c8 (not pushed). UI/schema rest: drain/stack-2026-11-01, superseded by the hands-on builds.

### Own priorities (Merlin 11-02: perf, app performance, detailed bug/code review, then own prios; no reviews needed)
Done: O1-O22 (journal); reviews docs/perf-app-review-2026-11-02.md, docs/code-review-2026-11-02.md, docs/code-review-combined-2026-11-02.md
- O23-O28 review fixes [all Mac green, merged into drain/hands-on-2-2026-11-02 fa13b78, Mac green]
- O30a quiesce wait 10 s timeout, aborts reset/scope change [drain/O30a-2026-11-02 0ee8a84, Mac green; new error copy needs Merlin]
- O31a watcher: denied is not deleted + hard links one rule [drain/O31a-2026-11-02 c23d919, Mac green; new multi-link file counts 0 until next full scan]
- O31b partial multi-path success re-arms full refresh [drain/O31b-2026-11-02 4042c28, Mac green; persistent failure = full refresh up to every 30 min]
- O30a/O31a/O31b merged into hands-on-2 5d19bd4 [Mac green]
- O32b same-size rename reloads drilldown [drain/O32b-2026-11-02 9e745ae, Mac green]; O32a indexes = Waiting item 10; O33 real-DB dry run [Mac green 04b9607: your DB v25->v27 migrate 13.4 s, prune 3 ms, feed 39 ms, 53 episodes, 1032 drilldown groups]; O32b+O33 merged into hands-on-2 ab61cce; O34 retry only failed paths [886c9fa Mac green, merged into hands-on-2 05b2f5d]; O35 found v26/v27 cost 8.6 s + 7.5 s on your DB (whole-DB foreign key check after create-only steps); O36 skips that check [723d4cf Mac green: v26+v27 now 3 ms total, was 16.1 s; hands-on-2 fast-forwarded to it]
- known doubts: O27a more watcher churn from browser WAL (check in soak); O28c clicks ignored during long migration (visible, Merlin call; was ~16 s on your DB, O36 cut it to ms)

## Rundown
- 11-02: Mac go; all review fixes green on branches; combined hands-on-2 build green; second review round fixing 3 interaction bugs. Nothing pushed.
