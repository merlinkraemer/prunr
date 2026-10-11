# Prunr product roadmap

**Date:** 2026-09-07
**Status:** superseded on 2026-10-11 by [core-screen-episodes-prd-2026-10-11.md](core-screen-episodes-prd-2026-10-11.md); kept for history

## Current state and next step

> **2026-10-11:** The core screen is settled: a day-grouped list of named changes over 30 days ("what happened"), not size-first Storage. The current plan and slices are in [core-screen-episodes-prd-2026-10-11.md](core-screen-episodes-prd-2026-10-11.md). Background: [communication model](core-screen-communication-model-2026-10-11.md), [layout review](core-screen-layout-review-2026-10-11.md), [row analysis](core-screen-row-analysis-2026-10-11.md). The text below is the 2026-09-07 plan.

The near-term direction is clear: make capacity honest, then support size-first Storage and signed Changes for Mac developers. The broader product vision/differentiation and the first affected-user proof are not yet settled. **Next step: start a new agent brainstorm session** to define that longer-term promise, what makes Prunr worth using over existing tools, and the evidence that would justify further scope. Then reconcile this roadmap; s1 remains the first implementation slice if authorized. Do not infer that the historical green checks in `todo.md` complete these slices.

## Problem

Prunr has persistent inventory, technical categories, signed changes, and Finder reveal, but the interface gives recent change priority even when the user needs to find substantial space. Capacity representation and residual wording can imply more accuracy than the implementation supports. Broad categories and file-level lists leave too much recognition and inspection work to the user.

The underlying job is to reduce investigation when storage surprises or blocks a technical Mac user. Product direction is captured in [the updated definition](product-definition-notes-2026-09-06.md). This plan documents the accepted direction; app implementation, publishing, user outreach, and release are not authorized by this documentation update.

## Solution

Keep the existing native utility and scanning foundation. Make available capacity and accounting honest, then offer size-first **Storage** and signed **Changes** views over shared navigation. Make recognizable folders/artifacts easy to find and explain a narrow set of developer data. Validate the discovery loop before extending history or adding cleanup.

The initial Storage default and existing seven-day Changes window are planning decisions. Preserve signed arithmetic and retention independence; changing presentation must not rewrite history semantics. Do not add speculative period selectors or automatic intent-based mode switching.

## Out of scope

- Batch, autonomous, scheduled, or one-click global cleaning; no immediate new deletion operation.
- Universal junk scores, “unused” verdicts from timestamps, or guaranteed reclaimable-byte promises.
- Causal activity logs, broad cross-tool/project attribution, git integration, manual project setup.
- A general Mac maintenance suite, premature full-window redesign, new analytics collection.
- Repository-wide refactoring or replacing snapshot/FSEvents infrastructure.
- Creating GitHub issues/boards, contacting testers, pushing, deploying, or shipping a release in this task.

## Slices

### s1: Trust the capacity overview

- **outcome:** A user can read available space and interpret the bar and scan coverage without misleading proportions or labels.
- **depends_on:** none
- **likely_files:** `Prunr/Views/DriveBarView.swift`, `Prunr/Views/MenuBarView.swift`, `Prunr/Services/DiskSpaceService.swift`, `Prunr/Models/DiskAccountingResult.swift`, `PrunrTests/`
- **acceptance:**
  - [ ] Available space is persistently visible, using a documented volume/free-space definition; unknown/loading values are not rendered as measured zero.
  - [ ] Used/free proportions remain literal at low, medium, and high usage. Category visibility/hit areas do not inflate measured shares; overcount is explained rather than normalized into a falsely exact breakdown.
  - [ ] Residual wording distinguishes unaccounted bytes from verified excluded paths; positive, zero, and inventory-overcount cases are handled explicitly without treating scan totals as reclaimable bytes.
  - [ ] Current volume capacity and last completed inventory have understandable freshness/coverage states. Existing scan failure, incomplete-result, and quiet-idle contracts are preserved and verified proportionately.

### s2: Choose Storage or Changes

- **outcome:** A first-time user can explore large existing items immediately, while a returning user can investigate changes through the same navigation.
- **depends_on:** s1
- **likely_files:** `Prunr/Services/MenuBarManager.swift`, `Prunr/Views/MenuBarView.swift`, `Prunr/Views/CategoryGrowthListView.swift`, `PrunrTests/MenuBarManagerRegressionTests.swift`
- **acceptance:**
  - [ ] Storage is the initial default and ranks categories, subcategories, and listed items by current size; unchanged large items do not rank below tiny changes.
  - [ ] Changes preserves signed seven-day accounting and meaningful-change ranking; zero net change, absent history, and unavailable data are not conflated.
  - [ ] Current size remains visible on changed file rows. Switching views shares inventory and preserves a coherent navigation state without triggering a new full scan solely for the switch.
  - [ ] First-scan inventory works without seven days of history. Regression fixtures include the screenshot's large unchanged Audio versus tiny changed Media case and positive/negative/net-zero changes.

