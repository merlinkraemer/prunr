# R7 — the simplest honest model: "every gigabyte gets a row"

## The model in plain words

**A row** is one place (app, project, library, download, named folder) and the space it took or gave back,
under the day it happened. Icon · name + caption · signed amount. Same row shape as the shipped app.

**The one rule.** A place gets a row each time it has gained (or lost) another 1 GB since its last row.
- A big event (Docker pull +31 GB) crosses 1 GB the same day → one row that day, caption = clock time.
- Slow growth (Mail +250 MB/day) crosses 1 GB on day 4 → one row that day, amount = everything since the last
  row (+1.0 GB), caption = "a little each day since Fri 2 Oct". Day 8 it crosses again → next row.
- Nothing is reset at week boundaries; the counter per place just keeps running.
- Caption: clock time when more than half of the amount moved in one go that day; otherwise "a little each
  day since <date>"; "found by scan" when the crossing came from the daily scan, not the watcher.
- Shrink rows are grey (−4 GB). Trash growing is a move, no row; "Trash emptied" is a grey row.
- Days with no row do not appear. Labels are real dates: "Wed 7 Oct". No week labels, no sums per day.

**Honesty.** The header ("this week +48 GB") is the measured fact. The rows show every change that reached
1 GB; what is missing is, by construction, under 1 GB per place and still counting up. No "smaller changes"
line is needed because the gap is explained by the rule itself, and it closes as soon as a place crosses 1 GB.
When the last 7 days hold no row, one muted line says "Nothing over 1 GB since 28 Sep" (the rule, dated),
so the +32 MB header and a list that starts two weeks back are not read as stale.

## Why this is the simplest

- One number (1 GB), one row kind, one sentence: "every time a place has used another gigabyte, it gets a row
  on that day." A user can predict what will appear and when.
- It answers the owner's worry without a new concept: creeping growth and many-small-files growth surface
  through the same rule as big events, just a few days later, with a caption that says so.
- No adaptive cutoff, no per-week tail, no row cap, no "quiet/busy week" wording, no roll-ups, no ranges
  as a separate row type. The list is a plain chronological ledger.
- Orange only for growth ≥ 1 GB; under this rule every growth row qualifies, so orange = "this ate space".

## Dropped vs the PRD (docs/core-screen-episodes-prd-2026-10-11.md, Rules)

- Adaptive cutoff (2% of week, 250 MB–2 GB clamp) → fixed 1 GB.
- "At most 5 rows per day" → no cap; the list scrolls.
- Weekly "in N smaller changes" row and "rows + tail = header" invariant → header is the fact, rows are
  "everything ≥ 1 GB"; the remainder is bounded by 1 GB per place.
- "Nothing notable changed this week" → "Nothing over 1 GB since <date>", shown only when 7 days have no row.
- "Churn gets no line": a place that goes +1.2/−1.2 GB daily now gets a row for each crossing. Accepted; true.
- Kept: per-place naming, Trash rules, "found by scan", 30-day history, header, footer, day grouping.

## Code impact (EpisodeBuilder, 30-min slots per place)

1. Replace the per-day episode + cutoff pass with a per-place running accumulator: `net since last row`,
   `start slot`, `largest slot`. Walk slots in time order; when |net| ≥ 1 GB, emit a row dated by that slot's
   day with the amount = net at end of that day, then reset.
2. Caption from the accumulator: same-day start or largest slot > ½ net → clock time of largest slot; else
   "a little each day since <start day>"; scan-sourced slots set "found by scan".
3. Delete: weekly gross/2% cutoff, clamp, 5/day cap, tail-row aggregation, week grouping. Day grouping stays.
4. Accumulator state must persist across scans/launches (one small table: place, net, start, largest).
