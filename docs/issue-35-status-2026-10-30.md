# Issue #35 status (2026-10-30)

Issue #35 (constant ~70% CPU from an infinite full-scan retry loop) describes a tight loop that cannot happen in current main. Since Aug 19-20 (e67f674, 7ead213, aaba061) every full scan goes through `MenuBarManager.createBaselines`, which records the attempt time up front and, on failure, increments `consecutiveFailedFullScans`. The cooldown gate (`isWithinFullRescanCooldown`), the dirty-root and recent-change escalations, and the reconciliation backstop (`reconciliationBackstopDelay`) all measure from the last attempt, not the last success, with an exponential backoff of 60s doubling per failure. This closes Bug A and Bug B of docs/cpu-leak-analysis-2026-06-15.md. The failures are also now visible in diagnostics (`recordScanOutcome`, error code per failure).

Remaining gaps, fixed on branch `drain/Q9-2026-10-30`:

- The backoff was capped at 30 minutes with no give-up, so a scan that fails persistently after ~5 minutes of traversal (the 2.25M-file case) still burned roughly 15-20% duty cycle forever. The cap is now 6 hours (reached after 9 consecutive failures; any success resets it). Manual scans are never gated. Size: one constant.
- There was no test for the retry gate. `FullScanRetryBackoffTests` now asserts the backoff schedule and that repeated real scan failures keep the gate closed.

Not resolved (needs real data, Merlin): the original trigger, the `code=0` failure in the DB finalize phase on a home-sized scan, was never captured. If it still occurs on alpha.24 it will now show in `diagnostics.log` as `scans(success/failed/cancelled)` and the error code, and costs at most one scan per backoff step. Recommendation: leave #35 open until a tester diagnostics log shows no failed scans, then close.

Idle CPU: `IdleCPUTests` measures process CPU (getrusage) of a MenuBarManager with a baseline, watcher and reconciliation backstop armed, idle for 30s, and fails above 5% average. See the Q9 report for numbers. A true 24h run does not fit mac-queue (job timeout 2700s); it needs the real app with `npm run monitor` per issue #31 on a machine Merlin owns.
