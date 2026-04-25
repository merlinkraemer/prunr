# Beta Fix Plan — 2026-04-25

## Verdict

Prunr is not ready for broad beta yet. The core UI and database flows are close, and validation is green on small/local workloads, but full-home scans still have correctness and hang risks that must be addressed first.

Validated before writing this plan:

- `swiftlint lint --strict --config .swiftlint.yml` — 0 violations
- `make test` — 47/47 tests passed
- `make e2e E2E_FILE_COUNT=5000` — 10/10 phases passed
- checked-in `Prunr.app` — Developer ID signed, hardened runtime, stapled notarization ticket validates

Not validated yet:

- full home-directory scan at 600k–1M+ files
- overnight idle/auto-scan CPU and RSS behavior
- reproduction/closure of the first-scan crash tracked in #12

## Release gate definition

A beta candidate is acceptable only when:

1. Manual Stop/cancel reliably recovers from long scans.
2. A failed/cancelled scan cannot corrupt or partially update visible inventory data.
3. Silent/background refresh cannot hard-freeze the app without a user escape hatch.
4. Drill-down queries remain responsive on 600k+ entry snapshots.
5. Source metadata, packaged app metadata, and privacy manifest are release-ready.
6. Full validation passes: unit tests, E2E, synthetic stress scan, live monitor, and a real full-home scan.

## Phase 0 — scan freeze and data correctness blockers

### #15 — Full scan freezes mid-run on large home directories

**Status:** in progress, still beta-blocking.

Current mitigations (`FTS_XDEV`, known path skips, more frequent `Task.yield()`) reduce risk but do not fully solve the root cause because `fts_read(tree)` remains a synchronous blocking call. Cancellation is only checked after `fts_read` returns.

**Fix plan:**

1. Keep the existing safe mitigations:
   - `FTS_XDEV`
   - skip `.photoslibrary` / `.photolibrary`, `Library/Mail`, Trash, Time Machine snapshots, saved app state
   - 10k-file yield interval
2. Make skip matching component-aware instead of raw substring matching so legitimate user folders are not skipped accidentally.
3. Add a scan progress watchdog:
   - track last yielded file / last progress timestamp from the scanner
   - if no scanner progress occurs for a configurable timeout, abort the scan and surface a recoverable scan error
   - cancellation must unblock the consumer, even if the underlying traversal worker is stuck
4. If a safe watchdog cannot reliably interrupt FTS, replace FTS traversal for beta with a cooperatively cancellable enumerator, or run FTS in an isolated worker that can be abandoned without blocking app state.
5. Add tests for skip behavior and cancellation behavior where possible; use stress/manual validation for actual FTS hangs.

**Acceptance:**

- Stop works during a long scan.
- A no-progress traversal timeout exits with a visible/recoverable error.
- Full-home scan no longer freezes at the previous ~600k-file failure point.

### #16 — Cancelled or failed full scan leaves partial working-set data

**Status:** must fix before beta.

`ScanService` deletes an incomplete snapshot on failure/cancel, but when `alsoWriteWorkingSet` is true, already-written working-set rows and category totals remain.

**Fix plan:**

1. Add a clear rollback strategy for failed full scans:
   - preferred: stage working-set writes per scan session and commit/promote only after scan completion
   - acceptable beta fix: on scan failure, rebuild the working set from the latest complete snapshot for that tracked path
   - if no previous snapshot exists, clear working-set rows/totals for that tracked path
2. Ensure category totals are also restored/cleared consistently.
3. Add regression coverage:
   - create prior good snapshot + working set
   - start a new scan that writes at least one working-set batch
   - force cancellation/failure
   - assert latest complete snapshot and working set still match

**Acceptance:**

- Cancel/failure never leaves hybrid old+new inventory.
- UI returns to last known good inventory after cancellation.

### #17 — Silent reconciliation can hang without visible cancel path

**Status:** must fix before beta.

Silent reconciliation can start a full scan from menu-bar load without visible progress/cancel. It inherits the #15 freeze risk.

**Fix plan:**

1. For beta, prefer the safest policy: disable silent full reconciliation and rely on explicit manual scans + FSEvents incremental refresh.
2. If silent reconciliation remains enabled:
   - add a wall-clock timeout
   - wire timeout to `ScanService.cancelScan()`
   - guarantee `isReconciling` and related UI state are reset in `defer`
   - expose some visible background-refresh status/cancel affordance if a full scan is running
3. Add tests for silent-reconcile state cleanup on cancellation/error.

**Acceptance:**

- Silent reconciliation cannot leave app state stuck forever.
- A background full scan has either a timeout or a user-visible stop path.

### #12 — Crash on first scan during beta audit

**Status:** must close with evidence before beta.

**Fix plan:**