### s3: Find recognizable large folders and artifacts

- **outcome:** A user can identify a substantial folder or artifact inside a broad category and reveal the exact target in Finder.
- **depends_on:** s2
- **likely_files:** `Prunr/Models/CategoryInventoryItem.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Database/DatabaseManager.swift`, `Prunr/Views/CategoryGrowthListView.swift`
- **acceptance:**
  - [ ] Other exposes recognizable large folders with names, locations, and aggregate current sizes; it does not require inspecting thousands of individual files to discover one large directory.
  - [ ] A supported technical artifact such as `node_modules` is navigable as a unit without manual project definitions; parent/child representations do not double-count totals.
  - [ ] Large inventories have explicit pagination/completeness behavior rather than a silently truncated list. Unknown, failed, empty, and unavailable results are distinguishable when they affect this flow.
  - [ ] Finder reveal targets the displayed item; refresh/back navigation remains coherent after that item changes or disappears. Relevant aggregation, scope, and scan-integrity regressions pass.

### s4: Understand a bounded set of developer artifacts

- **outcome:** A developer can understand what a supported artifact contains and the consequences of removing it without an unsupported safety verdict.
- **depends_on:** s3
- **likely_files:** `Prunr/Models/GrowthCategory.swift`, `Prunr/Views/CategoryGrowthListView.swift`, supporting explanation model if needed, `PrunrTests/`
- **acceptance:**
  - [ ] Begin with a small documented set, such as Xcode DerivedData and project dependencies; each explanation identifies the evidence used and regeneration prerequisites/cost rather than promising harmless deletion.
  - [ ] Archives, source data, shared caches, and unknown paths do not inherit generic disposable-cache wording. Active-use status is not implied unless measured reliably.
  - [ ] Name, path, current size, explanation, and Finder reveal are available together. Any timestamp shown names its actual meaning and handles missing metadata honestly.

### s5: Inspect an item before leaving Prunr

- **outcome:** A user can preview a supported file and return to the same storage context, using Finder as a fallback.
- **depends_on:** s3
- **likely_files:** `Prunr/Views/CategoryGrowthListView.swift`, `Prunr/Services/MenuBarManager.swift`, platform preview integration
- **acceptance:**
  - [ ] Use native preview capabilities for supported items; show readable location/current size and an explicit Finder action for unsupported items.
  - [ ] Preview does not mutate files, lose list position/navigation, or present a missing item as current.
  - [ ] Keep the current menu-bar entry point. Introduce a larger inspection surface only if this bounded flow demonstrably cannot fit; review that UX decision before expanding scope.

### s6: Validate discovery with affected developers

- **outcome:** Recorded user evidence identifies whether Prunr reduces investigation and which context is missing.
- **depends_on:** none
- **likely_files:** documentation/evidence notes in `docs/` when sessions occur; no app telemetry required
- **acceptance:**
  - [ ] Prepare separate tasks for a real storage-blocked operation and unexplained growth. Recruit a small initial group, targeting roughly five affected developers; outreach requires separate authorization.
  - [ ] Record the usual-tool baseline and Prunr attempt: time to first useful discovery, navigation effort, misunderstood labels, decision confidence, and whether the target meets the user's actual space need. No forced deletion.
  - [ ] Include unchanged large data and a technical artifact; record failures and order/learning effects. Separate participant evidence from synthetic correctness fixtures.
  - [ ] After s2/s3 are available, repeat the relevant tasks and record a continue/revise decision. A small exploratory sample is not proof of market fit.

### s7: Test whether richer change context earns its cost

- **outcome:** A bounded experiment determines whether named change context improves diagnosis beyond current inventory.
- **depends_on:** s2, s6
- **likely_files:** `Prunr/Services/GrowthJournalService.swift`, `Prunr/Services/BaselineService.swift`, `Prunr/Views/CategoryGrowthListView.swift`, experiment evidence in `docs/`
- **acceptance:**
  - [ ] Start only if s6 identifies a concrete history-related gap. Compare current inventory with a named contributor, current size, and accurately observed timing; a research prototype is sufficient.
  - [ ] Do not claim install events, last use, abandonment, or causal attribution from category journal buckets. Missing observations and net cancellation remain explicit.
  - [ ] Record whether context changes discovery/understanding enough to justify collection, storage, and UI cost; stop or park the experiment if it does not.

## Dependency graph

