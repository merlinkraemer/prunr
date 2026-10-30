# Real-data usefulness audit (Q7, 2026-10-30)

Question: on the owner's real data, what does the change list say, what does each drilldown show, and where does a user end up asking "but what grew?". Input for Q8 (fix the drilldown to explain growth).

## Scope and method

- Data: slim DB snapshot of 2026-10-30 (journal buckets 2026-10-15..10-29, place index `workingSetPlaceChild`, 9 snapshots). `snapshotEntry`, `workingSetEntry`, `pathClassification` are not in the slim copy.
- No Swift compiler on dev. The feed and drilldown are replayed in Python, each function names the Swift it mirrors (`scripts/audit/replay.py`): `fetchJournalSlots` (`DatabaseManager.swift:1951`), `EpisodeBuilder.build` (`EpisodeBuilder.swift:345`), `UnitNamer`/`UnitRules`, `ChangeFeedDay.groups` (`EpisodeBuilder.swift:98`), `fetchPlaceContents` (`DatabaseManager+Drilldown.swift:896`), `FeedPage.soloPlace` (`ListNavigation.swift:58`).
- Re-run: `python3 -I scripts/audit/audit.py <slim.db> --rows` (class table plus per-row evidence); `scripts/audit/feed_dump.py` prints the reconstructed list.
- Assumptions, to confirm with the Q6 replay: local time zone Europe/Berlin; "now" = the file time of the snapshot; owner names are resolved with an empty installed-app catalog (the app merges helper ids into installed apps, so a few owner names or groups may differ); a unit's category is the one stored in the journal (the app recomputes it from the path; same for nearly all units).
- All numbers below are about the reconstructed list. Paths are generalised: `~` is home, `<...>` stands for a personal folder or app name.

## What the real list looks like

- 46 change rows (places with a row) on 33 distinct places, 30 main-list rows (owner x day). 27 of the 30 hold one place, so a click goes straight to that place's contents page. 3 groups hold several places (19 rows).
- Journal: 2,742 buckets, 2,600 from the daily scan and 142 from the watcher. Only 4% of slots (5% of the bytes moved) came from the watcher.
- 2026-10-19..10-25 has no scan (Mac off). The scan on 10-26 reconciled an 8-day window and produced 26 of the 46 rows, all dated "Mon 26 Oct".
- Header this week +27.00 GB; the week's rows add up to +29.57 GB; 689 of 717 moving places have no row (net -4.5 GB, 20.6 GB gross).
- Place pages come from `workingSetPlaceChild`: one level, current size per child, no per-child change. `snapshotEntry` is kept for the last 2 snapshots only (`DatabaseCleanupService.swift:24`), so per-file history is gone for every row older than about a day.

## Summary table

Rows can carry several classes. GB share = share of the 198 GB total of row amounts (absolute).

| # | Class | Rows | Share of rows | GB share | Severity | Needed data in DB today? |
|---|-------|-----:|--------------:|---------:|----------|--------------------------|
| A1 | Page shows sizes, not growth (non-empty page) | 36 | 78% | 87% | High | No: must be recorded (L1) |
| A2 | Same place, several rows, identical page | 21 | 46% | 62% | High | No: needs per-day detail (L1) |
| A3 | Growth buried: place far bigger than growth (needle) or growth under one big folder the app cannot open | 12 | 26% | 39% | High | No (L1, with depth) |
| A4 | Shrink rows: page shows what is left, not what went | 21 | 46% | 32% | Medium | No (L1 records removals) |
| A5 | Empty page ("No files found") | 10 | 22% | 13% | Medium | Partly: "now 0, was about X" is derivable |
| B1 | Row has no time or caption (daily-scan only) | 43 | 93% | 97% | High | Yes (`observedSince`, source) |
| B2 | Catch-up scan: one row spans 8 days, dated the scan day | 26 | 57% | 54% | High | Yes (`observedSince`) |
| B3 | Row says more than the place holds now | 2 | 4% | 2% | Low | Derivable (now vs row) |
| B4 | Move shown as shrink row plus growth row | 4 | 9% | 5% | Low | Yes (same size, same day) |
| B5 | Header vs rows: sub-1 GB places invisible | 689 places | - | - | Low | Yes |
| C1 | Category group nets unrelated places ("Developer +9.9 GB" = +44.3 / -34.5) | 17 | 37% | 46% | High | Yes |
| C2 | Confusing place names (two-folder places, parent folder as project) | 12 | 26% | 54% | Medium | Yes (naming) |
| C3 | One child: click jumps to Finder, page never shows | 3 | 7% | 5% | Low | Yes |
| - | Page plausibly explains the row (one row for the place, a child matches) | 6 | 13% | 8% | OK | - |

