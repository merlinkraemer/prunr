# PRD — Signed growth over a fixed window

_2026-08-21 · implementation spec. Outcome of the round-2 brainstorm (`docs/growth-framing-2026-08-21.md`) + three model reviews (Sol, GPT, Kimi)._

---

## 1. Summary

The headline growth number is broken in four verified ways: it's positive-only, it decays
on its own when the journal is pruned, it drops sub-1 MB categories silently, and its
"since" label reads a different clock than its value. This PRD makes the number **signed
net change over a fixed 7-day window**, makes the category rows **decompose that number**,
and moves **urgency to the drive bar** where it belongs. No screen redesign — the panel
looks almost identical; the change is semantic.

**Not in this PRD:** the empty-drilldown bug (tracked separately as a plain bug), cleaning
(gated behind this landing), the `· mostly Tue` temporal suffix (deferred — see §7).

---

## 2. Why

The distrust round 1 couldn't locate has a concrete cause: **the number genuinely changes
when nothing changed.** Three reviewers independently converged on the same fix — split the
two jobs the header was doing. Free capacity answers *should I care*; signed recent change
answers *what happened*. Once the drive bar carries urgency, the headline is free to be
signed, and signed rows that sum to the header make every number on screen inspectable
against the one above it. That inspectability is the trust property; not more-precise
arithmetic.

The enabling fact (verified): **the journal already stores signed deltas.**
`DatabaseManager.swift:2272` writes `deltaBytes != 0` and nets within buckets
(`deltaBytes = deltaBytes + excluded.deltaBytes`). Positive-only lives in exactly **one**
read-side filter. Signed is a one-line change, no migration.

---

## 3. The target

```
┌──────────────────────────────────┐
│  ↑ +4 GB · last 7 days           │  header = signed sum of all category deltas
├──────────────────────────────────┤
│  ████████████░░    462/500 GB    │  drive bar = urgency (live statfs, unchanged)
├──────────────────────────────────┤
│  Caches & System  ↑ +8.2 GB 190GB│  changed rows first, |delta| desc
│  Developer        ↓ −3.1 GB 121GB│  orange up / subdued down
│  Downloads        ↑ +0.9 GB  12GB│
│  Audio Production           538GB│  unchanged rows fall back to size order
│  Other                      546GB│  no delta = sub-floor within window
└──────────────────────────────────┘
```

- `↑ +X` orange (existing treatment) — larger than 7 days ago
- `↓ −X` quiet/neutral (NOT green — down arrow + subdued) — smaller
- no delta — net change under the presentation floor
- header pill: signed sum across **all** categories, so `Caches +8.2 · Developer −3.1 · Downloads +0.9` → header `↑ +4 GB`
- label is the constant string `last 7 days`, never a computed relative date
- **rank: changed rows first by `|delta|` desc; unchanged rows after, by size desc**

---

## 4. Scope — what changes

### Slice 1 — Signed math (the core; ship-alone-able)

The trust fix. Everything downstream depends on it.

| Change | File | Note |
|---|---|---|
| Drop `.filter { $0.deltaBytes > 0 }` — sum signed | `GrowthJournalService.swift:106` | one line; write path already signed |
| Story built from signed total; keep the row when `total != 0` | `GrowthJournalService.swift:105–120` | negative totals now produce a story |
| Header sums **all** categories signed, not just growing | `MenuBarView.swift:1113` (`overallGrowthBytes`) | must equal the visible rows' sum |
| `recentStoryThresholdBytes` (1 MB) becomes a **presentation** floor, not a drop | `GrowthJournalService.swift:8` | see §5 zero-state |

**The invariant.** Header = signed sum of **all** category deltas. Rows use the **same
signed calculation**; sub-floor deltas may be visually omitted. The guarantee is *identical
semantics*, not *visible reconstruction* — see §5.

**Acceptance:**
- Delete 20 GB from category X, add 1 GB to category Y, same window → X row `↓ −20 GB`,
  Y row `↑ +1 GB`, header `↓ −19 GB`.
- Header value equals the signed sum of all category deltas **before presentation
  filtering**.
