# Prunr — Trust Plan

_2026-08-21 · supersedes the ordering in `docs/ux-review-brief-2026-08-21.md` §5.7_

Synthesis of the UX brief plus two external model reviews (Sol, Kimi K3), with every
code claim verified against the repo. The brief's diagnosis holds; its **priority order
was wrong**. Semantic integrity moves ahead of visual cleanup.

---

## The thesis, revised

The brief blamed "five clocks rendered without labels." That's real, but it is the
*amplifier*, not the cause. The cause is that **several UI claims do not match the
underlying data semantics** — the headline growth number is not what its label says it
is, failures render as facts, and a button labeled Refresh doesn't refresh.

The clocks made those defects unfalsifiable. Fix the defects first; much of the clock
problem then dissolves structurally rather than through labeling.

---

## Verified defects (evidence)

| # | Defect | Evidence |
|---|---|---|
| D1 | Growth sums **positive buckets only** — shrinkage discarded | `GrowthJournalService.swift:107` filters `deltaBytes > 0` |
| D2 | Growth **decays on its own** — journal pruned at 30d while baseline can be older | `MenuBarManager.swift:1335` prune · `SettingsStore.swift:98` default 30 · cutoff `GrowthJournalService.swift:30` |
| D3 | Categories under 1 MB growth get **no story at all** → silently land in "stable" | `GrowthJournalService.swift:8,112` |
| D4 | Query failures return `[]`; UI renders "No files found" | `BaselineService.swift:494` + 11 more catch blocks |
| D5 | Refresh button is a **no-op** when no FSEvents are queued | `MenuBarManager.swift:1491` → `:3047` early return |
| D6 | "Outside scan scope" is `used − tracked`, clamped at 0 — adding it back is a tautology | `MenuBarView.swift:1103` |
| D7 | `GrowthBarView` / `SizeBarView` are **dead code** (zero non-preview references) | grep: no usages outside own files |

