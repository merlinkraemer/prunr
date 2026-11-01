# Checkpoint table for the change list - design (2026-10-31)

Status: proposal, needs Merlin's go (schema change). Code read on `drain/integration-2026-10-31` (migrations up to v26). Evidence from the read-only snapshot `prunr-2026-10-30.db` via `scripts/audit/replay.py`.

## Problem

Rows of slowly growing places move as the 30-day window slides, with no filesystem activity: the row jumps a day, changes its amount, or disappears.

## Root cause

`EpisodeBuilder.build` keeps a running count per place and emits a row whenever |count| reaches 1 GB, then resets it. The count is not stored: every build starts it at zero on the oldest shown day (`windowStart` = today - 29). `changeFeed` reads slots only since that day, and `prune` deletes buckets older than it. So each morning one day drops out of the count, and every row whose count was still carrying that day's bytes is computed from a different starting point.

Synthetic case (PRD acceptance "250 MB/day"): a place growing 250 MB every day gets rows on days 4, 8, 12 ... of the window. Next day the window starts one day later, so every row moves to days 5, 9, 13 ... Every row shifts by a day, every day.

### Evidence from the snapshot

The snapshot holds 15 days (15-29 Oct), so the slide starts on 14 Nov when 15 Oct leaves the window. Replaying `build_feed` for `now` = 12 Nov ... 29 Nov: 15 places change rows that are still inside the window. Day nets after run grouping (GB):

| Place (anonymised) | 15 | 16 | 17 | 18 | 26 | 27 | 28 | 29 |
|---|---|---|---|---|---|---|---|---|
| A: browser app-support folder | +0.08 | -0.58 | -0.78 | +0.03 | -0.93 | -0.06 | +1.25 | +0.06 |
| B: dev tool's dot folder in home | +0.11 | +0.16 | +0.13 | +0.08 | +2.60 | +0.51 | +0.36 | +0.52 |
| C: browser cache folder | -0.10 | +0.13 | -0.17 | +0.21 | -4.69 | +0.39 | +0.10 | +0.11 |

Rows of A on consecutive days:

| View date | Window starts | Rows |
|---|---|---|
| 13 Nov | 15 Oct | 17 Oct -1.28 |
| 14 Nov | 16 Oct | 17 Oct -1.36 |
| 15 Nov | 17 Oct | 26 Oct -1.68, 28 Oct +1.19 |
| 16 Nov | 18 Oct | none |

Row B on 26 Oct reads +3.09, +2.98, +2.82, +2.69, +2.60 GB on 13-17 Nov as the small drip of 15-18 Oct drops out. Its 29 Oct row ("a little each day since 27 Oct", +1.39) vanishes on 26 Nov. Row C on 26 Oct flips between -4.62, -4.52, -4.65, -4.48, -4.69.

Control: replaying the same data with the count carried from the first day ever and rows shown only for days in the window gives 0 in-window row changes over the same 18 days.

## Design: carry the count across the window edge

Store each place's running count at the prune cutoff, so the count a build starts with is the one it would have had with full history.

### Table (migration v27, on top of v26)

```sql
CREATE TABLE growthJournalCheckpoint (
    unitKey TEXT PRIMARY KEY,        -- UnitResolver key, same as growthJournalBucket.unitKey
    asOf DATETIME NOT NULL,          -- prune cutoff: state after every bucket before it
    countBytes INTEGER NOT NULL,     -- EpisodeBuilder running count (signed, Trash: shrinks only)
    grossBytes INTEGER NOT NULL,     -- running gross for the next row
    countStartDay DATETIME NOT NULL, -- local day the count started (buildingSince)
    lastActiveDay DATETIME NOT NULL  -- newest day with a non-zero day net folded in
) WITHOUT ROWID;
```

Keyed by `unitKey` only, because `EpisodeBuilder` groups slots by `unitKey` across tracked paths and `pruneGrowthJournalBuckets` is global. Only non-zero counts get a row. `growthJournalDetail` needs nothing: it is drilldown detail, not part of the count.

### Write: in prune

`pruneGrowthJournalBuckets(olderThan: cutoff)` does, in its one write transaction:
1. Read the current checkpoint rows and every bucket with `bucketStart < cutoff`, as slots.
2. Fold them with the builder's own fold (`EpisodeBuilder.fold`, shared, pure): seed each place from its checkpoint, add its days oldest first, reset at 1 GB exactly as `build` does.
3. Replace the checkpoint rows with the result (`asOf = cutoff`), drop zero counts, then delete the old buckets and detail as today.

The cutoff stays a local midnight (`max(retentionDays, 30)` days back). A run that crosses the cutoff midnight is split: its head goes into the carry, its tail stays and counts on the cutoff day. Builds already see it that way, because `changeFeed` reads from the same midnight, so nothing shown changes.

