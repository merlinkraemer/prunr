# Prunr — UX Review Brief

_2026-08-21 · written for cross-model A/B review. Self-contained: a reader needs no repo access._

---

## 0. How to use this doc

This is a briefing for critiquing Prunr's UX. It describes what the app is, how it
works today, four unresolved problems the author is stuck on, and one proposed
direction. If you are a model reviewing this: **you may disagree with §5 (the proposed
direction).** It is separated from §4 (the problems) on purpose. Argue with the
diagnosis, propose alternatives, or reprioritize — don't just ratify.

The five open questions in §6 are the ones that actually matter.

---

## 1. What Prunr is

A macOS **menu-bar utility for seeing what is growing on disk.** Not a disk-usage
visualizer (that's DaisyDisk / GrandPerspective) — the differentiator is the **diff over
time**: "what got bigger since I last looked," not just "what is big right now."

- **Platform:** macOS menu-bar app (SwiftUI + AppKit panel). Solo dev, open alpha.
- **Storage:** local SQLite via GRDB. Snapshots of the filesystem tree are stored and
  compared.
- **Freshness engine:** FSEvents watches the scan scope and triggers incremental
  refreshes; periodic full scans rebuild the whole tree.
- **Stage:** alpha, ~500 Swift files, shipping via GitHub releases + Sparkle appcast.

### Core UX (top → bottom of the panel)

1. **Header** — a status pill. Either `+X GB` (growth since baseline, click to reset
   baseline), or a green **"Stable"** checkmark. A small "since 3 hours ago" sits next to
   the growth pill.
2. **Drive bar** — one horizontal bar: used vs. free space, with colored category
   segments inside the used portion. Sourced from live `statfs`.
3. **Category list** — rows like _Caches & System · 228 GB_, _Developer · 71 GB_, each
   with a growth indicator. Split into "growing" and "stable" groups. Tap a row to drill
   down.
4. **Drilldown** — category → subcategories → individual files/contributors. This is the
   audit trail: where a big number is supposed to decompose into real, named files.
5. **Footer status text** — a single line that shows one of: update-available banner /
   "Not tracking — needs Full Disk Access" / "Refreshing" / "Changes pending" / "X GB
   outside scan scope" / empty.
6. **Refresh button** — icon in the header; runs a "lightweight refresh without a full
   scan."

### The intended job-to-be-done

Open the menu bar → immediately see whether disk grew and _what_ grew → drill into the
culprit → (future) clean it from inside the app.

---

## 2. Where it works

- The drive bar + category breakdown reads clearly and is roughly ~80% trustworthy to the
  author.
- The FSEvents-driven freshness means the panel is usually current without manual action.
- The growth-since-baseline pill is a genuinely novel framing vs. competitors.

---

## 3. Context that matters for the critique

**There are five distinct "truth sources," each measured on a different clock, and the UI
renders them in identical typography with no labels:**

| # | Source | What it feeds | Clock |
|---|--------|---------------|-------|
| 1 | `statfs` free space | drive bar | **now**, authoritative |
| 2 | Snapshot inventory | category sizes (228 GB, etc.) | as of last **full scan** |
| 3 | Baseline delta | the `+X GB` header pill | since a **user-resettable baseline** |
| 4 | Growth journal (FSEvents minute-buckets, retention-windowed) | per-category "recent growth" | **rolling window** |
| 5 | Drilldown contributors | files inside a category | **resolved on demand**, partly live FS |

A single category row shows **#2 for its size and #4 for its growth**, on one line, in one
font. Those two numbers were captured at different times by different mechanisms, so they
_can_ legitimately disagree — and the UI asserts a coherence that doesn't actually exist.

This is the thread that ties all four problems below together.

---

## 4. The four problems (author's words, sharpened)

### Problem 1 — Background scans are opaque

Autoscans run in the background. On a large scan scope, the footer shows "Refreshing" (a
pulsing dot) or "Changes pending" for a long time with **no indication of what's happening
or how long it'll take.** Author considered a percentage / progress bar but isn't sure
it's even warranted on the main view.

_Technical note:_ a percentage already exists internally but never reaches the UI. Its
formula is a time-extrapolated estimate clamped to a **3% floor and 97% ceiling** — i.e.
it would jump to 3%, crawl, then park at 97%. The footer status line is a 5-way priority
chain competing for one slot, where the transient "Changes pending" outranks the standing,
useful "X GB outside scan scope."

### Problem 2 — The numbers aren't trusted

Author doesn't fully trust the displayed numbers but can't articulate why. Symptoms:

- **Categories sometimes open empty** — a category header says 228 GB, you tap in, and the
  drilldown shows "No files found." The app contradicts itself on screen.
- **Growth rate isn't helping** — the rate/trend abstraction doesn't improve understanding
  vs. a plain "GB free" number or a DaisyDisk-style "what's big" list.
- The distrust is **vague and unlocatable** — nothing concrete to point at, which is
  itself the tell.

_Technical notes:_ (a) the growth/size bars have a hardcoded `minimumWidth = 0.2`, so a
10 MB bar renders at 20% the width of a 5 GB bar — a visual off by up to ~500×. (b)
"loading," "genuinely empty," and "lookup failed" all collapse into the same empty-tray
state, so you can't tell which one you're seeing. (c) shrinkage (freeing space) renders as
the same green "Stable" checkmark as "nothing happened." (d) baseline timing labels include
vague strings like "recent" / "just now."

### Problem 3 — Read-only must be trustworthy before cleaning ships

The next big feature is **cleaning things from inside the app** (caches, downloads, trash,
etc.). But author won't build it until read-only is actually trusted: _"if I'm not
completely trusting the numbers I wouldn't use it."_ Author notes they wouldn't
_rationally_ need 100% certainty to act — but the current UI makes them feel they do.

This is the key insight: **the UI is manufacturing a demand for certainty that the task
doesn't inherently require.** The goal isn't more-precise numbers — it's a UI that earns
enough trust that the user stops feeling they must independently verify.

### Problem 4 — The refresh button is weak

There's a refresh button that feels unnecessary and gives no feedback on what it's doing.
The app doesn't communicate what's happening in the background at all. Author wants to
expose the **minimum** amount of information — not a dashboard of internals.

Three specific weaknesses: you can't tell when refresh is _needed_; its result is
invisible when nothing changed; and it duplicates work FSEvents already does automatically.

---

## 5. Proposed direction (open to challenge)

The one-line thesis: **every number should be attributable to its clock and verifiable by
drilling down. Distrust comes from unattributed, unfalsifiable numbers — not from
arithmetic errors.**

### 5.1 Trust fixes (do these first — they gate everything)

1. **Kill empty drilldowns under non-zero headers.** A number you can't decompose into
   named files is unfalsifiable, therefore untrusted. Split the three collapsed states —
   _loading_ vs. _genuinely zero_ vs. _lookup failed_ — into distinct UI. A 228 GB header
   must never dead-end at "No files found."
2. **Remove `minimumWidth` from the bars.** Use a log scale or simply don't draw a bar
   below a threshold. Never fake the visual floor — it teaches the eye the graphics are
   decorative, and that distrust bleeds onto the digits next to them.
3. **Make shrinkage visible.** Freeing 20 GB should not look identical to an idle machine.
   The "Stable" checkmark should distinguish "nothing changed" from "you freed space."
4. **Attribute every number to its clock,** or unify to one clock. At minimum, precise
   timing labels ("as of 2 min ago"), never "recent" / "just now" next to a precise byte
   count.

### 5.2 Reconciliation (highest-leverage trust feature)

Show that **category sizes + outside-scope ≈ disk used** (what Finder reports). An app that
visibly demonstrates its parts sum to the whole authoritative total has _proved itself
once_ — after which the user stops auditing every number. The "X GB outside scan scope"
string already exists but only as a fallback footer state; promote it to a first-class
reconciliation row.

### 5.3 Background scan (Problem 1)

- **Progress bar only on the very first scan,** where there's no data and the wait _is_ the
  experience.
- **Background rescans: mark the data, not the chrome.** De-emphasize the specific numbers
  whose source is recomputing; settle them when the scan lands. Nothing in the footer.
- **Don't ship the 3%→97% bar.** A bar that breaks its promise on every scan spends
  credibility on the least worthwhile thing.
- **Drop "Changes pending."** It's the app narrating its own queue; the user can't act on
  it. Either incorporate the change silently, or if a full scan is genuinely required, say
  _that_ and offer the button.

### 5.4 One freshness element (Problems 1 + 4 together)

Replace the refresh button _and_ the "Refreshing"/"Changes pending" footer states with a
single always-visible element in the header:

```
Updated 2 min ago        ← idle, always present
Updating…                ← in progress
Stale · click to update  ← FSEvents gap / full scan needed
```

One slot, one meaning, clickable to force. This is the _minimum_ information Problem 4
asks for, and it's the only place the app should talk about its own internals.

### 5.5 Replace growth rate with a named-contributors list (Problem 2)

A rate is an abstraction over the list; nobody decides from a forecast. People decide from
named things:

```
Xcode DerivedData  +4.2 GB
Downloads          +1.1 GB  (3 files)
Chrome cache       +800 MB
```

Ship the list — it's the "ah, right" moment. The rate was built because it was computable,
not because it was useful.

### 5.6 Gate for shipping cleaning (Problem 3)

Do **not** ship delete until read-only is trusted. Concrete exit criteria:

1. No displayed number > 0 can ever produce an empty drilldown.
2. Every row states its clock (or is genuinely live).
3. Reconciliation is visible (categories + outside-scope ≈ disk used).

### 5.7 Suggested order

1. Split loading/empty/failed in drilldowns (the trust bug).
2. Kill `minimumWidth` on both bars.
3. Freshness element; delete the footer nag chain.
4. Attribute every number to its clock.
5. Replace the rate with the named-contributors list.
6. Reconciliation row.
7. _Then_ cleaning.

---

## 6. Open questions (the ones that matter)

1. **Empty drilldown:** reproducible on a specific category (Caches? Other?), or does it
   move around? This decides whether it's a category-detection bug or a generic
   loading/state bug.
2. **Baseline semantics:** should the baseline stay user-resettable, or always mean "since
   you last opened the app"? (i.e. is the `+X GB` pill a managed baseline or a
   session delta?)
