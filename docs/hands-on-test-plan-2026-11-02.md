# Prunr hands-on test session - plan (2026-11-02)

Goal: Merlin decides item 9 (land the UI/schema rest) by using the build, not mockups. About 40 minutes at the Mac, real data.

## What gets tested
One combined test build: `drain/stack-2026-11-01` (category groups, drilldown that explains growth, captions, nav fixes, checkpoints) plus the O23-O28 fixes (watcher, denied folders, sleep-safe scans, hard links, missing drives, scope-change safety, faster scans and startup). Branch `drain/hands-on-2-2026-11-02`, green on the Mac before the session.

## Setup (orchestrator, on Merlin's go)
1. Back up `~/Library/Application Support/Prunr` to `~/prunr-backup-2026-11-02` (the build migrates the DB to v27, no way back without the backup).
2. `mac-queue add ... mac-install Prunr`: signed Debug build installed to /Applications/Prunr.app.
3. Rollback: quit, restore the backup folder, reinstall alpha.24 from the website.

## Steps
Reply per step with the number and "ok", or what felt wrong (one line is enough).

| # | Do | Look for | Pass if |
|---|---|---|---|
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

## After
- Keep the build or roll back (setup step 3).
- Orchestrator turns each "wrong" into a fix branch; item 9 lands only on Merlin's ok.
- The Q9 2h idle soak can run in the same Mac session.
