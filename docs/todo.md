# Todo: Growth UX Redesign

Goal: make the delta-tracker mental model legible. Growth = total accumulation
since a dated baseline anchor, reset on the user's terms, with a footer that is
quiet when healthy and loud when broken.

## Background (why)

- Per-category growth is currently the *single best contiguous burst within 24h*
  (`GrowthJournalService.buildStories`), gated by `recentStoryWindow = 24h`.
  Older or spread-out growth never shows → looks "Stable" when it isn't.
- The journal is cleared on Accept (`BaselineService.acceptGrowth` → line 75), so
  every retained bucket already means "growth since last accept". The 24h window
  and best-segment scoring are legacy restrictions fighting that fact.
- The baseline (reference point) is invisible, so "+X GB" has no "since when"
  anchor. "Dismiss" reads as throw-away, not "set new baseline".
- Footer shows a relative timestamp that looks identical whether the engine is
  alive or dead — the exact reason the root-scope tester saw "stable" not "broken".

## Phase 1 — Growth = total since baseline (drop 24h window)

- [ ] `GrowthJournalService.buildStories`: replace best-segment selection with a
      per-category **sum of all positive bucket deltas** over the retained journal.
      - story.deltaBytes = Σ positive deltas
      - story.startedAt = earliest positive bucket, endedAt = latest
      - keep the 1 MB (`recentStoryThresholdBytes`) floor on the total
      - delete `recentStoryWindow` and the `recentSegments` filter (line 106)
      - `score()` / segment plumbing no longer needed for selection; keep
        `buildSegments` only if still used for span, else remove
- [ ] Verify partition (`growingCategories`/`stableCategories`) still keys off
      `recentGrowthStory != nil` — no change needed, behavior now = "any growth
      since baseline" instead of "burst in last 24h".
- [ ] Drop the per-category duration label: `CategoryGrowthListView` line 910
      `+X · <displayLabel>` → just `+X`. The baseline "since <date>" in the top
      bar is the single time anchor for all categories.

## Phase 2 — Surface the dated baseline + relabel Reset (top bar)

- [ ] Thread a baseline date through `InventoryAggregationResult`:
      add `baselineSnapshotDate: Date?`, computed in
      `BaselineService.getInventoryWithTrends(trackedPaths:)` as the **earliest**
      baseline-snapshot `createdAt` across enabled paths.
- [ ] Store it on `MenuBarManager` (set where `latestSnapshotDate` /
      `baselineSnapshotIdsByPath` are consumed); expose `growthBaselineDate: Date?`.
- [ ] `MenuBarView.overviewHeader` (growth > 0 branch):
      `↑ +X GB · since <date>`  + button relabeled **Reset** / **Resetting**.
      - date format: "today" if same calendar day, else short "Jun 1"
      - update `.help(...)` text to match "Reset" wording
- [ ] Keep the "Set as New Baseline!" flash and the "Stable" pill as-is.

## Phase 3 — Footer = health line (quiet when healthy, loud when broken)

- [ ] Add a `growthTrackingHealth` computed state on `MenuBarManager`:
      - `.refreshing`  (isBackgroundFullScanRunning)
      - `.changesPending` (pendingDirtyReason/hasPendingRecentChanges)
      - `.notTracking` — no realtime watcher AND reconciliation gated off
        (the root-scope broken case)
      - `.healthy`
- [ ] `MenuBarView.footerStatusText`: drive off `growthTrackingHealth`.
      - healthy → quiet (no timestamp; subtle/empty)
      - notTracking → `Not watching — needs Full Disk Access` (actionable)
      - keep update-available + refreshing + changes-pending branches
      - drop the always-on "Updated X ago" / "No changes detected" timestamp

## Out of scope here (separate decision)

- Re-enabling realtime/periodic growth for root `/` scope
  (`shouldAutoWatchTrackedPath` exclusion + `isPermissionConfirmedForProtectedTraversal`
  gates on reconciliation). Phase 3's `.notTracking` footer makes the broken state
  visible; the actual re-enable is a follow-up with its own CPU/permission tradeoff.

## Verification

- [ ] `make build`
- [ ] `make test`
- [ ] Manual: grow a tracked folder over >24h span → top bar shows cumulative
      total + "since <date>"; Reset clears it and re-anchors the date to today.

## Review

Implemented all three phases. `make build` ✓, `make test` ✓ (67 tests).

- **Phase 1** — `GrowthJournalService.buildStories` now sums all positive journal
  deltas per category (≥1 MB floor) instead of picking the best 24h burst.
  Removed `recentStoryWindow`, `buildSegments`, `score`, `formattedDuration`,
  `GrowthSegment`. Per-category list drops the `· <duration>` suffix.
- **Phase 2** — `InventoryAggregationResult.baselineSnapshotDate` (earliest
  baseline `createdAt` across paths) via new `DatabaseManager.fetchSnapshotCreatedAt`.
  Threaded through `applyInventory(baselineDate:)` → `MenuBarManager.growthBaselineDate`.
  Top bar: `↑ +X · since <date>` + button relabeled **Dismiss → Reset**.
- **Phase 3** — `MenuBarManager.isGrowthTrackingActive` (false only when a
  baseline exists but nothing is watched AND reconciliation is gated off).
  Footer is health-driven: green dot + "Tracking" when healthy, orange
  "Not tracking — needs Full Disk Access" when broken. Dropped the relative
  timestamp entirely; removed unused `relativeTime(from:)`.

### Known minor
- Brief footer flash possible if read between baseline load and watcher
  configuration (watchedPaths momentarily empty). Transient; resolves on next
  reactive update.

### Manual checks
- Grow a tracked folder over a multi-day span → top bar shows cumulative total
  + "since <date>"; Reset re-anchors the date to today and clears growth.
- Set scan path to `/` without Full Disk Access → footer shows
  "Not tracking — needs Full Disk Access" instead of looking stable.