Union figures: growth rows 25 (54%, 68% of GB), shrink rows 21. 41 of 46 rows (93% of GB) are shrinks, buried growth or a repeated page; 40 of 46 are not plausibly explained by what the page shows.

## Class details

### A1. The page shows sizes, not growth (36 non-empty pages, plus 10 empty ones = every row)

Every place page lists the place's direct children by current total size (`PlaceChildRow`, `PlaceContentsView.swift:185`: size text is `child.totalBytes`). Nothing on the page is a change. The 10 empty pages say "No files found" (`ListNavigation.swift:320`).

Root cause: `fetchPlaceContents` reads `workingSetPlaceChild` (`DatabaseManager+Drilldown.swift:896`), which has `totalBytes` and `fileCount` only. The journal (`growthJournalBucket`) is per (unit, category, subcategory), with no child. Recording hooks already hold the per-child numbers and drop them: `applyWorkingSetChanges` builds `placeDeltas` per child (`DatabaseManager+Drilldown.swift:242-290`) next to the journal delta, and the scan has per-path deltas from `calculateDeltas` (`BaselineService.swift:161`) before it collapses them to one number per unit (`:164-175`).

Data in DB: no. Must be recorded (L1 `growthJournalDetail`).

Examples (generalised):
- `~/<area>/<resources>` (+27.0 GB on 29 Oct, +2.4 GB on 15 Oct): the page lists 16 folders, 400 GB total, largest `<installers>/` 238 GB, then `<audiobooks>/`, `<assets>/`, `<games>/`. Which one grew 27 GB is not on the page.
- `~/dev/<build-root>` (+3.7, +8.4, +3.0, +6.3, +5.1 GB on five days): one page, 216 per-project build folders, 39.9 GB.
- `~/.claude` (+3.1 GB on 26 Oct, +1.4 GB on 29 Oct): 60 children, `projects/` 5.6 GB; the row's +3.1 / +1.4 is not there.

### A2. Same place, several rows, one identical page (21 rows on 8 places)

A place's page does not depend on the row's day or amount (`fetchPlaceContents(unitRoot:)` takes no time span). Places with several rows: the build root (5 rows), a compiler cache (4), and six places with two rows each.

Root cause: the page is keyed by place, not by episode (`MenuBarView.swift:1371`, loader `loadPlaceContents(unitRoot:)`; `MenuBarManager.swift:1910`).

Example: a game project folder `~/dev/<game>` has two rows, +13.9 GB (18 Oct) and +32.1 GB (26 Oct). Both open the same page: `research/` 32.3 GB, `critters/` 13.6 GB, 7 tiny others. Current sizes happen to match the two rows, so one could guess, but the page does not say which row belongs to which folder (this is the one place where per-child deltas would be provably right).

Data in DB: no (L1). Needs the row's time span (`day`, `buildingSince`) passed to the query.

### A3. Growth buried (12 rows, 39% of GB)

Two shapes, both from "the page is one level of current sizes and rows are leaves":
- Needle (10 rows): the place now holds at least 4x the row's growth. `~/<area>/<resources>` +27 GB of 400 GB; `~/dev/<build-root>` +5 GB of 40 GB; an app's `Application Support` folder +1.7 GB of 13 GB (`vm_bundles/` 10.7 GB is the biggest child, probably unrelated).
- Deep (6 rows, overlaps): the biggest child is a folder holding most of the place and larger than the growth, so the change is somewhere inside it, and a child row cannot be opened (it only reveals in Finder: `PlaceChildRow` `onTap` -> `onReveal`, `PlaceContentsView.swift:126`). Examples: the toolchain folder of a language toolchain (+1.4 GB inside a 4.1 GB `toolchains/`), the 400 GB resources folder (`<installers>/` 238 GB).

Root cause: place pages are depth 1 and non-navigable; `PlaceChildKey` stores only the first path part below the root (`DrilldownIndex.swift:76-100`).

Data in DB: no. Needs per-child deltas plus a deepest-dominant-path (see fix list).

### A4. Shrink rows show what is left (21 rows, 32% of GB)

A row like "uv cache -11.1 GB" opens a page with 38 children totalling 0.5 GB: what remains, not what went. For 14 of 21 shrinks the place now holds under 25% of the amount that went.

Root cause: same as A1; the working set no longer has the removed paths, so only a journal that records children can say what went.

Severity medium: most are caches cleared (cache -4.6 GB, -3.4 GB, -2.2 GB...), so "cleared" is the honest answer, but the page does not say it. Not moved to Trash (0 rows flagged `isMovedToTrash`).

### A5. Empty page (10 rows, 13% of GB)