```text
s1 → s2 → s3 → s4
               └→ s5
s2 + s6 → s7 (conditional experiment)
s6 → validation evidence for prioritizing s4/s5
```

## Parallel batches

- **Batch 1** (independent): s1; s6 baseline/session preparation. Live outreach is a separate action.
- **Batch 2** (after s1): s2; s6 baseline research may continue independently.
- **Batch 3** (after s2): s3. Retest s6 when the revised flow is available.
- **Batch 4** (after s3): s4 and s5, prioritized by evidence. They share view files: serialize edits or use isolated worktrees and coordinate integration.
- **Conditional batch** (after s2 and completed s6): s7 only if the evidence warrants it.

Logical independence does not imply permission to launch implementation agents. Each slice remains unchecked until implemented and verified.

## Notes

### Outcome horizons and workstreams

| Workstream | Now | Next | Later / conditional |
| --- | --- | --- | --- |
| Reliability / trust | s1; preserve authoritative scans and explain incomplete/failed data | Recheck navigation, aggregation, responsiveness in s2/s3 | Larger accounting/performance work only for evidenced gaps |
| Core experience | s2 size-first Storage and separate Changes; s3 recognizable units | s4 explanations and s5 preview | Larger inspection window/search only if observed tasks require them |
| Cleaning / action | Existing Finder reveal; validate decisions without deletion | Define single-target action needs from user evidence | At most L3, with explicit target/recoverability/revalidation contract; never batch/autonomous |
| Distribution / growth | Prepare s6 research; use existing feedback process | Reassess promise/onboarding against observed outcomes | Public copy, recruitment campaigns, release only with separate authorization |
| Experiments | Compare actual workflows, including failures | s7 if history has a demonstrated gap | Broader history only after useful results |
| Parked | Universal junk scoring; blanket safe-cache claims | Cross-tool causal attribution; manual project setup | Maintenance suite, automatic cleanup, speculative redesign |

### Release and implementation gates

- Inspect branch/worktree state before code work; substantial implementation belongs on a feature branch. Do not overwrite unrelated work or push protected branches without explicit permission.
- Verify the arithmetic and behavior affected by each slice; run the required project checks and proportional regression coverage. The historical green counts in `todo.md` are not current verification.
- Reproduce first-scan, scan-in-progress, inaccessible data, stale/failed drilldown, changed/deleted target, and overcount states relevant to the slice. No cosmetic success may hide unknown or contradictory accounting.
- User visual judgment remains separate from programmatic checks. No browser/app visual automation unless explicitly requested. Capture the specific remaining visual review items at handoff.
- Release requires verified implemented slices and separate authorization; no new release readiness is claimed by this plan.
- Any future deletion needs an explicit implementation plan covering target revalidation, recoverability, failure behavior, and actual available-space read-back. Moving to Trash is not immediate recovery of free space.

### Next working week, after implementation authorization

1. Establish feature branch and s1 capacity/accounting fixtures; implement and verify s1.
2. Implement s2 with shared navigation and size/change fixtures; preserve signed journal semantics.
3. Begin s3 with one complete Other-folder path and one supported artifact unit, rather than a broad classifier rewrite.
4. In parallel, prepare s6 and arrange sessions once outreach is authorized. Let observed failures prioritize the next slice; do not promise every slice fits one week.

### Proposed GitHub Project structure

One card per slice; fields: **Workstream**, **Horizon**, **Depends on**, **Evidence / acceptance**, and **Release gate**. Statuses: Backlog → Ready → In progress → Verify → Done; use Blocked only with a named dependency/decision. Keep experiments separate from committed implementation. No board or issues were created by this plan.

### Evidence and risks

- [Product definition and competitive sources](product-definition-notes-2026-09-06.md) contain the 2026-09-07 review, six motivating examples, and corrections to earlier assumptions.
- Baseline code: `a3f328b`. Review established source behavior and the supplied screenshot, not live reliability, competitor usability outcomes, or user demand.
- Scope/accounting mismatches, misleading last-used claims, classifier precedence, shared artifacts, and silent file-list caps are material risks. Preserve uncertainty instead of inventing precise answers.
- [Signed-growth PRD](prd-signed-growth-2026-08-21.md) remains the arithmetic/retention contract; its universal change-first presentation is superseded by this plan once implemented.
- [Historical trust plan](trust-plan-2026-08-21.md) and [task history](todo.md) provide context, not a fresh backlog audit. Recheck unresolved claims against current source before expanding a slice.

**TL;DR:** First make capacity honest, then separate size exploration from change diagnosis and surface recognizable folders/artifacts. Validate with affected developers; add explanations/preview next and expand history only when evidence justifies it. This is a documentation plan, not completed implementation or release approval.
