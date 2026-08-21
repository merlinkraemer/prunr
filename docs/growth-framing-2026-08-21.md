# Prunr — What should the growth number *mean*?

_2026-08-21 · second round, written for cross-model A/B review. Self-contained._
_Companions: `docs/ux-review-brief-2026-08-21.md` (round 1), `docs/trust-plan-2026-08-21.md` (implementation plan)._

---

## 0. How to use this doc

Round 1 asked "why doesn't the author trust the numbers." That produced a plan. Working
through that plan surfaced a question the plan had assumed away: **what is the headline
growth number actually measuring, and is that the right thing to measure?**

The author is genuinely undecided here — this is not a proposal seeking ratification.
Sections 1–3 are facts. Section 4 is a decision log including two reversals, kept
deliberately, because the reversals are the most informative part. Section 5 is the open
fork. Section 6 is what reviewers should argue with.

**Disagree freely.** The last round's most useful outputs were the corrections.

---

## 1. What Prunr is

macOS menu-bar utility. SwiftUI + AppKit panel, GRDB/SQLite, FSEvents-driven refresh plus
periodic full scans. Solo dev, open alpha, ~500 Swift files.

The differentiator vs. DaisyDisk / GrandPerspective is the **diff over time** — "what got
bigger," not "what is big."

Panel, top to bottom: header pill (`+X GB` growth, or green "Stable") → drive bar (live
`statfs`) → category list, split into "growing" and "stable" groups → drilldown to files →
footer status line.

---

## 2. The job-to-be-done, in the author's words

> "I get error disk is full, I be like I didn't install anything, what's going on, I have
> to either remember or go through dirs etc to find out where the storage went. Prunr
> should be the simple menubar thing to open to check what's going on quickly."

And on the pill specifically:

> "This is for what ate my storage. It's a glanceable *do I need to clean anything*, not
> the reverse."

These two quotes are the spec. **Note the tension between them** — it's the subject of §5.
The first is a *recency* question asked in a panic. The second describes a
standing alarm indicator.

---

## 3. What the number is today (verified against the repo)

The header pill renders `+X GB` next to a relative label like `since 3 hours ago`. Those
two halves come from **different anchors**:

| Half | Anchor | Path |
|---|---|---|
| the number | since the last manual Accept/Reset — journal buckets are deleted at that event | `MenuBarView.swift:1113` → growth journal stories |
| the label | date of the previous *comparable snapshot*, chosen by an entry-count heuristic | `growthBaselineDate` → `BaselineService.comparableBaselineSnapshotId:348` |

`comparableBaselineSnapshotId` walks back from the latest snapshot and returns the first
with >100 entries and ≥50% of the latest entry count. That is "the previous scan," not
"your baseline." So **`+4 GB since 2 hours ago` can mean 4 GB accumulated over three
weeks, labeled with a two-hour-old scan timestamp.**

Three further defects in the same number, all verified:

- **It discards shrinkage.** `GrowthJournalService.swift:107` filters `deltaBytes > 0`
  before summing. A category that grows 8 GB at noon and is cleared at 3pm reads `+8 GB`.
- **It decays on its own.** `MenuBarManager.swift:1335` *prunes* (deletes) journal buckets
  at `categoryHistoryRetentionDays` (default 30), while the baseline is cleared only on
  Accept/Reset and can be far older. Growth older than the retention window is
  unrecoverable, so the headline number shrinks with zero filesystem activity.
- **Sub-1 MB categories get no story at all** (`GrowthJournalService.swift:8,112`), and
  the UI partitions on story-existence (`MenuBarManager.swift:187`), so they silently land
  in "stable."

Net: the number is not signed, not complete, not stable over time, and its label describes
a different clock than its value. This is a sufficient explanation for "I don't trust it
and I can't say why" — *the number genuinely changes when nothing changed.*

---

## 4. Decision log from the working session

Settled, with reasoning:

| # | Question | Answer | Why |
|---|---|---|---|
| 1 | Is the pill a session delta, a managed baseline, or "since last scan"? | **Managed baseline** (= current intent) | A session delta resets constantly, so a 200 MB/day leak is invisible every session and 6 GB a month. "Since last scan" is an implementation detail, not a user concept. |
| 2 | What happens when the baseline gets old? | **Leave it now; cleaning becomes the reset later** | Don't invent an expiry policy with an arbitrary threshold. Cleaning (the next feature) is the natural re-baseline moment. |
| 3 | Pill when you delete 20 GB? | **No negative pill** — then **reopened**, see below | "Glanceable do I need to clean anything, not the reverse." |
| 4 | What does the category list rank by? | *unresolved* — see §6 | |

### The two reversals (kept on purpose)

**Reversal A — netting.** The author accepted "no negative pill," then immediately
pushed back:

> "But is it actually a good idea to have +1 GB −19 GB = stable? This is the sort of thing
> that I don't know how to handle because it doesn't actually show what actually happened."

This exposed that two different nettings had been conflated:

- **Within a category** (Caches +8 GB then −8 GB) — netting is pure gain. The category is
  genuinely flat; today it reads `+8 GB`, a false alarm.
- **Across categories** (Downloads +1 GB, Trash −20 GB) — netting destroys information.
  Downloads *did* accumulate 1 GB; emptying the Trash is an unrelated event and summing
  them is meaningless.