The place is gone or empty (`frida cache -7.3 GB`, `torch cache -1.7 GB`, `Spotify cache -3.4 GB`, a Python env and a git folder that moved). The page reads "No files found". Data: "now 0 B, was about 7.3 GB" is derivable from the row (was = now - row amount).

### B1. No time and no caption (43 of 46 rows)

43 rows come from the daily scan only (`isApproximateTime`) and 1 more is a multi-day build, so `timeCaption` returns nil (`EpisodeBuilder.swift:461`) and the row shows title and amount only. 2 rows show a time. The comment at `EpisodeBuilder.swift:313` says a scan row reads "found by scan" and a multi-day row "a little each day since ...", but no code renders either (`grep` finds the strings only in comments).

Data in DB: yes (`source`, `observedSince` on `JournalSlot`, `EpisodeBuilder.swift:21`).

### B2. Catch-up scan (26 rows, 54% of GB)

The 10-26 scan covered 18 Oct 09:16 to 26 Oct 12:39 local time (196 h). Its residual is booked at `snapshot.createdAt` (`BaselineService.swift:189-195`), so everything found lands on "Mon 26 Oct": +32.1 GB game project, -11.1 GB uv cache, -7.3 GB frida cache, +6.3 GB build root and 24 more rows. `isApproximateSlot` (`EpisodeBuilder.swift:586`) knows the window but only turns the time caption off.

Same pattern, smaller: every other scan row has a 24 h window and is dated the scan day.

Data in DB: yes (`observedSince`).

### B3-B5. Amounts that do not add up

- B3: the row says more than the place holds now (2 rows): `<app> cache` +1.84 GB (18 Oct) but the place holds 0.01 GB (cleared on 26 Oct); a build folder +1.5 GB with 0.5 GB left. Growth rows for places that were later cleaned are indistinguishable from live growth. Derivable by comparing the row with the current place total.
- B4: moves show as two rows (4 rows, 2 pairs): a Python env of 3.46 GB and a `.git` of 1.15 GB moved between two project folders on 15 Oct: a -3.46 and a +3.46 row, a -1.15 and a +1.15 row (9.2 GB of rows for no change). Roadmap item L6 already covers this.
- B5: the header says +27.00 GB, the week's rows add to +29.57 GB, and 689 places moved 20.6 GB gross with no row (below 1 GB each). No "smaller changes" row exists in the code (`grep "smaller change"` finds nothing), so the gap cannot be opened.

### C1. Category groups net unrelated places (3 groups, 19 rows, 46% of GB)

`ChangeFeedDay.groups` groups a day by owner (`EpisodeBuilder.swift:98`); category owners ("Developer") with several places read the category name (`ListNavigation.swift:96`) and the sum of the places (`ChangeGroup.netBytes`, `EpisodeBuilder.swift:143`). On 26 Oct "Developer" holds 12 places: +44.3 GB up, -34.5 GB down, shown as "Developer +9.9 GB". 15 Oct: 5 places, +8.3 / -4.6, shown as "+3.7 GB". Opening it lists the places, so this is recoverable by a click, but the row amount is not a thing that happened.

### C2. Confusing names (12 rows, 54% of GB)

- Place fallback is the first two folders below home (`UnitRules.placeRoot`, `UnitNamer.swift:295`), named "<inner> · <outer>": "3-Resources · local" (a 400 GB tree), "game · dev", "Builds". Seven rows (80 GB) are such places; the title names a folder two levels from home, not the thing that grew.
- Build output takes the project name from the parent folder (`UnitRules+Developer.swift:282`), which for `~/dev/build` is "dev": "Build files · dev" on 5 rows (26.5 GB), while the page lists 216 project folders. The parent is a developer root folder name, not a project.
- Owners without an installed-app catalog read the folder or id tail: "Codexbar", "LightroomCC", "ccache", "ms-playwright"; the app resolves these through `AppCatalog` and may name them differently (confirm in the Q6 replay).
- Child names that mean nothing: a compiler cache's page lists `0`, `2`, `e`, `5`, `c` (hash shard folders) for a 4 GB place.
- "Applications" (a category owner) heads a row for a user's build folder.

### C3. Single child opens Finder (3 rows)

A place with exactly one child skips the page and reveals that child (`SoloDrill.revealPath`, `ListNavigation.swift:86`; `MenuBarManager.swift:1831`). For `<game>.app` +1.8 GB and a device-support folder -7.0 GB the user lands in Finder and never sees the page. Fine for a file, odd for a folder.

## Where per-child detail would and would not already work (check for Q8)

