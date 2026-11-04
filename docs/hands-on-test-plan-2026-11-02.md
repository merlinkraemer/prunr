# Prunr hands-on test session - plan (2026-11-02)

Goal: Merlin decides item 9 (land the UI/schema rest) by using the build, not mockups. About 45 minutes at the Mac, real data.

## What gets tested
One combined test build: `drain/stack-2026-11-01` (category groups, drilldown that explains growth, captions, nav fixes, checkpoints) plus the O23-O28 fixes (watcher, denied folders, sleep-safe scans, hard links, missing drives, scope-change safety, faster scans and startup). Branch `drain/O49-2026-11-04` (06dabf4, 543 tests green): hands-on-2 plus the database shrink (items 10 and 11, migrations v28-v32, your DB 3.47 -> about 1.04 GB) and the menu bar pulse while the database opens (O28c/O49).

## Setup (orchestrator, on Merlin's go)
1. Back up `~/Library/Application Support/Prunr` to `~/prunr-backup-2026-11-02` (the build migrates the DB to v32 and rewrites most tables, no way back without the backup). Note the file size: `du -h ~/Library/Application\ Support/Prunr/prunr.db`..
2. `mac-queue add ... mac-install Prunr`: signed Debug build installed to /Applications/Prunr.app.
3. Rollback: quit, restore the backup folder, reinstall alpha.24 from the website.

## Steps
Reply per step with the number and "ok", or what felt wrong (one line is enough).

| # | Do | Look for | Pass if |
|---|---|---|---|
| 0 | Launch the build, watch the menu bar icon for about 40 s | Icon pulses while the database upgrades, panel opens after | Pulse feels right, no crash, panel works |
| 1 | Open the panel | The top answers "what grew" | You know in 5 s where storage went |
| 2 | Look at a category group row | Up/down split under the group total | Split makes sense, no unrelated places netted into one number |
| 3 | Open that group | Per-place rows, sorted by size, "smaller changes" row | Rows add up to the group header |
| 4 | Tap a "folder grew" row | Page lists what inside actually grew | You can tell what to delete, not just a folder listing |
| 5 | Read row captions and names | "found by scan · since ...", names without generic parents | Wording reads naturally |
| 6 | Drive bar -> Categories, drill in and out fast, close and reopen | Flicker, double slides, snapping, wrong header | Nothing jumps |
| 7 | Download or copy ~1 GB into Downloads, wait 1 min, then delete it | Growth row appears, then shrinks | Both show within about a minute |
| 8 | Settings -> Rescan, close the lid 1 min mid-scan, reopen | Scan status | Scan finishes, no "Scan failed" |
| 9 | Open Settings categories with the panel closed | List content | Matches the panel |
| 10 | Leave it idle 15 min, check Activity Monitor | Prunr CPU | Near 0% |
| 11 | Run the `du -h` from setup again | DB file size | Clearly smaller than before (about 1-1.4 GB; free space reclaims over the next idle cleanup) |

## After
- Keep the build or roll back (setup step 3).
- Orchestrator turns each "wrong" into a fix branch; item 9 lands only on Merlin's ok.
- The Q9 2h idle soak can run in the same Mac session.
