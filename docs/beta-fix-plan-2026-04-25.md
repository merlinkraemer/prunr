# Beta Fix Plan — 2026-04-25 (Updated)

## Verdict

**All Phase 0–3 fixes are complete and validated.** The app is ready for limited/internal beta. The remaining gates are release artifact hygiene (#18) and a manual end-to-end smoke test.

Validated before this update:

- `swiftlint lint --strict --config .swiftlint.yml` — 0 violations
- `make test` — 50/50 tests passed
- `make e2e E2E_FILE_COUNT=5000` — 10/10 phases passed
- `make stress-create STRESS_FILES=100000 && make stress-scan && make stress-repeat` — passed
- Idle CPU validation: dropped from ~100% to ~0.01% after disabling the automatic file watcher
- RSS at idle: stabilized around ~50 MB after lazy `NSHostingView` teardown
- built app metadata verified: `com.prunr.app`, `0.1.3 (2)`
- built app includes `Contents/Resources/PrivacyInfo.xcprivacy`

## Release gate definition

A beta candidate is acceptable only when:

1. Manual Stop/cancel reliably recovers from long scans. ✅
2. A failed/cancelled scan cannot corrupt or partially update visible inventory data. ✅
3. Silent/background refresh cannot hard-freeze the app without a user escape hatch. ✅
4. Drill-down queries remain responsive on 600k+ entry snapshots. ✅
5. Source metadata, packaged app metadata, and privacy manifest are release-ready. ⚠️ #18
6. Full validation passes: unit tests, E2E, synthetic stress scan, live monitor, and a real full-home scan. ⚠️ manual smoke test pending

## Phase 0 — scan freeze and data correctness blockers ✅

### #15 — Full scan freezes mid-run on large home directories

**Status:** resolved.

Mitigations applied (`FTS_XDEV`, known path skips, more frequent `Task.yield()`, 5k–10k batch sizes). Cancellation checkpoints added between DB chunks. Full-home scans no longer freeze at the previous ~600k-file failure point.

### #16 — Cancelled or failed full scan leaves partial working-set data

**Status:** resolved.

`ScanService` now rolls back working-set rows and category totals on failure/cancel by rebuilding from the latest complete snapshot, or clearing the working set if no prior snapshot exists.

### #17 — Silent reconciliation can hang without visible cancel path

**Status:** resolved for beta.

Silent full reconciliation is disabled for the beta. The app relies on explicit manual scans. When re-enabled post-beta, it must include a wall-clock timeout and visible cancel affordance.

### #12 — Crash on first scan during beta audit

**Status:** resolved.

Clean-install first-scan path hardened. No crash reproduced in validation.

## Phase 1 — performance and responsiveness ✅

### #22 — Improve cancellation responsiveness during large scan DB writes

**Status:** resolved.

Scan batch size reduced and cancellation checkpoints added between DB transactions. Stop returns promptly even during large writes.

### #21 — Use `pathClassification` SQL for snapshot subcategory breakdown

**Status:** resolved.

Snapshot-backed `getSubcategoryBreakdown` replaced with classification-backed SQL queries. Drill-down performance no longer scales with unrelated snapshot rows.

### #9 — Investigate CPU 150% when app runs for extended periods

**Status:** resolved.

Root cause: `FSEventsWatcher` triggered `RecentChangeService` → DB → full working-set replacement in a tight loop. Fixed by disabling the automatic file watcher for beta and adding lazy `NSHostingView` teardown on popover close. Idle CPU now ~0.01%, RSS ~50 MB.

## Phase 2 — beta release hygiene

### #18 — Beta artifact metadata drifts from source build settings

**Status:** partially resolved.

`project.yml`, `Makefile`, and source build output are aligned to `com.prunr.app`, `0.1.3 (2)`. The checked-in signed `Prunr.app` artifact still uses the old bundle ID and must be rebuilt/replaced before distribution.

### #19 — Add app privacy manifest before beta distribution

**Status:** resolved.

`Prunr/PrivacyInfo.xcprivacy` added and verified in the built `.app` bundle.

### #20 — Replace production `print()` diagnostics with `Logger`

**Status:** resolved.

Production service diagnostics now use `OSLog.Logger` with privacy annotations.

## Phase 3 — beta polish ✅

### #13 — Drill-down file view: cap grown items list at 10 with expand action

**Status:** resolved.

Growth contributors capped at 10 with a "Show more" expand action. Existing "load more" pagination for non-growth files remains intact.

### #14 — Drill-down file view: growth contributor list stalls after initial files are visible

**Status:** resolved.

Contributor prefetch now gates correctly on data availability. Contributors render with the initial file list instead of popping in later.

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

All code-fix phases are complete. **Do not distribute broad beta until:**
- #18 is closed (artifact rebuilt and metadata verified)
- The manual smoke test above is completed successfully
- Consider making the repo public so GitHub branch protection can be enabled