### Prune the checkpoint

- Drop a row when `asOf - lastActiveDay > 90 days`: a place quiet for a quarter starts from zero. Bounds growth from places that no longer exist. Cost: a woken place's next row can be up to 1 GB later.
- Every path that clears the journal clears checkpoints in the same transaction: `deleteGrowthJournalBuckets(trackedPathId:)`, `deleteAllGrowthJournalBuckets`, `clearRealtimeData`, and any future migration that runs `DELETE FROM growthJournalBucket`. Add it next to `deleteJournalDetail`. The per-path clear removes all checkpoints (keys are not per path); other paths' rows may shift once. Rare, acceptable.

### Read: in EpisodeBuilder

- `changeFeed` fetches all buckets (prune already bounds them to the cutoff) plus the checkpoint rows, and passes `carries: [String: PlaceCount]` to `build`.
- `build` seeds each place's `count`, `gross`, `countStart` from its carry, folds every day oldest first, and emits rows only for days `>= windowStart`. Days before the window (retention > 30, or before today's prune ran) fold silently. `weekNetBytes` is unchanged.
- `buildingSince` can now predate the window ("a little each day since 2 Sep" on a list that starts 2 Oct). Honest, but user-visible copy: Merlin's call (see open questions).

### Storage

Snapshot: 906 places in 15 days, 858 of them with a non-zero carry at the 30 Oct cutoff (most places never reach 1 GB). Row about 71 B key + 5 numbers, about 120 B in a WITHOUT ROWID table: roughly 100-110 KB, rewritten once a day. The journal itself writes about 340 buckets a day; the database is 33 MB.

## Alternatives

| Option | Schema | Fixes drift | Trade-off |
|---|---|---|---|
| **Checkpoint table (rec)** | v27 table | Yes, exactly (0 changes in replay) | One table, fold shared with build, clear paths must remember it |
| No schema: count resets at fixed calendar blocks (week or month), window snaps to block start | None | Yes inside a block | Breaks the PRD rule "nothing resets at week ends"; growth under 1 GB per block never gets a row (100 MB/day: today a row every 10 days, with weekly blocks never); window is 30-36 days |
| No schema: anchor each place's count at its first growth day in the window | None | No | The first growth day in the window is itself a function of the window edge; the drift only moves |
| Longer retention (e.g. 90 days), fold days 31-90 silently | None | Mostly | Drift moves to the 90-day edge and still hits exactly the slow growers (under 1 GB per 60 days); about 3x journal rows and 3x slots per `changeFeed` read |
| Freeze emitted rows in an episode table | Larger table | Yes | Stores titles, owners, amounts that names, keys and owner rules change later; invalidation and duplicated builder logic |

## Recommendation

Checkpoint table, migration v27. It is the only option that keeps the current row rule and makes every past row stable for good, at about 100 KB and one extra step in an existing prune.

## Open questions for Merlin

1. Schema go for v27 (AGENTS.md: data/schema must ask).
2. `buildingSince` older than the window: show the real date (rec), or clamp the caption to the window start.
3. Stale-carry expiry: 90 days (rec), or keep carries forever.

## Implementation slices

1. **Pure fold** - extract `PlaceCount` and `EpisodeBuilder.fold(carry:days:)` from `build`; `build(carries:)` emits only days in the window. Tests: 250 MB/day for 40 days gives identical rows for each consecutive `now`; place A's day nets reproduce the table above without carry and are stable with it; Trash carry counts shrinks only; count back to 0 resets `countStart`; `buildingSince` before the window.
2. **Migration v27 + DB API** - table, `fetchJournalCheckpoints`, `replaceJournalCheckpoints`, clearing in all journal-clear paths. Tests: migrates a v26 database; each clear path empties the table; per-path clear.
3. **Prune writes the checkpoint** - fold and replace inside the `pruneGrowthJournalBuckets` transaction, stale expiry. Tests: for several `now` values, build after prune equals build on the unpruned journal; pruning twice on one day is a no-op; a run crossing the cutoff counts once; expiry after 90 quiet days.
4. **Read path** - `changeFeed` drops `since: windowStart`, passes carries; `scripts/audit/replay.py` mirrors carries and gains a window-slide check. Tests: `changeFeed` integration on a fixture journal over 35 days; perf on the real snapshot via `mac-queue` (fetch now covers retention, not 30 days).

Slices 1 and 4 touch `EpisodeBuilder`; 2 and 3 are DB only. Order: 1, 2, 3, 4; 1 and 2 can run in parallel. No UI change unless question 2 picks the clamp.
