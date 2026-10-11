# Core screen: a list of things that happened
**Date:** 2026-10-11
**Status:** draft

## Problem

When the disk fills up, Prunr cannot say what did it. Today the popover is a size list of eight technical buckets ("Other 521 GB", "Caches & System 229 GB") under one number ("7-day change +15.5 GB"), and that number reads "0 MB" while a scan runs. No app, project, file or time appears anywhere. To find the culprit, the user has to compare rows in their head.

People remember storage loss as events: "I pulled a Docker image on Tuesday", "that Xcode build", "the ISO I downloaded". The screen should speak in those terms.

Three things in the data stop that today:
- Prunr records how much each category changed, but not which folder changed. A row cannot be named after a real app or project.
- Every daily scan overwrites the record of when changes happened. Everything collapses to the time of the scan.
- Pruning is only guaranteed to keep 7 days of history, and it runs only after a full scan.

## Solution

The main view becomes a list of **things that happened**, newest first. Each row names something the user recognises, says when it happened and shows how much space it took or gave back. A header on top shows how full the disk is and how much changed this week. The rows always add up to that weekly number.

### Screens and states

- **Header.** The coloured storage bar, as today. Under it, "19 GB free of 2 TB" on the left and "this week +48 GB" on the right. The weekly number sits on the same right edge as the row amounts. Clicking the header opens the categories view.
- **Categories view.** Today's category list, biggest first. Each row shows its size and its change this week. The last row is "Not watched · 122 GB": space outside the home folder. The existing drill (category → subcategory → files) stays. A back arrow returns to the list.
- **The list.** Changes are grouped under plain day labels: "Today", "Yesterday", weekday names within the last 7 days, then dates ("3 Oct"). Labels carry no sums and no decoration. Each row has:
  - an icon (the category's icon for now; real app icons later);
  - a recognisable name, with a muted caption of the clock time and a detail ("14:20 · Prunr");
  - a signed amount: orange when space was used, grey when it was given back.

  Each week ends with one row, "in 9 smaller changes +4.3 GB", that carries the rest. The list scrolls back 30 days and opens on this week.
- **Change detail (click a row).** A page for that change, in the style of today's drilldown. It lists the folders and files that changed in that place, each with its signed amount, plus Show in Finder. The page states which time span it compares, for example "Changes in Xcode build files since Tue 03:10". For a change older than what Prunr keeps on file, the page lists the biggest items in that place now, labelled as current sizes, and says that details of older changes are not kept.
- **Footer.** As today: refresh on the left, status in the middle, settings on the right.
- **Calm week.** The line "Nothing notable changed this week". The "smaller changes" row follows if anything moved, then older weeks.
- **Day one.** While the list is empty: "Watching your home folder since today. Changes show here from tomorrow." A big change on day one still shows as a row as soon as it happens.
- **Short history.** If Prunr has been watching for less than 30 days, the list ends with "Watching since 3 Oct".
- **Scanning.** The last list stays on screen and the footer says "Scanning…". Numbers never drop to 0 during a scan.
- **Error.** If history cannot be read, the list shows "Couldn't read change history" with a Retry button, and the weekly number shows "—". The list is never shown empty on an error.
- **Unchanged.** The menu bar item, onboarding and first scan, Settings, and the panel size.

### Rules

**What a row is.**
- A row is one place's changes on one day. A place is an app, project, library, download or named folder.
- Activity in the same place on the same day merges into one row. Activity that starts before midnight and runs past it stays with the day it started.
- The amount is the net change. Space that came and went within the day cancels out.
- The clock time is when most of the bytes moved.

**When the time is not known exactly.**
- Some changes are only found by the daily scan. If the scan was not triggered by a change in the last hour, the caption says "found 03:10 · daily check" instead of a clock time. 03:10 is when that scan started.
- If the scan was triggered by fresh activity (a big `npm install`, for example), the time counts as known.

**Which changes get their own row (adaptive).**
- Within each week, the cutoff for a row is 2% of all the space that moved that week. The cutoff never drops below 250 MB and never rises above 2 GB.
- At most 5 rows per day.
- Everything else goes into that week's "smaller changes" row.
- A busy week therefore lists only its big events, and a quiet week still shows its few real ones. Because the cutoff is set per week, a change can move between a row and the tail as the week moves on.

**This week.**
- "This week" covers the last 7 days: today plus the previous 6 days. Each day counts in full, so the header always equals the sum of the days shown under it.
- Older weeks are the 7-day stretches before that, going back 30 days.

**Names.**
- Use the most specific name a rule knows, for example "Xcode build files · Prunr", "node_modules · acme", "Docker disk" or "Downloads · ubuntu.iso".
- Otherwise, use the folder the user would recognise, for example "Archive · Documents".
- Never use a category word ("Other", "Caches & System"), a hash, a bundle id with dots, or a path longer than two parts.
- Docker's single disk file holds images, containers and volumes, so it is called "Docker disk", never "Docker images".

**Trash and moves.**
- Moving something to the Trash does not free space. The Trash growing is never shown as an orange row; it goes into "smaller changes".
- When a place shrinks because its bytes went to the Trash in the same minute, its row is captioned "moved to Trash" so it does not read as freed space.
- Emptying the Trash is a grey row, "Trash emptied −4 GB".
- Other moves show as two rows, one "−" and one "+".
- Space that comes and goes (churn) gets no line of its own in v1.

**Honesty.**
- The weekly number equals the rows plus the "smaller changes" row. The categories view's weekly changes add up to the same number.
- "—" means unknown: loading, a read error, or no history yet. A real zero, once history exists, reads "no change this week". "0 MB" is never shown while scanning.
- A cancelled or failed scan changes nothing on screen.
- Changes recorded before this update keep their rough category names ("Build files", "Downloads") until they age out after 30 days. On the day of the update, the daily scan's correction is also shown at that rough level instead of as new rows.
- Wording uses "grew", "appeared", "emptied", "moved to Trash". It never uses "because", "safe", "junk" or "stable".

## Out of scope

- Notifications, runway or forecast, deletion, cleanup or ignore actions, whole-disk watching.
- Changes to the menu bar item, onboarding, Settings (except the history floor rising to 30 days) or the panel size.
- A "Biggest places" screen or footer link.
- Pairing moves into one row (except the Trash caption above) and churn lines.
- A line comparing free-space change with watched changes.
- Exact per-change detail for changes older than the retained scan data. This is the later slice L1.
- Real app icons (L2) and names for Logic and iMovie (L3).

## Slices

Every slice is validated from lab2 with `mac-queue add <checkout> <ref> test Prunr` (runs `make test`, Xcode 16.4 is the compile target, `CODE_SIGNING_ALLOWED=NO`). Acceptance bullets are `make test` assertions unless marked **(owner visual check)**. Reads that cross an async `dbPool.read` must map rows to `Sendable` values inside the closure (`docs/lessons.md`, 2026-06-02).

### s1: Daily scans keep when changes happened
- **outcome:** A full scan no longer overwrites the watcher's timestamps. It only adds what the watcher missed, tagged as found by the scan, and the window total still equals the snapshot delta.
- **depends_on:** none
- **likely_files:** `Prunr/Database/DatabaseManager.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Models/CategoryInventoryItem.swift` (`GrowthJournalBucket` fields), `PrunrTests/BaselineServiceRegressionTests.swift`
- **changes:**
  - Migration `v21_journal_source`: add `source TEXT NOT NULL DEFAULT 'watch'` and `observedSince DATETIME NULL` to `growthJournalBucket`. Recreate `idx_growthJournalBucket_identity` on `(trackedPathId, bucketStart, category, subcategory, source)`.
  - `upsertGrowthJournalBuckets` (`:2247`): the `ON CONFLICT(...)` target must list `source`, or SQLite rejects the insert. The function gains `source` and `observedSince` parameters.
  - New `fetchGrowthJournalTotalsByKey(trackedPathId:from:to:)`.
  - `BaselineService.createBaseline` (`:141-171`): stop calling `deleteGrowthJournalBuckets(newerThan:)`. Compute `authoritative − provisional` per key over `(prev.createdAt, snapshot.createdAt]`. Write non-zero residuals at `snapshot.createdAt` with `source='scan'` and `observedSince = prev.createdAt`. `snapshot.createdAt` is the scan start (`ScanService.swift:193`). The first-baseline journal clear stays.
- **acceptance:**
  - A watch +10 GB at T1 followed by a scan finding +12 GB leaves +10 GB at T1 (watch) and +2 GB at scan start (scan).
  - A watch +10 GB followed by a scan finding 0 leaves a −10 GB residual.
  - The double-count regression (`BaselineServiceRegressionTests.swift:~229`) is rewritten for residual semantics and passes.
  - A cancelled scan writes no buckets.
  - Migration test: `migrate(upTo: "v20_add_snapshot_lifecycle")`, insert buckets, migrate fully; old rows read back as `source='watch'`.

### s2: Changes are recorded per place and listed by day
- **outcome:** Downloading a 2 GB file makes "Downloads · file.iso" appear under "Today" with its time and +2 GB, in a new list that replaces the category overview as the main view.
- **depends_on:** [s1]
- **likely_files:**
  - New: `Prunr/Models/UnitResolver.swift`, `Prunr/Models/UnitNamer.swift`, `Prunr/Models/UnitRules+Developer.swift`, `Prunr/Models/UnitRules+Apps.swift`, `Prunr/Models/UnitRules+Media.swift` (the last three as empty stubs, so the name slices touch only their own file), `Prunr/Services/EpisodeBuilder.swift`, `Prunr/Views/ChangeFeedView.swift`, `Prunr/Views/ChangeRow.swift`, `PrunrTests/UnitResolverTests.swift`, `PrunrTests/EpisodeBuilderTests.swift`.
  - Edited: `Prunr/Database/DatabaseManager.swift`, `Prunr/Services/RecentChangeService.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Services/GrowthJournalService.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Views/MenuBarView.swift`.
- **changes:**
  - **Unit key.** `UnitResolver.resolve(path:)` is pure and `nonisolated` and returns `"<kind>|<rootPath>"` with case preserved. Names are computed at read time, so rule edits need no migration. Keys must stay stable across releases.
  - **SQL function.** Register `prunr_unit(path)` as a pure `DatabaseFunction` in `config.prepareDatabase` (`DatabaseManager.swift:53`).
  - **Migration `v22_journal_unit`:** add `unitKey TEXT NOT NULL DEFAULT ''`. Recreate the identity index with `unitKey` added, plus `(trackedPathId, unitKey, bucketStart)`. Update the upsert conflict target again.
  - **Write paths.**
    - `JournalDeltaKey` (`:499`) gains `unitKey`.
    - `replaceWorkingSetSubtree(stagingSessionId:)` (`:2086`) groups by `prunr_unit(path)`.
    - The other subtree variant, `replaceWorkingSetFile` (`:1840`), `removeWorkingSetPathOrSubtree` (`:1932`), `removeWorkingSetFileIfPresent` (`:1953`) and the `createBaseline` delta loop resolve the unit in Swift.
  - **Coarse-grain residual.** If any provisional bucket in the scan window has `unitKey=''`, the s1 residual is computed at `(category, subcategory)` grain and written with `unitKey=''`. This prevents fake "found" rows on the day of the update.
  - **Feed read.** New multi-path read `fetchJournalSlots(trackedPathIds:since:)`, pre-aggregated in SQL: `GROUP BY unitKey, category, subcategory, source, CAST(strftime('%s', bucketStart)/1800 AS INT)`. It returns Sendable tuples with net and gross per 30-minute slot. Today's `fetchGrowthJournalBuckets` reads one path at a time (`:2282`).
  - **Builder.** `EpisodeBuilder.build(slots:now:calendar:)` groups slots by unit and the local day the run started, splitting at gaps over 30 minutes. It takes the peak slot as the time and flags approximate times. Legacy `''` units become one coarse unit per `(category, subcategory)`, named by subcategory or "Files in <category>", never "Other".
  - **Manager and views.** `GrowthJournalService.changeFeed(trackedPaths:)` runs off the main thread. `MenuBarManager.changeFeed` is recomputed after journal writes (debounced 2 s) and is replaced only when the value differs. `HeaderLevel` (`MenuBarView.swift:110`) gets `.feed` as root. `ChangeRow` uses a 24 px category icon tile, a name with caption, a right-aligned tabular amount, orange for + and grey for −. `CategoryInventoryRow` is `private` (`CategoryGrowthListView.swift:816`): copy its metrics or widen its visibility.
  - **Names in this slice.** Downloads (`~/Downloads/<item>`), Trash, and the named-place fallback.
- **acceptance:**
  - Resolver tests: Downloads item, Trash, fallback "Archive · Documents", a `Library/<Area>/<X>` path giving "X data", case preserved. A guard test fails any name containing a 32-hex run or a dotted bundle id.
  - Builder tests: the 30-minute split, same-day merge, a midnight run staying on its start day, peak time, approximate time for `source='scan'` with an old `observedSince`, merging across tracked paths, legacy coarse units, an injected time zone and a DST day.
  - Upgrade test: v20 data plus a scan after migration produces coarse residuals only, with no unit-keyed "found" rows.
  - A watcher refresh test writes one unit-keyed bucket for a new file under `~/Downloads`.
  - Performance: an XCTest `measure` on a 200k-bucket fixture records SQL read plus build time. The number is reported in the PR, not asserted.
  - **(owner visual check)** The list shows the download under "Today".

### s3: Header with free space and this week, and the categories view
- **outcome:** The header shows the bar, the free space and "this week ±X". Clicking it opens today's category list, biggest first, ending with "Not watched". A read error and a rescan behave honestly.
- **depends_on:** [s2]
- **likely_files:** `Prunr/Views/ChangesHeaderView.swift` (new), `Prunr/Views/MenuBarView.swift`, `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/GrowthJournalService.swift`, `Prunr/Database/DatabaseManager.swift`, `PrunrTests/MenuBarManagerRegressionTests.swift`
- **changes:**
  - Header and levels.
    - `ChangesHeaderView` wraps `driveBarSection` (`:1037`) plus the free / this-week line in one button.
    - The `.categories` level hosts the existing `CategoryGrowthListView`.
    - Retire `overviewHeader` (`:1359`).
  - Window and sort.
    - One window function, `weekStart(now) = startOfDay(now − 6 d)`, is used by both the feed and `recentGrowthStories` (today `Date() − 168 h`, `GrowthJournalService.swift:44`).
    - `inventorySortsBefore` (`MenuBarManager.swift:128`) sorts by size, descending.
    - Rename "Outside Scan Scope" (`MenuBarView.swift:~1090`) to "Not watched".
    - `fetchGrowthJournalTotalsBySubcategory` (`:2358`) stops dropping negative totals.
  - States.
    - `ChangeFeedResult` is `.loaded` or `.failed`; `nil` means unknown.
    - The error view with Retry lives in the list body; the footer is unchanged.
    - During a rescan the previous feed stays.
- **acceptance:**
  - Header number == Σ block-0 slots == Σ category "this week" deltas, in a fixture across several categories and tracked paths.
  - A feed read failure gives `.failed` and the header text "—". It never gives an empty `.loaded`.
  - Starting a rescan does not clear `changeFeed`.
  - Subcategory totals include signed negative values.
  - **(owner visual check)** The slide into the categories view and back, and the drill below it.

### s4: Adaptive rows, "smaller changes", 30 days and calm/day-one states
- **outcome:** Each week shows only its notable changes plus one "in N smaller changes ±X" row. Day labels follow Today / Yesterday / weekday / "3 Oct". History reaches back 30 days, and calm, day-one and short-history states read correctly.
- **depends_on:** [s3]
- **likely_files:** `Prunr/Services/EpisodeBuilder.swift`, `Prunr/Views/ChangeFeedView.swift`, `Prunr/Views/ChangeTailRow.swift` (new), `Prunr/Views/ChangeFeedStateView.swift` (new), `Prunr/Services/GrowthJournalService.swift`, `Prunr/ViewModels/SettingsStore.swift`, `Prunr/Services/DatabaseCleanupService.swift`, `PrunrTests/EpisodeBuilderTests.swift`
- **changes:**
  - **Cutoff.** `threshold(block) = clamp(0.02 × gross(block), 250 MB, 2 GB)`, at most 5 rows per day, tail = exact remainder. The constants live in one place.
  - **Trash.** Trash `+` never becomes a row. A shrink row gets the caption "moved to Trash" when the Trash grew by at least 90% of that row's bytes in the same 30-minute slot.
  - **History.** `historyWindowDays = 30`. Clamp `prune` and both `SettingsStore` clamps (`:105`, `:230`) to at least 30. Call journal pruning from startup maintenance; `cleanupOldCategoryHistory` (`DatabaseCleanupService.swift:732`) prunes only snapshots today.
  - **States.** Day one shows the sentence when there are no episodes and the first complete snapshot is under 24 h old. Calm: no rows in block 0. A short history ends with "Watching since <date>", taken from the first complete snapshot.
- **acceptance:**
  - Cutoff: a low-activity week uses the 250 MB floor, a busy week the 2 GB ceiling, and a mid week exactly 2% (just below goes to the tail, at the line is a row). The 6th change of a day goes to the tail.
  - Σ rows + tail == block net for every block, including blocks with only shrinks.
  - A Trash move fixture: no orange Trash row, a "moved to Trash" caption on the source, and the sum unchanged.
  - Day labels: Today, Yesterday, weekday for days 2-6, "3 Oct" style after that.
  - Retention: buckets older than 30 local days are not read and are pruned at startup. A retention setting of 7 still keeps 30.
  - State tests: day one, calm, short-history marker, and "no change this week" for a true zero.

### s5: Developer names
- **outcome:** Xcode, Docker, node_modules, Python, build and git changes read as "Xcode build files · Prunr", "Docker disk", "node_modules · acme".
- **depends_on:** [s2]
- **likely_files:** `Prunr/Models/UnitRules+Developer.swift`, `PrunrTests/UnitRulesDeveloperTests.swift` (new)
- **changes:**
  - **Rules:**
    - DerivedData `<Name-hash>`, hash stripped → "Xcode build files · Name"
    - Xcode Archives, iOS DeviceSupport, CoreSimulator
    - `Docker.raw`, the `com.docker.docker` container and `~/.docker` → "Docker disk", caption "images, containers, volumes"; `.colima` → "Docker disk · Colima"
    - the outermost `node_modules` (not global packages) → "node_modules · proj"
    - `.venv`, `venv`, `.conda`
    - `.build`, `target`, `build`, `dist` in a developer context → "Build files · proj"
    - `.git` → "Git history · proj"
    - `~/.npm`, `~/.gradle`, `~/.cargo`, `~/.m2`, `~/.cache/<tool>`
    - `~/.ollama/models`, `~/.cache/huggingface`
  - `isBuildArtifactsPath` (`GrowthCategory.swift:410`) is `private static`. Widen it to internal or reimplement it in the pack.
- **acceptance:**
  - One or more passing cases per rule, including hash stripping and the outermost `node_modules`.
  - No path in the developer fixture falls through to the fallback.

### s6: App and cache names
- **outcome:** Library caches, containers, app support, Mail, Messages, Steam and cloud folders read as "<App> cache", "<App> data", "Mail attachments", "Google Drive files".
- **depends_on:** [s2]
- **likely_files:** `Prunr/Models/UnitRules+Apps.swift`, `PrunrTests/UnitRulesAppsTests.swift` (new)
- **changes:**
  - `~/Library/Caches/<id>` → "<App> cache", via `GrowthCategory.cacheApplicationKey` / `cacheApplicationDisplayName` (internal already).
  - `~/Library/Containers/<id>` and `~/Library/Group Containers/<id>` → "<App> data".
  - `~/Library/Application Support/<App>` → "<App> data". Steam `steamapps/common/<Game>` → "<Game> · Steam".
  - `~/Library/Mail` → "Mail" (attachments subtree → "Mail attachments").
  - `~/Library/Messages/Attachments` → "Messages attachments".
  - `~/Library/CloudStorage/<Provider-Account>` → "<Provider> files".
- **acceptance:**
  - Known bundle ids map to names. Unknown ids use the de-dotted last component. No name contains "Library" or a dotted id.

### s7: Media and audio names
- **outcome:** Photos, iCloud Drive, Final Cut and Ableton changes read as recognisable libraries and projects.
- **depends_on:** [s2]
- **likely_files:** `Prunr/Models/UnitRules+Media.swift`, `PrunrTests/UnitRulesMediaTests.swift` (new)
- **changes:**
  - `<X>.photoslibrary` → "Photos library" (· X if not the default name).
  - `~/Library/Mobile Documents/com~apple~CloudDocs/<top>` → "iCloud Drive · top"; other Mobile Documents containers → "<App> in iCloud".
  - `<X>.fcpbundle` → "Final Cut Pro library · X" ("render files" for render and cache subfolders).
  - Ableton: a folder named "<X> Project", or the parent of an `.als` → "Ableton project · X"; the User Library → "Ableton library".
  - `isSampleLibraryPath` (`GrowthCategory.swift:482`) is private: widen it or reimplement.
- **acceptance:**
  - Bundle units take the bundle as root and name.
  - Both Ableton forms resolve to "Ableton project · X".
  - Real path samples from the owner's Mac are included as fixtures.

### s8: Click a change to see where it landed
- **outcome:** Clicking a row opens a page that lists, for that place, the folders and files that changed in a stated time span, each with a signed amount and Show in Finder.
- **depends_on:** [s4]
- **likely_files:** `Prunr/Views/EpisodeDetailView.swift` (new), `Prunr/Views/MenuBarView.swift` (`.episode` level), `Prunr/Services/MenuBarManager.swift`, `Prunr/Database/DatabaseManager.swift` (detail query), `Prunr/Views/ChangeRow.swift` (tap), `PrunrTests/EpisodeDetailTests.swift` (new)
- **changes:**
  - **Why this design.** Per-file data is kept only for the latest 2 snapshots per path (`DatabaseCleanupService.swift:25`, `maxSnapshotEntryPayloadsPerPath = 2`). That is the simplest honest source.
  - **Recent changes.** If the episode started after the older retained snapshot S, compare S with the current working set under the unit root. Aggregate to the first path part below the root, in SQL, using the same path-range pattern as `replaceWorkingSetSubtree`. Show signed deltas, largest first, with the header "Changes in <name> since <S time>".
  - **Older changes.** Show the working set's biggest children under the root, labelled "Biggest items now", plus one line "Details of older changes aren't kept". This reuses the file-drill row style (`DrilldownFileRow` is `private`, `CategoryGrowthListView.swift:980`: widen it).
  - **Finder.** Show in Finder for the root and each item, via `manager.revealInFinder(path:)` (`MenuBarManager.swift:2457`). A missing path shows "No longer on disk".
- **acceptance:**
  - Fixture with two snapshots and changes inside a unit: the compare mode lists the changed children with signed amounts that sum to the root's net since S, and the header names S's time.
  - An episode older than S selects the "Biggest items now" mode with its label.
  - A missing root returns `.missing`, not an empty list.
  - A query failure returns `.failed`.
  - **(owner visual check)** The slide in and back, and the Finder reveal.

### s9: Remove the old overview
- **outcome:** The category-first overview code and its copy are gone, and the marketing screenshot shows the new screen.
- **depends_on:** [s3, s4]
- **likely_files:** `Prunr/Views/MenuBarView.swift`, `Prunr/Views/CategoryGrowthListView.swift` (the "stable" view at `:~787`), `Prunr/Services/MenuBarManager.swift`, `Prunr/Services/MarketingScreenshotRenderer.swift`
- **changes:**
  - Delete the "7-day change" and "Your disk is stable" paths and the change-rank helpers.
  - Keep a `changedCategories` count for the diagnostics report (`MenuBarManager.swift:852-853`), or replace it with episode counts in the same report fields.
- **acceptance:**
  - The build passes, and a test asserts the diagnostics report still has its growth and stable count fields.
  - **(owner visual check)** The marketing renderer output.

### Later (after v1, not needed for the core screen)
- **L1: exact per-change detail for all 30 days.** A `growthJournalDetail` table (per bucket, unit and top 20 children) written on every delta path, so s8 can show exactly what changed in any episode, not only recent ones. Depends on s8.
- **L2: real icons.** `CacheApplicationIconResolver` (`CategoryGrowthListView.swift:1189`) for bundle-id units, and `NSWorkspace.icon(forFile:)` for bundles and download items, cached per unit. Depends on s6.
- **L3: more names.** Logic, iMovie, Music library, TV. Depends on s7.

## Dependency graph

```
s1 ── s2 ──┬── s3 ── s4 ──┬── s8 ── (L1)
           │              └── s9 (also needs s3)
           ├── s5
           ├── s6 ── (L2)
           └── s7 ── (L3)
```

## Parallel batches

Batches are chosen so no two slices in a batch edit the same file.
- **B1:** s1
- **B2:** s2
- **B3:** s3 ‖ s5 ‖ s6 ‖ s7. s3 edits views, the manager, `GrowthJournalService` and `DatabaseManager`. s5-s7 each edit only their own rule file and test file, because s2 created the stubs.
- **B4:** s4
- **B5:** s8. It is not run alongside s4, because both touch the feed and row files.
- **B6:** s9. It is not run alongside s8, because both edit `MenuBarView.swift` and `MenuBarManager.swift`.
- L1, L2 and L3 come after v1. L2 and L3 can run in parallel; each touches its own files.

Order: s1 → s2 → {s3, s5, s6, s7} → s4 → s8 → s9.

## Open questions

None blocking. The owner's Round 2 answers and the orchestrator defaults settle the threshold, week, legacy rows, day labels, panel size, footer, day one, moves and churn. The adaptive cutoff constants (2%, 250 MB, 2 GB, 5 per day) are first values to tune with the owner after s4 ships.

## Risks

- **Residual surprises.** If the watcher missed or over-counted something, a scan writes a "found · daily check" row, or a negative correction, for a place the user did nothing to. Tests cover the arithmetic; real-world frequency is unknown until alpha.
  - The update-day case is handled by the coarse-grain rule.
  - Changes made during a scan are safe. Watcher refreshes wait while a full scan runs (`MenuBarManager.swift:3189`) and replay against the rebuilt working set, so a change the snapshot already caught replays as 0.
- **Unit keys must stay stable.** If a rule edit changes the key for a folder, history within the 30-day window splits into two rows until the old one ages out. Name changes are free; key changes need care. `prunr_unit` must be registered on every pool connection.
- **Bulk changes.** More than 25k paths, or more than 192 refresh targets (`RecentChangeService.swift:56`), escalate to a full scan after up to a 30-minute cooldown. The "triggered by fresh activity" rule keeps those times as known, at up to 30 minutes' error.
- **Row volume.** Place-level keys multiply journal rows. SQL pre-aggregation to 30-minute slots bounds the read; s2 measures the cost.
- **Name quality.** Project inference from parent folders can misname things (generic `build` folders, Ableton naming). Fixtures from the owner's Mac reduce this; the fallback is always a readable folder name.
- **Midnight step.** Counting whole days makes the weekly number move at midnight, when a day leaves the window.
- **Detail coverage.** s8 shows exact changes only since the older of the two retained snapshots, roughly the last 1-2 days. Older rows fall back to current sizes, labelled as such, until L1.
- **iCloud and Trash noise.** iCloud "optimise storage" evictions show as grey rows. Trash moves are captioned but still show as two movements.
- **Width.** Long project names truncate at 320 px. The caption carries the detail, so titles stay short.

## Review notes

Each finding in `prd-review.md` was checked against the code.

**Applied as written:**
- #1 upgrade-day residual, using the coarse-grain rule.
- #2 adaptive cutoff.
- #3 day labels.
- #5 "Docker disk".
- #7 scan start time. Confirmed: `ScanService.swift:193` creates the snapshot at scan start, and the watcher guard is at `MenuBarManager.swift:3189`.
- #8 conflict target and multi-path read. Confirmed at `DatabaseManager.swift:2262` and `:2282`.
- #9 reconciliation first, on the current schema.
- #10 file-safe batches, with per-pack test files.
- #11 private helpers. Confirmed: `isBuildArtifactsPath`, `isSampleLibraryPath`, `CategoryInventoryRow` and `DrilldownFileRow` are all private.
- #12 SQL pre-aggregation as the default.
- #13 unknown vs zero.
- #14 retention wording. Confirmed: `cleanupOldCategoryHistory` deletes snapshots only.
- #15 the whole-day reading of "rolling 7 days", stated as such.
- #16 testable acceptance, with owner-visual checks marked.
- #17 the diagnostics use of `changedCategories`. Confirmed at `:852`; `E2ETestCommand` has no reference to it.
- #18 CloudStorage names and the hash/bundle-id guard test.
- The minor notes: `GrowthBarView`/`SizeBarView` are confirmed gone from `Prunr/Views`, and the bulk-change mitigation moved into Rules.

**Amended:**
- #4 Trash. Trash growth goes to the tail as suggested. In addition, the source row gets a "moved to Trash" caption. Without it, the source's grey shrink would read as freed space, which is the same lie in the other direction.
- #6 detail content. s8 shows real deltas when they exist, by comparing the retained snapshot with the current working set, instead of only "current biggest items". The fallback is labelled. This also fixes the "wrong thing" problem.

**Rejected:**
- Cutting the drilldown (s10) from v1. The owner explicitly wants row click to open where the change landed, so v1 keeps an honest drilldown (s8). Only the exact 30-day detail table moves to L1.
- Cutting the Ableton names from s7. The owner's own Mac has its largest area in audio production (Audio Production 453 GB in the screenshot), and the folder-plus-`.als` rule is cheap and covered by fixtures. Logic and iMovie do move to L3.
- Folding states into s3/s4 was accepted, not rejected: the error and rescan states are in s3, calm, day one and short history in s4.
