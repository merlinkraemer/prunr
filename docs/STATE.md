# Prunr — state

_Updated: 2026-11-17 by orchestrator (on dev). Live state only, max ~80 lines. History → docs/journal.md, facts → memory, long-term → docs/product-roadmap-2026-09-07.md._

## Direction
Compass: not iced, design mode, alongside Pad/Bounce. Infrastructure is done (notarized DMG, Sparkle, signup). The core screen is unsettled: answer "where did my storage go" at once, without over-detail. Lens to test: growth as a sentence ("Since last week, 14 GB appeared: 9 in Xcode caches…"). Core screen settled 2026-10-11; build per docs/core-screen-episodes-prd-2026-10-11.md. Loose end: fix #35 when a morning opens. Parked: website DMG vs App Store, price (~€5.99 one-time).

## Ship target
A stranger downloads the alpha from the website and gets a one-glance answer to "what grew". Done for the current queue: code runs from dev with a green Mac test run, and #35 status is known.

## Rulebook
AGENTS.md ## Unattended. Holiday ended 2026-11-13 (Merlin: "holiday mode is over now"); UI/schema still lands only on his ok.

## Waiting on Merlin
1. Tester feedback on alpha.24: still 1 item (checked 11-13), positive (found a 25 GB app install via the change list); no bugs reported — rec: recheck weekly — branch: none
4. Background reconciliation + watcher pre-arm still gated on Full Disk Access; access loss after a scan would show skipped folders as a big shrink — rec: decide after beta feedback — branch: none
5. [done 2026-11-13, Merlin yes] Closed #29 #32 #34 #18 #11 #26 with notes
9. [landed 2026-11-17 on local main efef1b5, Merlin "Yes, land it"] Review build: new core screen, review fixes, DB shrink (items 3, 6, 7, 8, 10, 11 folded in), pulse; Mac green 543 tests; not pushed - next: alpha.25 on your go - branch: none
12. [done 2026-11-17] Homebrew: tap live (merlinkraemer/homebrew-prunr, CI green), brew line live on the download page (3c127f6) - cask auto-bumps hourly from the latest release (tap bump.yml) - branch: none


## Run
status: stopped 2026-11-13 (holiday over) · ran since 2026-10-30 10:15 · cap 2 workers · autonomy loose (Merlin 10-30: land green non-UI work on local main; never push, no beta/release)
targets: hardening, real-data usefulness, perf, bug/code review (Merlin 11-02), then own prios; keep working until Merlin says stop
mac-queue: LAB2_HOST=dev; Mac go given 11-02, orchestrator drains (MAC_QUEUE_IGNORE_BATTERY=1)
hands-on build drain/O49 installed on Merlin's Mac 11-06 (backup ~/prunr-backup-2026-11-06): DB 3.56 -> 1.3 GB, 7 days up at 0% CPU (covers Q9 soak); panel ignored clicks during the >77 s upgrade; steps 1-9 not yet done
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
- known doubts: O27a more watcher churn from browser WAL (check in soak); O28c clicks ignored during the one-time upgrade: O48 traced it, the DB opens off the main thread since 51cad7e so macOS stays responsive, but the panel/Settings/Feedback silently ignore clicks with no sign of work for ~37 s on the first launch after the shrink update (Quit + updates work); [option 1 built per rec as O49: existing menu bar pulse runs while the DB opens, no new copy; Mac green 06dabf4 (543 tests), branch drain/O49-2026-11-04 on top of O47; look at it in the hands-on session] alternatives: 2 panel shows an "Upgrading database" state (new copy); 3 leave it

## Rundown
- 11-17: review build landed on local main efef1b5 (Mac green), not pushed; Homebrew tap live, auto-bumps hourly; brew line on the download page.
- Next: alpha.25 (release needs your go).