1. Reproduce with a clean state under Xcode:
   - exception breakpoint
   - zombie objects if needed
   - capture crash report from `~/Library/Logs/DiagnosticReports/`
2. If not reproducible after the Phase 0 scan fixes, document exact validation steps and close only after a successful clean install → onboarding → first scan run.
3. Add regression coverage if a root cause is found.

**Acceptance:**

- First scan completes on clean state without crash.
- Issue has either a fix commit or a reproducible-validation closure note.

## Phase 1 — performance and responsiveness required for large beta datasets

### #22 — Improve cancellation responsiveness during large scan DB writes

**Fix plan:**

1. Reduce the outer scan batch from 50k to 5k–10k entries, or split `addEntriesCore` into smaller write transactions.
2. Add cancellation checkpoints between DB chunks/transactions.
3. Measure scan throughput before/after. Do not sacrifice 1M+ file performance unnecessarily; target responsive cancellation with acceptable throughput.

**Acceptance:**

- Stop returns promptly even while DB writes are active.
- 1M-file scan throughput remains acceptable.

### #21 — Use `pathClassification` SQL for snapshot subcategory breakdown

**Fix plan:**

1. Replace the snapshot-backed `getSubcategoryBreakdown` path that paginates all snapshot entries and classifies paths in Swift.
2. Use classification-backed SQL queries from `DatabaseManager`, or add a grouped SQL query that returns subcategory totals/counts/top files directly.
3. Keep the working-set path SQL-backed.
4. Add a performance/regression test with mixed-category snapshot data.

**Acceptance:**

- Drill-down warmup/opening time does not scale with unrelated snapshot rows.
- Large snapshots remain responsive.

### #9 — Investigate CPU 150% when app runs for extended periods

**Fix plan:**

1. Re-run the live monitor after Phase 0/1 scan changes:
   - `npm run monitor -- --samples 20 --interval 5`
   - optionally overnight run before release
2. Confirm whether CPU is caused by scanning, silent reconciliation, watcher churn, or UI loops.
3. Fix or mitigate any sustained idle CPU > expected baseline.

**Acceptance:**

- App can sit idle after scan without sustained high CPU.
- Overnight monitor has acceptable CPU/RSS and no runaway autoscan loop.

## Phase 2 — beta release hygiene

### #18 — Beta artifact metadata drifts from source build settings

**Fix plan:**

1. Decide canonical beta bundle ID.
2. Align `project.yml`, Makefile defaults domain, installed app, docs, and release artifact.
3. Align marketing/build versions.
4. Add a release check that compares built app metadata to expected values.

**Acceptance:**

- CI/local build produces the same bundle ID/version expected by release docs.

### #19 — Add app privacy manifest before beta distribution

**Fix plan:**

1. Add `Prunr/PrivacyInfo.xcprivacy`.
2. Declare no tracking and no collected data unless app behavior changes.
3. Verify the file is present in the built `.app` bundle.

**Acceptance:**

- Built app includes app-level privacy manifest.

### #20 — Replace production `print()` diagnostics with `Logger`

**Fix plan:**

1. Replace production service `print()` diagnostics with `OSLog.Logger`.
2. Keep CLI output in E2E/stress commands.
3. Use privacy annotations for paths and user data.

**Acceptance:**

- Production app diagnostics are visible through unified logging.
- No accidental stdout-only diagnostics in service paths.

## Phase 3 — beta polish, not a hard stability gate

### #13 — Drill-down file view: cap grown items list at 10 with expand action

**Plan:** keep in the beta polish queue. This should be fixed before a polished public beta if time permits, but it should not block Phase 0/1 stability work.

### #14 — Drill-down file view: growth contributor list stalls after initial files are visible

**Plan:** keep in the beta polish queue. Fix after the SQL drill-down performance work (#21), because #21 may reduce the underlying load time. UI should show a compact contributor skeleton or cached contributors immediately.

## Final validation checklist

Run before tagging a beta candidate:

```bash
swiftlint lint --strict --config .swiftlint.yml
make test
make e2e E2E_FILE_COUNT=5000
make stress-create STRESS_FILES=100000
make build
make stress-scan
make stress-repeat
npm run monitor -- --samples 20 --interval 5
```

Manual validation:

1. Clean install/reset state.
2. Onboard with home directory selected.
3. First full scan completes or exits with recoverable timeout/error.
4. Stop during scan leaves inventory consistent.
5. Drill into largest categories and subcategories; no long blank/popping sections.
6. Leave app running long enough for watcher/autoscan checks; CPU/RSS remain stable.
7. Verify packaged app metadata, signing, stapling, privacy manifest.

## Current beta decision

Do not distribute broad beta until Phase 0 and Phase 1 are complete, and Phase 2 release hygiene is complete. Phase 3 can be deferred only for a very small/internal beta if users are warned about drill-down polish issues.