**D2 is the sharpest.** Buckets are *deleted*, not just filtered — so for a baseline older
than the retention window, growth history is unrecoverable and the headline number shrinks
with no filesystem activity. The invariant asserted in the comment at
`GrowthJournalService.swift:90` ("every retained bucket represents growth since the current
baseline") is broken by the prune.

**Corrections to the brief:** §4 P1's "percentage never reaches the UI" is false —
`scanStatusCard` (`MenuBarView.swift:1794`) already renders determinate progress when the
estimate is reliable and degrades to indeterminate otherwise. §5.2 reconciliation is a
tautology. §5.1.2 targets dead code. §5.1.3 is mis-scoped as presentation.

---

## Phase 0 — Decisions (blocking Phase 1)

These change the shape of the work. Not code.

- [ ] **D-1 · Baseline semantics.** Is the pill a *session delta* ("since you last opened")
      or a *managed baseline* (explicit reset)? Recommendation: **session delta by default,
      explicit "Set baseline" behind a click.** Current ambiguity is itself a trust leak.
- [ ] **D-2 · Retention vs. baseline age.** Once growth is net-signed, retention and
      baseline age can no longer be independent settings. Options: (a) never prune inside
      the active baseline window, (b) cap baseline age at retention and force a re-baseline,
      (c) collapse the journal into a signed running total per category so pruning detail
      doesn't lose the aggregate. Recommendation: **(c) + (a)** — keep an unpruned signed
      aggregate; prune only per-bucket detail.
- [ ] **D-3 · Primary category frame.** Recommendation: growth stays the **headline**
      (pill + contributors), but the category list becomes **single-clock** — last-scan
      sizes, with growth as sort order and badge. Dissolves two-clocks-on-one-row
      structurally.

---

## Phase 1 — Growth means signed net change

Fixes D1, D2, D3. Nothing downstream is trustworthy until this lands.

- [ ] Define the contract explicitly in code: _signed net byte change per category since
      the active baseline_. Write it as a doc comment that the tests enforce.
- [ ] `GrowthJournalService.buildStories` — stop filtering `deltaBytes > 0`. Sum signed.
- [ ] Replace the `recentStoryThresholdBytes` drop (currently kills the story entirely)
      with a *presentation* threshold. A category with ±0 net still has a story: "no net
      change." Absence of a story must stop meaning "stable."
- [ ] Implement D-2's resolution so the aggregate survives pruning. Add a regression that
      advances the clock past retention and asserts the reported growth is unchanged.
- [ ] `MenuBarManager.growingCategories` / `stableCategories` — partition on *net sign*,
      not on `recentGrowthStory != nil`.
- [ ] `MenuBarView.overallGrowthBytes` — sum signed across all categories, not just
      `growingCategories`.
- [ ] Header pill: three states — grew / **shrank** / no net change. Freeing 20 GB must not
      look like an idle machine.

**Acceptance:** delete 20 GB and add 1 GB inside one baseline window → pill reads **−19 GB**.
Leave the app idle past the retention window → the number does not move.

---

## Phase 2 — Typed drilldown outcomes

Fixes D4. The swallow is in the service layer, so empty-state copy in the view cannot fix it.

- [ ] Introduce a result type — `loaded(rows) | empty | failed(error) | unavailable(reason)` —
      and thread it through `BaselineService`'s 12 catch blocks. No more `catch { return [] }`.
- [ ] `CategoryGrowthListView` renders four distinct states. `failed` gets Retry; `unavailable`
      names the reason (permissions, snapshot missing, scan in progress).
- [ ] **Invariant check:** non-zero parent opening to zero rows is a *contradiction*, not an
      empty state. Surface it as such, with Rescan + diagnostics.
- [ ] Instrument every empty-under-nonzero occurrence to the diagnostics log with category,
      snapshot id, and query path.

**Acceptance:** no category header > 0 can render "No files found." Instrumented counter
exists and is queryable in alpha builds.

---

## Phase 3 — Refresh means refresh

Fixes D5.

- [ ] Decide: promote `checkGrowth()` to a genuine rescan/reconciliation, **or** remove the
      button and expose an explicit "Rescan now" recovery action. Recommendation: remove the
      ambient button; recovery belongs next to the staleness signal, not floating in the header.
- [ ] Replace the footer priority chain (`MenuBarView.swift:1618–1700`) with one freshness
      element that names *what* is stale:
      `Scanned 2h ago` · `Scanning… showing 2h-old data` · `Stale · Rescan`
- [ ] "Stale" needs a **policy** (age threshold + pending-change volume), not a binary — or it
      pins on permanently and becomes the old nag in a better font.
- [ ] Drop "Changes pending" (internal queue chatter, no user consequence). Keep only genuine
      stale-inventory signalling.

**Acceptance:** every state the freshness element can show is either actionable or
informative about the data the user is looking at. None describe an internal queue.

---

## Phase 4 — Collapse clocks, then label sections

- [ ] Sample `statfs` at panel-open. For a menu-bar app, glance-time liveness is the only
      liveness that matters.
- [ ] Unify everything except free space and the baseline delta to "as of last scan."
- [ ] Apply D-3: category list becomes single-clock (last-scan size), growth as sort + badge.
- [ ] Provenance at **section** level only — "Drive space now" / "Scanned 2h ago" /
      "Since baseline". Per-row labels are clutter and read as nervousness. _(This replaces
      brief §5.1.4.)_

---

## Phase 5 — Honest accounting gap

Fixes D6. Replaces the brief's "reconciliation."

- [ ] Remove the `max(0, …)` clamp — tracked inventory exceeding used space is a real
      contradiction signal and must not be suppressed.
- [ ] Show a **signed** gap with named buckets, so every byte has a name:
      `Tracked 412 GB · Outside scope 38 GB · Purgeable/system 11 GB · Unaccounted −2 GB`
- [ ] Never use the word "reconciled." Success criterion is **"every byte has a bucket
      name,"** not "sums within ε."
- [ ] Timestamp each bucket with its source clock.

---

## Phase 6 — Named contributors replace the rate

- [ ] Precompute or lazily hydrate contributors — current queries are sequential and
      expensive (`CategoryGrowthListView.swift:736`). Do not put them in the overview until
      this is done.
- [ ] Overview shows named things, signed:
      `Xcode DerivedData +4.2 GB · Downloads +1.1 GB (3 files) · Trash −8.0 GB`
- [ ] **Dismiss/ignore affordance per contributor.** Transient noise (Dropbox sync, Xcode
      builds) will otherwise train the user to ignore the list — the same death as the rate,
      just slower.
- [ ] Persist ignores; expose them in Settings so the list stays auditable.

---

## Phase 7 — Cleanup

- [ ] Delete `GrowthBarView.swift` and `SizeBarView.swift` (dead). If bars return, use
      **linear scale with a minimum-pixel visibility floor** — never a proportional-width
      floor, never a log scale on a magnitude chart.
- [ ] Remove rate/trend plumbing left unused after Phase 6 (`CategoryGrowthTrend`,
      `growthSpanDays`).
- [ ] Purge vague timing strings — `"recent"`, `"just now"` (`MenuBarManager.swift:3214,3224`).

---

## Phase 8 — Cleaning (gated)

Do not start until Phases 1–5 ship and the Phase 2 instrumentation reads **zero
empty-under-nonzero events over N weeks of alpha.** "Never happens" must be measured, not
hoped.

Additional gate the brief omitted — deletion requires **live revalidation at action time**:

- [ ] Re-stat exact paths immediately before deleting (existence, size, mtime).
- [ ] Verify permissions and that the path is still inside an enabled scope.
- [ ] Confirm recoverability (Trash vs. permanent) and state which is happening.
- [ ] Abort loudly on any mismatch between displayed and revalidated state.

Snapshot data is for *deciding*. It must never be the authority for *deleting*.

---

## Order of work

1. Phase 0 decisions (D-1, D-2, D-3)
2. Phase 1 — signed net growth
3. Phase 2 — typed outcomes + instrumentation
4. Phase 3 — refresh / freshness
5. Phase 4 — clocks
6. Phase 5 — accounting gap
7. Phase 6 — named contributors
8. Phase 7 — cleanup
9. Phase 8 — cleaning

Phases 1–3 are the trust core; 4–6 are the payoff; 7 is hygiene; 8 is the feature.

---

## Open, unresolved

- **Is the empty drilldown category-specific or generic?** Phase 2's instrumentation
  answers this empirically — stop guessing and measure.
- **Purgeable / APFS snapshot accounting** — needed for Phase 5's bucket names. Unknown
  whether macOS exposes these reliably enough to name them.
- **Retention default (30d)** may be wrong once growth is signed and the aggregate survives
  pruning. Revisit after D-2.