Provisional resolution: **pill = sum of net-positive categories** (never negative, but
honestly so — "how much accumulated" is a genuinely one-directional question);
**rows = signed both directions**. The `+1 / −19` case then reads `+1 GB` at the top and
`−20 GB` on the Trash row.

**Reversal B — the author then reopened negatives anyway:**

> "The growth number might actually be better with negative. The core question this app
> should solve is what is currently happening with my storage."

That reframing — *what is currently happening*, rather than *what has accumulated* — is
what opens §5. It is bidirectional in a way the alarm framing is not.

A third, separate observation from the author: when told the green "Stable" state would
show after freeing 30 GB, the objection was that the *word* is wrong, not the logic.
"Stable" is a claim about the machine. Proposed replacement: **"Nothing new."**

---

## 5. The open fork

Both options assume the §3 defects are fixed regardless. This is only about what the
number *means*.

### Option A — Managed baseline (today's intent, done properly)

`+47 GB since you last reset`. User-controlled mark, cleared explicitly or by a future
cleaning action.

- Supports deliberate "reset and watch this" workflows.
- Requires solving baseline-age: a four-month-old mark yields a big number that stops
  moving meaningfully, and four months of normal accumulation buries the 30 GB that
  appeared last Tuesday.
- Retention and baseline age become coupled settings that cannot be independent.

### Option B — Rolling window

`+12 GB · last 7 days`. Fixed window, no user concept to maintain.

- Directly answers the panic in §2.
- **Dissolves the decay bug structurally** — a fixed display window and a retention window
  become the same window, so pruning can no longer eat data that's still on screen.
- The label becomes a constant phrase rather than a computed relative date. Argument:
  "last 7 days" is read once and learned; "since 3 hours ago" must be re-read and
  re-interpreted on every open, and silently means something different each time.
- Loses the deliberate reset-and-watch workflow.
- A slow leak surfaces as a small number every week rather than one large number once —
  which may be better (steady signal) or worse (never crosses an alarm threshold).

Sketch for B:

```
┌──────────────────────────────┐
│  ↑ 12 GB    last 7 days      │
├──────────────────────────────┤
│  ████████░░░░░  412 / 500 GB │
├──────────────────────────────┤
│  Grew in the last 7 days     │   ← section header carries the clock
│   Developer      +8 GB  71 GB│
│   Caches         +4 GB 228 GB│
│                              │
│  Everything else             │
│   Documents             42 GB│
└──────────────────────────────┘
```

Flat week: `✓ No growth · last 7 days`.

Sub-question if B wins: **is the window a setting?** Provisional recommendation is no —
ship 7 days fixed. A setting is a way of not choosing, and once configurable the label
must be read carefully again because it may differ from every screenshot and support
thread.

---

## 6. What reviewers should argue with

1. **A or B — or is the fork false?** Is there a formulation that answers the disk-full
   panic *and* supports deliberate tracking without becoming two numbers in one header?
   (Two numbers is the failure mode this whole effort is trying to escape.)
2. **Is the pill/rows split coherent?** Positive-only alarm on top, signed ledger below.
   Or does a user who freed 30 GB and sees a pill that isn't negative simply distrust the
   pill again?
3. **Is "growth over time" even the right primary frame?** The author's own signal — the
   growth rate "not really helping" — is evidence the diff framing may be over-weighted.
   The alternative is leading with DaisyDisk-style "what's big + drillable" and treating
   growth as a badge and a sort order. Round 1 reviewers split on this.
4. **What should the category list rank by?** Biggest-first (a "what's big" list, growth
   as badge) vs. biggest-grower-first (decomposes the pill). The current
   growing/stable group split is a third option that costs vertical space on the
   "stable" half — space spent listing things explicitly defined as not-news.
5. **Is a threshold needed at all?** Today sub-1 MB categories vanish entirely. If growth
   becomes signed and complete, does every category get a row, or does an alarm indicator
   still need a floor to stay glanceable?

---

## 7. Explicitly out of scope for this round

- **The empty-drilldown bug** (non-zero header → "No files found"). The author's position:
  "that's just a bug, it doesn't matter for planning." Failures currently render as facts
  because `BaselineService` has 12 `catch { return [] }` blocks. It gets fixed; it is not
  a design question.
- **Dead code** — `GrowthBarView` / `SizeBarView` have zero non-preview references.
- **Cleaning** — gated behind read-only being trusted, which is what this doc is about.

---

## 8. One paragraph for a cold reviewer

Prunr is a macOS menu-bar tool for seeing what's growing on disk. Its headline number is
`+X GB` growth since a baseline. That number is currently positive-only (shrinkage is
discarded before summing), decays on its own (the journal is pruned at 30 days while the
baseline can be older), drops categories under 1 MB entirely, and pairs its value with a
"since" label computed from a completely different anchor. Those are being fixed. The open
question is what the number should mean once it is correct: a **user-managed baseline**
that supports deliberate tracking but goes stale, or a **fixed rolling window** that
directly answers the app's actual trigger moment — "disk is full, I didn't install
anything, where did it go?" — at the cost of the reset-and-watch workflow. Secondary and
unresolved: whether the alarm should ever go negative, and whether growth deserves to be
the primary frame at all rather than a badge on a size-ranked list.
