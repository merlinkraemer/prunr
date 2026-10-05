# Prunr — Product Definition: Working Notes

_Started: 2026-09-06. Updated: 2026-09-07 after source, screenshot, and competitor review. Status: working direction adopted for planning; user value remains to be validated. Documentation approval does not authorize app implementation or release._

## Current direction — 2026-09-07

This section supersedes conflicting conclusions in the original interview below. Preserve that interview as historical reasoning, not the current implementation contract. The actionable plan is [Product roadmap](product-roadmap-2026-09-07.md).

**Core problem:** When storage surprises me or gets in my way, finding out what matters takes too much investigation.

**Working promise:** Know what's taking up space, see what changed, and quickly find what you can do about it.

**Primary audience:** Mac developers experiencing storage pressure or unexpected growth. Technical media users share the general discovery problem; developer-specific explanations come first. The founder currently lacks storage pressure, so real affected users must supply validation.

**Core loop:** Check available space → explore large or changed items → recognize/inspect a folder or artifact → make an intentional decision → verify the resulting state. Finder reveal is already a useful action; in-app deletion is not required to validate discovery.

### Product principles and boundaries

1. Be an instrument: accurate measurements, explicit uncertainty, user-controlled decisions.
2. Deliver value on the first scan; history adds context rather than gating inventory.
3. Give each task a clear ordering: current size for Storage, meaningful change for Changes.
4. Surface recognizable folders/artifacts and explain known consequences; do not infer personal importance.
5. Stay quiet and ready; preserve responsive navigation and scan integrity as the experience grows.

Keep the L3 ceiling, no batch/autonomous cleaning, no git features, and no manual project definitions. Cleanup remains an optional thin layer. Cache/temp labels alone do not establish safety: regeneration cost and active use matter. No new cleanup operation is included in the immediate roadmap.

### Decisions for the next iteration

- Preserve the restrained native presentation and existing inventory/watcher foundation.
- Make available capacity persistent and the capacity bar quantitatively proportional. Do not enlarge used space or category shares to make them clickable.
- Introduce **Storage** and **Changes** as views over the same inventory/navigation. Storage is the initial default, ranked by current size. Changes retains the existing signed seven-day comparison; no new period picker is required now.
- Keep current size visible at category, subcategory, and file levels, including changed items.
- Make large recognizable folders and technical artifacts discoverable, especially inside Other. Do not rely solely on a capped list of individual files.
- Describe the measured residual honestly: used bytes minus scanned inventory is not proof of excluded folders. Distinguish coverage/accounting uncertainty from known categories; never call inventory totals guaranteed reclaimable space.
- Add a small set of well-supported developer explanations and inspection affordances before attempting broad project attribution.
- Preserve Finder reveal. Preview is a bounded next step; a larger inspection window is conditional on demonstrated space/navigation constraints, not an approved redesign.

### Corrections to the original interview

| Earlier conclusion | Current interpretation |
| --- | --- |
| Growth framing failed | Growth is useful for diagnosis, but unsuitable as the universal cleanup/exploration ranking. |
| No history means no day-one value | Current inventory already works independently of growth. |
| Unknown intent blocks the product | Recognition and inspection let the user supply intent. No universal junk score is needed. |
| Dev/media needs have no overlap | Size navigation and recognition overlap; specialist knowledge differs. |
| Cases 1–5 are detectable from dormancy/location | Candidates may be discoverable; disposability and abandonment are not established by those signals. |
| Project attribution is a unique moat | Mole already groups rebuildable artifacts by project. Reliable attribution across shared storage is still unproven. |
| History explains what changed and why | Current journal measures net size changes by category/subcategory; it does not establish causal activity or last use. |

The six motivating examples below remain validation scenarios, not a requirement to infer all six automatically. Footage can be surfaced for recognition without knowing whether it should be moved to a NAS.

### What the current app establishes

Review baseline: source at `a3f328b` and user-supplied screenshot dated 2026-09-07. Source review and screenshot inspection are not runtime reliability or usability validation; no tests were run during this review.

- `MenuBarManager.inventorySortsBefore` and subcategory sorting prioritize changes above 1 MB. The screenshot's 538.1 GB Audio category below a −3 MB Media change is expected behavior.
- `DriveBarView` enforces minimum category widths/used fill and caps residual share. Replace those representational distortions while preserving accessible navigation.
- `MenuBarView.outsideScanScopeBytes` is `max(0, usedBytes - trackedInventoryBytes)`; the label currently overstates what is known.
- Changed file rows in `CategoryGrowthListView` show delta instead of total size.
- `GrowthJournalService` uses signed net changes over seven days. Additions and removals can cancel; this is not an activity log. `SnapshotEntry` contains path/size references, not last-used or causal metadata.
- Existing technical subcategories, cache-owner recognition, inventory drilldowns, and Finder reveal are useful assets to extend.