3. **One clock or many?** Is it feasible/desirable to collapse the 5 truth sources toward
   a single "as of last scan" clock, accepting slightly staler free-space — or is
   multi-clock inherent and the fix is purely labeling?
4. **Reconciliation tolerance:** what residual (categories + outside-scope vs. statfs used)
   is "close enough" to display as reconciled without looking broken? macOS purgeable
   space, APFS snapshots, and hardlinks all make exact reconciliation impossible.
5. **Is "growth over time" actually the right primary frame**, or should Prunr lead with
   the DaisyDisk-style "what's big + drillable" and treat growth as a secondary lens? The
   author's own signal (rate "not helping") is evidence the diff framing may be
   over-weighted in the UI.

---

## 7. One-paragraph summary for a cold reviewer

Prunr is a macOS menu-bar tool for seeing what's _growing_ on disk over time. It's ~80%
trustworthy today but the author distrusts the numbers without being able to say why. The
root cause is that the app renders five different data sources — live free space, last full
scan, a resettable baseline, an FSEvents growth journal, and on-demand drilldowns — in
identical typography with no labels, so numbers that are legitimately measured at different
times _look_ like they should agree and don't. The fix is attribution + falsifiability
(every number drillable to named files, every number tagged with its clock, and a
reconciliation row proving the parts sum to the whole) rather than more-precise arithmetic.
Four visible symptoms — opaque background scans, categories that open empty, a weak
feedback-less refresh button, and a growth "rate" that doesn't aid decisions — are all
facets of that one root cause. Cleaning features must wait until read-only is trusted.
