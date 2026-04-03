# Beta Audit - 2026-04-03

This document records the current state of Prunr before beta planning, based on:

- local code inspection
- current local worktree state
- current repository docs
- current open GitHub issues

## 1. Local Dev Environment

Status: almost ready, but not fully initialized.

What is installed and working:

- `/Applications/Xcode.app` exists
- Swift toolchain is present
- `gh` is installed and authenticated
- repo-local `make` commands now force `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

What is still missing on this Mac:

1. `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. `sudo xcodebuild -license`
3. Open Xcode once to finish first-run setup so `simctl` becomes available

Current verification:

- `make doctor` succeeds and reports the remaining first-run setup gaps
- `make build` and `make test` both stop on the Xcode license gate, not on repo configuration

Conclusion:

- The repository tooling is in reasonable shape for a fresh Mac
- Apple first-run setup is still required before beta validation work can start cleanly

## 2. Product State From Code

The high-level product docs are broadly directionally correct:

- menu bar macOS app
- baseline plus growth-journal tracking
- segmented drive bar
- drill-down and subcategory breakdown flow
- 3-tab settings window
- smoke test target exists (`PrunrTests/PrunrSmokeTests.swift`)

Important implemented state that was easy to miss from stale docs/issues:

- growth indicator threshold is already reduced to `10 MB`
- growth story recency window is already reduced to `24h`
- manual "Check Growth" forces a real recent-change refresh
- snapshot-based subcategory drilldown path is implemented
- "Accept Growth" is already implemented in code and is currently part of local uncommitted work

Inference:

- Several March planning docs describe work that is now already implemented
- Beta planning should be based on current code, not historical plans

## 3. Local Worktree State

The worktree is not clean.

Relevant modified app files:

- `Prunr/Database/DatabaseManager.swift`
- `Prunr/Services/BaselineService.swift`
- `Prunr/Services/MenuBarManager.swift`
- `Prunr/Services/ScanService.swift`
- `Prunr/Views/MenuBarView.swift`

These changes line up with the "Accept Growth + growth indicator fixes" workstream in `docs/plan-accept-growth-and-fixes.md`.

Conclusion:

- There is active pre-beta product work in progress locally
- Any beta audit must treat the current branch as ahead of GitHub issue tracking

## 4. Documentation Audit

### Docs that look current enough

- `docs/STATE.md`
- `docs/OVERVIEW.md`

These match the codebase at a high level.

### Docs that are stale or archival

- `documentation/roadmap.md`
- most of `.planning/phases/**`
- `docs/fix-plan-growth-indicators.md`

Why they are stale:

- `documentation/roadmap.md` still presents MVP-era work as unchecked even though the app now has menu bar UI, growth tracking, settings, tests, and post-MVP features
- `.planning/phases/**` contains historical execution plans and completed task logs, not current open work
- `docs/fix-plan-growth-indicators.md` still says "Status: Proposed" for multiple fixes that are already present in code

Recommended source of truth going forward:

1. `docs/STATE.md` for implemented state
2. `docs/OVERVIEW.md` for direction
3. this audit doc for beta-prep triage until replaced by a newer audit

## 5. GitHub Issue Audit

Open issues at audit time:

- `#1` Quantized category breakdown in top bar
- `#2` UI: polish drilldown flow
- `#3` Rethink settings and rules UX
- `#4` Polish growth indicators UI

Assessment:

### `#4` Polish growth indicators UI

Status: active and real.

Reasoning:

- growth indicator code is under active local modification
- related fixes and "Accept Growth" behavior are in current local changes

### `#2` UI: polish drilldown flow

Status: still plausible, but needs rewrite before implementation.

Reasoning:

- drilldown machinery is substantial and already implemented
- the old issue title/body is too vague to be a useful beta task
- this should become a concrete polish/UX bug list after fresh hands-on testing

### `#3` Rethink settings and rules UX

Status: partially stale.

Reasoning:

- settings already have dedicated `General`, `Scan Scope`, and `Scan Rules` tabs
- the core "settings and rules" UX exists and is beyond the issue's original likely scope
- the issue should be replaced with specific UX findings from beta prep rather than kept as a broad umbrella

### `#1` Quantized category breakdown in top bar

Status: likely stale or at least underspecified.

Reasoning:

- the top bar already renders category segments via `DriveBarView`
- if the issue meant "show category segmentation at all", it is done
- if it meant a stricter quantized/legend design, the current issue text is too underspecified to guide work

Recommendation:

- keep `#4`
- rewrite `#2` and `#3` into concrete beta-facing tasks
- verify `#1` visually, then likely close or rewrite it

## 6. Beta-Blocking Unknowns

These still need explicit verification once Xcode first-run setup is completed:

1. Can the app build cleanly from the current working tree after license acceptance?
2. Do `PrunrSmokeTests` pass on this machine?
3. Does code signing work for local runs with the current team settings?
4. Does the onboarding + Full Disk Access flow behave correctly on a fresh machine?
5. Does current local "Accept Growth" work actually resolve the remaining growth-indicator confusion?

## 7. Recommended Next Pass Before Beta

1. Finish Apple first-run setup on this Mac
2. Run `make build`
3. Run `make test`
4. Manually exercise onboarding, scan scope, drilldown, growth indicators, and Accept Growth
5. Rewrite GitHub issues into specific beta tasks based on observed failures