### Competitive evidence and implications

Official pages/source documentation accessed 2026-09-07. These establish documented capabilities, not independently measured UX success, safety, adoption, or comparative performance.

| Source | Relevant workflow | Implication |
| --- | --- | --- |
| [DaisyDisk guide](https://daisydiskapp.com/guide/4/en/) | Map, large folders, preview, user-chosen removal; hidden/purgeable-space explanations | Recognition and human decisions already work as a product approach; this positioning alone is not unique. |
| [WhatSize](https://www.whatsizemac.com/) | Size-first column navigation, filtering, updates without rescanning everything | Familiar navigation and freshness matter; continuous inventory alone is not unique. |
| [CleanMyMac](https://macpaw.com/cleanmymac) | Separate cleanup, app management, and clutter workflows | Separate user tasks without adopting broad maintenance promises. |
| [Mole purge](https://github.com/tw93/Mole#purge) | Project-grouped artifacts with size/activity cues and explicit confirmation | Meaningful artifact units are valuable and already competitive territory. |
| [DevCleaner for Xcode](https://github.com/vashpan/xcode-dev-cleaner) | Explanations for DerivedData, archives, device support | Narrow domain knowledge helps users assess consequences; avoid treating all technical data alike. |
| [Apple Storage guidance](https://support.apple.com/en-us/102624) | Capacity, category navigation, move/delete options | Prunr must reduce investigation beyond the built-in baseline. |

### Validation and remaining questions

Recruit developers with an actual blocked operation or unexplained growth. Compare their usual workflow with Prunr, observing time to useful discovery, navigation effort, confusing terms, and confidence explaining a decision. Test recovery discovery and change diagnosis separately. No deletion is necessary in an exploratory session.

Open questions are now bounded: which artifact explanations help most; whether preview materially reduces Finder round trips; whether the popover constrains real tasks; and whether observed change context improves decisions enough to warrant more history work. Do not turn these into a broad heuristic engine before evidence arrives.

## Original interview — 2026-09-06 (historical)

_Exploration paused without a settled positive thesis. Statements below are preserved verbatim and may be superseded above._

## What Prunr is (starting context)
macOS menu-bar utility answering "what ate my storage?" Currently ~v0.1.5-alpha.22. SwiftUI/AppKit, GRDB/SQLite, filesystem snapshots, FSEvents, periodic full scans. Stated (pre-interview) differentiation vs DaisyDisk: shows _what changed over time and why_, not just _what's big_.

## What this conversation was for
Pressure-test the vision before building a roadmap. It did **not** land a finished thesis. Its main output is **negative knowledge** — several plausible framings were tested and falsified — plus a few hard constraints committed to. That narrowing is real progress; the positive definition is still open.

---

## Established facts (high confidence)

- **You are no longer your own user.** New laptop, no storage pressure. Prunr is kept running mainly as a passive menu-bar storage indicator. Consequence: design decisions now come from memory/empathy, not live pain. **Need a replacement source of truth** (real users, or a reproducible test setup). Unaddressed; biggest strategic risk.
- **The original trigger was a blocked operation, not curiosity.** File transfer, install, failing build, Photoshop scratch disk, growing caches — something couldn't proceed. Not "huh, where'd 40GB go?"
- **The thing that grows is usually not the thing you delete.** Space is freed by removing _old/stale/other_ stuff, not the new install/deps/file that caused the crunch. Single most important finding.
- **Target user: technical pros.** Devs first, media pros second. Explicitly _not_ CleanMyMac's general-consumer market.
- **Stance: "instrument, not butler."** Make the user more capable; don't act on their behalf and demand trust. Stated with no hedging — treat as a core principle.

## Hard constraints committed to
- **Cleaning ceiling is L3, ever.** May _recommend and explain_ (pre-select safe items, user confirms). **No** batch "Free 42GB" button (L4), **no** autonomous/scheduled cleaning (L5). Kills a whole feature class and marketing angle — intentionally.
  - L-ladder reference: L0 observe · L1 observe+navigate (reveal in Finder) · L2 single-target user-initiated trash · L3 recommendations (pre-select + explain, user confirms) · L4 batch · L5 autonomous.
- **Cleanup is a thin convenience layer on top of the core**, scoped to obviously-safe categories (trash, tmp, caches) so there's _something actionable_ when storage is hit mid-work. It is **not** the product.
- **No git integration / no per-project manual definition** (too much friction). NOTE: `.git`/`package.json`/`*.xcodeproj` etc. were proposed as _detection signals_, not features — that distinction was never fully resolved and is worth revisiting.

---

## Framings tried and rejected

| Framing | Why it failed |
|---|---|
| **Growth / "what changed"** as the headline | Can't see flat-but-dead junk (e.g. Docker images abandoned 4 months ago show as _zero_ delta). Useless on day one (no history). Growth may even be an _anti-signal_ — things growing now are things actively in use and worth keeping. |
| **History as evidence for safety claims** | Explicitly rejected. Cleanup is a separate layer, not powered by observed regeneration behavior. |
| **"Abandoned activity"** as the unit | Rejected: residue also comes from _active_ projects (tested something, removed it) and from pure tmp/caches. Not everything reclaimable is abandoned. |
| **"Reclaimable" as a clean category** | The set is genuinely heterogeneous — derived data (caches/tmp/build/deps), superseded copies (downloads, un-offloaded footage), dead experiments, and live-project debris. No single on-disk property separates "reclaim" from "keep" across all of them. |

## The core difficulty (unresolved — where the session stopped)
Every unifying label breaks because **the true separator is user _intent_, which is not encoded anywhere on the filesystem.** Prunr cannot compute importance.

Proposed reframe (neither confirmed nor rejected — session ended here): if intent is uncomputable, Prunr's job isn't _classification_, it's **recognition triggering** — surface candidates ranked by a cheap junk-likelihood heuristic, each shown with the minimum cues that make the user's own memory fire ("ah, that one"). The human supplies intent; Prunr supplies recall. Consistent with "instrument, not butler."

**The open question that would test it** (unanswered): across real examples, what is the _smallest cue_ that makes recognition fire — name? location? date-anchor? size? owning app/project? A combination? If mostly **name + date**, the UI is a dated named list and the product is near done. If _"I only knew because I remembered the whole episode,"_ no on-screen cue suffices and the product has a much harder ceiling.

## The six motivating examples (the real spec)
All are "an activity ended / a purpose lapsed, its residue didn't" — but see the "abandoned" rejection above; some occur inside still-active work:
1. A project worked on, trashed, never cleaned up.
2. Photoshop added 18GB tmp because the app was killed / "remove temp" never clicked.
3. 25GB media download sitting in a dir, no longer needed.
4. 3GB deps installed for a test that failed.
5. Tried a CLI tool / local LLM / GUI app, decided against it, never removed it.
6. Forgot to offload footage to the NAS after the final cut.

Detection note: 1–5 look detectable from appearance + dormancy + location. **#6 is not** — nothing on disk distinguishes footage-to-keep from footage-to-offload. That case likely requires user input, which conflicts with the "no friction" stance. Unresolved.

## A candidate worth keeping alive
**Attributing scattered debris back to the work that produced it** — e.g. `acme-dashboard · 14GB · node_modules 3GB + DerivedData 6GB + Docker 4.7GB · last touched 4mo ago`. Detectable for devs without user input via well-known root markers + artifact locations. The one thing DaisyDisk _structurally cannot do_ (no concept of what anything _is_). Possible moat. Was dismissed as "too hard / too narrow," partly on the misread that it meant git _features_. Unresolved.

## Actual stated hard problem
**The UI/prioritization problem:** "how do I decide what's important to the user, and how do I present it?" Implication: prioritization must come _before_ UI — can't design the screen until the sort order is known — and the honest sort order is a heuristic guess, not a truth claim.

## Recurring theme to carry forward
A **durable record no stateless tool has** — because at the moment of need even an AI agent must recompute everything and can't backtrack ("I installed deps I no longer need; nothing knows that"). Whether that record's job is _growth_, _dormancy detection_, _date-anchoring for memory_, or _nothing worth the engineering cost_ is **the central unresolved question** and should probably be settled first — it determines whether the snapshot/FSEvents subsystem is the core or an over-built supporting feature.

## Biggest open questions for next session
1. What's the minimum recognition cue? (name+date vs. full-episode memory)
2. Is history the core, or over-built infrastructure? What does it _uniquely_ buy vs. a good stateless scan + taxonomy?
3. Devs vs. media pros — which _first_? (Can't serve both well at once; debris has ~zero overlap.)
4. How to replace yourself as the user? (real users or a repro setup)
5. Is debris-attribution the moat, or out of scope?

## Deliverables still owed (from the original interview brief, once vision is settled)
Product thesis · primary user + trigger · core problem & why alternatives fail · one-sentence promise · 3–5 principles · core loop · key assumptions + validation · non-goals · horizoned roadmap (Now/Next/Later as outcomes, not tickets) · dependencies & release gates · risks · GitHub Project board structure · "next week" plan. Roadmap must separate: reliability/trust foundations · core experience · cleaning/action · distribution/growth · experiments · parked ideas.