- A category that grew 8 GB then was cleared 8 GB in-window shows **no delta line** (net 0),
  not `+8 GB`.

### Slice 2 — Fixed 7-day window

Decouples the display window from the retention setting.

| Change | File | Note |
|---|---|---|
| Introduce `displayWindowDays = 7` constant; use it as the story cutoff | `GrowthJournalService.swift:29` | today the cutoff = `retentionDays` |
| `recentGrowthStories(...)` cutoff sourced from display window, not `retentionDays` | `GrowthJournalService.swift:26–39` | retention now only governs pruning |
| Clamp prune retention `≥ displayWindowDays` | `MenuBarManager.swift:1335` + `SettingsStore` | prevents a user retention < 7 truncating on-screen data (the original decay bug at a new address) |
| Replace the `since \(baselineSinceLabel)` render with the constant `last 7 days` | `MenuBarView.swift:1430` | kills the third-anchor label problem |
| Stop feeding `growthBaselineDate` / `comparableBaselineSnapshotId` into the header | `MenuBarView.swift:1123`, `BaselineService.swift:348,1211` | heuristic stays as the drilldown-diff anchor only, off the header |

**Acceptance:**
- Header label always reads `last 7 days`. No relative date anywhere in the header.
- Setting retention to 3 in Settings does not change what the 7-day header counts.
- Advance the clock 8 days with no FS activity: a 16 GB spike from day 1 leaves the window;
  the number drops. This is correct (window moved) — the constant label is what makes it
  read as expected rather than as loss.

### Slice 3 — One list, kill the growing/stable split

One list, change-ranked, with a delta or no delta per row — not two groups.

| Change | File | Note |
|---|---|---|
| Remove `growingCategories` / `stableCategories` partition | `MenuBarManager.swift:187–194` | partition keyed on `recentGrowthStory != nil` — gone |
| Replace `inventorySortsBefore` with change-rank | `MenuBarManager.swift:121–126` | see rule below |
| View renders one section; delta conditional on story presence | `MenuBarView.swift` category list body | |

**Sort rule.** Two tiers:
1. `|delta| ≥ floor` → sorted by `|delta|` descending
2. `|delta| < floor` → all after tier 1, sorted by `currentSizeBytes` descending

Absolute, not positive-only: a `−20 GB` event is real information and must not sink below a
stack of `+50 MB` rows.

**Acceptance:**
- One category list. No "Growing" / "Stable" headers.
- A category that shrank 20 GB outranks one that grew 2 GB.
- A 546 GB category with no movement sits below a 12 GB category that grew 900 MB.
- Unchanged categories retain size order relative to each other.

### Slice 4 — Header interaction + zero state

The pill was a button that called `acceptGrowth()`. With a fixed window there's nothing to
accept.

| Change | File | Note |
|---|---|---|
| Remove pill → `acceptGrowth()` tap | `MenuBarView.swift:1395` | nothing to accept against a rolling window |
| `acceptGrowth` / journal-clear no longer user-facing from header | `MenuBarManager.swift:1452`, `BaselineService.swift:72` | keep the method; Settings "reset data" can still call it |
| Zero state: `|net| < floor` → `0 MB · last 7 days`, no arrow | `MenuBarView.swift:1376+` | replaces the green "Stable" checkmark |

**Acceptance:**
- Header is not a button (or its tap does nothing storage-mutating).
- Net-zero week shows `0 MB · last 7 days` — no arrow, no checkmark, no adjective, and
  never a stale `+X`.
- A week with +5 GB and −5 GB across categories shows `0 MB` in the header **and** both
  signed rows in the list.

---

## 5. Zero-state + floor semantics

One floor, two uses:

- **Row:** `|delta| < floor` → omit the delta line. The row still shows current size.
- **Header:** `|net sum| < floor` → `0 MB · last 7 days`, no arrow (see §6).

The floor is **presentation only** — the underlying signed totals are complete and still
sum correctly. Sub-floor categories are not dropped from the arithmetic, only from the
delta-line render. (Contrast today, where sub-1 MB is dropped from the data entirely and
the category silently becomes "stable.")