- 2 of 46 rows (29 Oct) fall inside the window of the two retained snapshots, so L0-style "compare snapshot with working set" could explain them. 44 rows (86% of GB) are older.
- `workingSetTopEntry` (top 200 files per group, with sizes, no dates) covers a median 37% of a place's bytes and exists for 35 of 46 places. It shows the biggest files now, not the new ones, so it is not an answer for growth.
- The journal's `subcategory` (file kind such as "build artifacts") is a weak hint only: one kind holds 70% of the row in 25 rows that span several kinds, but it is a classification, not a location.

## Ranked fix list for Q8

| Rank | Fix | Size | Type | Covers |
|-----:|-----|:----:|------|--------|
| 1 | L1 `growthJournalDetail`: record per-child delta (child name, delta, source, bucket, unit) at the three write points: scan residual (`BaselineService.swift:161-203`), watcher (`DatabaseManager+Drilldown.swift:242-290`, `placeDeltas`), file-date history (`FileDateHistory.swift:78`). Keep the top 20 children by absolute delta plus an "other" remainder per bucket and unit. Reconcile the scan residual per child like per unit. | L | data + logic | A1, A2, A3, A4, A5, B3 |
| 2 | Row-scoped place page: `fetchPlaceContents` takes the row's day span (`day`, `buildingSince`, `observedSince`), joins the summed child deltas to the current children, sorts by absolute change, shows removed children that no longer exist, keeps current size as the secondary number. Needs rank 1. | M | logic + UI | A1, A2, A4, A5 |
| 3 | Descend to the growth root: at record time, while one child holds at least 80% of a child's delta, also store that deeper path (depth up to 6) so a row can read "<child>/<sub>/<sub> +30 GB". Alternative: make place pages navigable. | M | data + logic | A3 (12 rows, 39% of GB) |
| 4 | Honest fallback for rows without detail (everything before rank 1 ships, and all 30-day history): caption on every place page "Now X, row +Y on <day>", children labelled "Size now"; for empty places "Gone (was about X)". No new data. | S | UI + small logic | A1, A4, A5, B3 now |
| 5 | Show the scan facts on the row: "found by scan" and, for windows over 36 h, "since Sun 18 Oct" (the comment at `EpisodeBuilder.swift:313` already promises it). Needs the window start on `ChangeEpisode` from `JournalSlot.observedSince`. | S | UI + logic | B1, B2 |
| 6 | Do not net unrelated places in a category group: show the gross split ("+44 / -35 GB") or per-place rows for category owners with several places. Copy and layout are the owner's call. | M | UI | C1 |
| 7 | Naming: drop the project name when the parent is a developer root folder (`projectName`, `UnitRules+Developer.swift:282`, `projectRoots` at `:242`), and avoid "<inner> · <outer>" for the two-folder place fallback when a child list can name the thing. Keys do not change. | S | logic (names) | C2 (build-root rows) |
| 8 | "Smaller changes" row for the week gap (689 places, 20 GB gross), so header and rows reconcile. Planned in the PRD, not built. | M | logic + UI | B5 |
| 9 | Pair moves (shrink plus growth of the same size on the same day) into one "Moved" row; roadmap L6. | M | logic + UI | B4 |
| 10 | Single-child shortcut: open the page for a folder child, reveal only a file. | S | UI | C3 |

Notes for Q8:
- Ranks 1-3 are data and logic; they are the real fix. Rank 4 and 5 are the cheapest honest steps and help every old row, because rank 1 cannot back-fill (per-file history is gone after 2 snapshots).
- Rank 1 adds a table and a migration: a data/schema change, so it needs the owner's go (`AGENTS.md` must-ask).
- Rows, owner naming, copy and group layout (ranks 5, 6, 7) are user-visible: owner decision.
- The scan and watcher both feed the same journal; per-child records must reconcile (residual = authoritative - recorded, per child) or the child list will double-count what the watcher already saw.

## What the Q6 Mac replay should confirm

1. Feed shape: 46 rows, 30 main-list rows, week header +27.00 GB (time zone and "now" assumptions).
2. Place pages for the key rows: the 16-child 400 GB page, the 9-child 46 GB game page, the 216-child build root (50 shown, "Show more"), the 38-child 0.5 GB cache that lost 11 GB, the empty pages ("No files found").
3. Replayed `rootPath` pages for rows that share a place are byte-identical (A2).
4. Owner names and group splits with the real installed-app catalog (C2): does "Codexbar", "ccache", "LightroomCC" change; does the "Developer" group on 26 Oct still hold 12 places.
5. Whether any episode shows a time or caption in the replay (B1: expect 2 of 46).
6. Category stored in the journal vs `GrowthCategory.categorize` for the 33 row places (the audit used the stored one).
7. The `ReplayRow.slots` per row: net, gross and window; check that the 10-26 rows list the 196 h scan slots (B2).
