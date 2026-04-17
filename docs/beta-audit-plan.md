# Beta Audit Plan

## Beta audit triage (2026-04-17)

Checkpoint: `059bafd` (`chore: checkpoint beta audit state`)
Source: [docs/beta-audit-2026-04-17.md](/Users/merlinkraemer/dev/projects/prunr/docs/beta-audit-2026-04-17.md)

### Outcome target

- [ ] Clear all audit P0 items before beta.
- [ ] Pull in only the P1 changes that share touched code or materially reduce beta risk.
- [ ] Keep each implementation step small enough for a standalone checkpoint commit.

### Atomic task list

- [ ] A01 Exclude `~/Library/Application Support/Prunr` from watcher roots before stream creation; keep SQLite sidecar filtering (`-wal`, `-shm`, `-journal`) as a secondary defense only.
- [ ] A02 Remove or move the scan-complete `FSEventStreamFlushSync` so scan-finish does not immediately replay self-generated DB events into a fresh rescan.
- [ ] A03 Replace `workingSetCategoryTotal` read-modify-write loops with single-statement SQL delta updates.
- [ ] A04 Remove the extra `RunLoop.main.perform { MainActor.assumeIsolated { ... } }` wrapper from the FSEvents handoff and make refresh scheduling single-dispatch on the main actor.
- [ ] A05 Pass live `SettingsStore.enabledBoundaries` into `BaselineService` so scan stop-drill-down logic matches user settings.
- [ ] A06 Make snapshot cleanup cancellation-safe with `defer` plus cooperative cancellation checks, so incomplete snapshots are reliably deleted on success, failure, or cancel.
- [ ] A07 Propagate cancellation into `RecentChangeService` so incremental refreshes stop when scans are cancelled.
- [ ] A08 Move orphan cleanup into the same transactional scope as subtree replacement writes, so cleanup only sees committed final state.
- [ ] A09 Make complex DB migrations idempotent with schema/existence guards and transaction boundaries, especially v7 and v10; use savepoints only for optional substeps.
- [ ] A10 Add `UNIQUE(snapshotId, category)` and `UNIQUE(snapshotId, category, subcategory)` constraints, then convert replace paths to UPSERT.
- [ ] A11 Add sleep/wake and mount/unmount lifecycle observers on `NSWorkspace.shared.notificationCenter`, and gate watcher/autoscan restart behavior behind those transitions.
- [ ] A12 Surface `SMAppService` register/unregister failures in settings instead of swallowing them with `print()`, and derive UI state from the service status.
- [ ] A13 Replace drill-down wall-clock timing with animation completion, remove or narrow implicit header animations that bleed into the transition, and avoid `Task.sleep` as coordination.
- [ ] A14 Delete dead `PathManager.swift` or isolate its defaults key so it cannot corrupt `trackedPaths`.
- [ ] A15 While touching DB bootstrap code, set explicit connection invariants: `journal_mode=WAL`, `foreign_keys=ON`, and add a corruption-recovery plan instead of hard failure.
- [ ] A16 Add focused regression coverage for watcher noise filtering, rescan re-entrancy, boundary propagation, cancellation cleanup, migration idempotency, and snapshot uniqueness.

### Phased integration plan

- [ ] Phase 1: Stop self-inflicted scan storms with A01-A04.
  Exit gate: `make build`, targeted watcher/recent-change tests, `npm run monitor -- --samples 20 --interval 5`, manual check that scan completion no longer triggers an immediate follow-up scan.
- [ ] Phase 2: Restore scan correctness under cancellation and concurrent writes with A06-A08 and A16 coverage for those paths.
  Exit gate: `make test`, manual cancel-during-scan exercise, verify no orphan snapshots and no fresh rows removed by cleanup.
- [ ] Phase 3: Restore user-configured scan behavior and app lifecycle handling with A05, A11, and A12.
  Exit gate: manual settings toggle test, app sleep/wake cycle, external drive mount/unmount smoke test, launch-at-login failure path visible in UI.
- [ ] Phase 4: Harden the database layer with A09, A10, A15, and the matching A16 migration/schema tests.
  Exit gate: migration test pass from partial-failure fixtures, clean launch on existing DB, duplicate snapshot rows impossible after interrupted replace flows.
- [ ] Phase 5: Close remaining beta polish blockers with A13 and A14.
  Exit gate: manual drill-down flicker repro no longer reproduces, settings/open-close smoke test, no duplicate defaults key remains in the codebase.
- [ ] Phase 6: Re-run the full beta readiness pass after Phases 1-5 land.
  Exit gate: `make build`, `make test`, `npm run monitor -- --samples 20 --interval 5`, clean install smoke test, overnight idle CPU/RSS check.

### Integration notes

- [ ] Keep Phase 1 isolated from schema changes; prove the CPU/rescan loop is fixed before touching migrations.
- [ ] Land Phase 4 behind its own checkpoint commit because schema changes have the highest rollback cost.
- [ ] Only pull P1 items into a phase when they directly reduce risk in files already being changed; otherwise leave them for post-beta.
- [ ] Treat savepoints as optional migration substeps only; use transaction boundaries and schema guards as the primary safety mechanism.
- [ ] After each phase, record actual verification results and the checkpoint commit hash in the review section below.

### Review

- Plan shape: fix the feedback loop first, then correctness/cancellation, then lifecycle/settings, then schema hardening, then UI polish.
- Highest leverage early win: A01-A04 should address the audit's main 150% CPU / repeated rescan cluster before wider refactors.
- Highest risk phase: A09-A10-A15 because migration mistakes can brick existing beta installs; this phase needs fixture-based verification, not just app launch.