**On the residual.** Three hidden categories at +0.8 MB each put +2.4 MB in the header that
can't be reconstructed from visible lines. Accepted deliberately. Do **not** add an "Other
changes" row to close it — that's UI complexity bought to fix a sub-floor discrepancy, and
the floor exists precisely because sub-floor numbers aren't worth screen space. The
trustworthiness claim is that rows and header share one calculation, not that the visible
subset re-adds to the total.

Floor starts at the existing 1 MB. Revisit if rows feel noisy.

---

## 6. Settled

**Sort by change, not size. Not an A/B.** Once the header reads `↑ +4 GB · last 7 days`,
the list's primary question is *what changed*, not *what's biggest* — a huge static
category shouldn't dominate the answer. Rule: **things that changed most are at the top;
things that didn't change fall back to size order.** Absolute delta, so a `−20 GB` event
ranks on its magnitude rather than sinking below `+50 MB` rows. Signed math makes Prunr a
change monitor, and a change monitor benefits from relevance ordering where an inventory
would benefit from stable positions. Current size stays on every row, so the "what's big"
reading isn't lost — it's demoted to context.

**Header strings — three, exactly symmetrical, no adjectives:**

```
↑ +4.2 GB · last 7 days
↓ −4.2 GB · last 7 days
     0 MB · last 7 days
```

No `Stable`, no `Nothing new`, no `No change` — all three are slightly false, since +5 GB
and −5 GB nets to zero while being real activity. A number claims less and is therefore
harder to disagree with.

**Zero-state rendering detail.** Sub-floor nets must render as literal `0 MB`, not as their
formatted value — a 900 KB net formats to `0.9 MB` (or `1 MB` under rounding), which
contradicts the floor. Truncate toward zero below the floor. If the byte formatter can't be
made to emit `0 MB` cleanly, fall back to `≈ 0 MB · last 7 days` rather than showing a
sub-floor number the rows deliberately hide.

### Still open (non-blocking)

- **Down-state visual weight.** Subdued, not green. Confirm the exact treatment against the
  existing orange — and consider subduing it further when the disk is under pressure, since
  shrinkage isn't what demands attention at 12 GB free.

---

## 7. Explicitly deferred

- **`· mostly Tue` temporal suffix.** Solves window-drift legibility (a number shrinking as
  a spike ages out). With signed deltas on every row + a constant label, drift is probably
  legible enough without it. Ship without; add only if the drift actually reads as a bug in
  daily use. Data (per-day buckets) already exists, so it's cheap to add later.
- **Empty-drilldown bug** — separate bug, not a design question. Failures render as facts
  via 9 `catch { return [] }` + 3 silent-failure variants in `BaselineService`. Fix on its
  own track.
- **Cleaning** — gated behind this landing and read-only being trusted.

---

## 8. Dead after this lands (Phase-7 cleanup, not this PRD)

- `growing`/`stable` partition helpers.
- `RecentGrowthStory.duration` and the rate/`displayLabel` fields, once no consumer reads
  them (`CategoryInventoryItem.swift:31–32`).
- `GrowthBarView` / `SizeBarView` — already zero non-preview refs.
- `comparableBaselineSnapshotId` stays (drilldown-diff anchor) but is no longer a header
  input.

---

## 9. Verification

- **Unit:** signed sum regression — build a fixture with +/− buckets across categories,
  assert header == Σ of all category deltas (pre-filter) and that a net-zero category emits
  no story. Include sub-floor categories in the fixture so the residual is exercised.
- **Unit:** window/retention decoupling — set retention < 7, assert the 7-day story count is
  unchanged; advance clock past the window, assert a spike leaves the number.
- **Unit:** sort rule — fixture with a `−20 GB` mover, a `+2 GB` mover, and a 546 GB
  unchanged category; assert order is `−20`, `+2`, then the static one. Assert two
  sub-floor categories keep size order relative to each other.
- **Manual (author):** delete 20 GB / add 1 GB, confirm `↓ −19 GB` header and the two signed
  rows; leave idle a week, confirm the number only moves as buckets age out, label constant.
- Build + lint. No browser/self-verify (per project rules).
