# Scan hardening review — e67f674..fe9c963

**Date:** 2026-08-21
**Status:** findings B/A/E/C + minors implemented (see `docs/todo.md`); D remains a release decision
**Scope:** the 8 commits after `docs/alpha-feedback-funnel-2026-08-19.md` landed

## Commits reviewed

```
fe9c963 fix: batch cache owners and resolve chrome icons     ← unrelated
776e9bf feat: show native cache application icons            ← unrelated
14f7c30 fix: polish glass drilldowns and cache grouping      ← unrelated
7ead213 fix: protect sync state during failed scans          ← post-release hardening
50a52a0 chore: checkpoint pre-alpha sync work                ← unrelated (screenshots)
8be3c8e fix: publish sparkle appcast with pages
97a9427 release: v0.1.5-alpha.10 build 11                    ← cut BEFORE 7ead213
e67f674 fix: harden alpha scan recovery and settings         ← the plan, all 8 slices
```

`e67f674` implements all eight slices. `7ead213` is follow-up hardening that introduced
two of the defects below. **alpha.10 was cut between them**, so shipped users have
`e67f674` without `7ead213`.

Test suite: `xcodebuild -scheme Prunr -destination 'platform=macOS' test` → 86 tests,
0 failures. None of findings A, B, or E are reachable from the current suite — they are
all timing-dependent.

---

## A — Launch race deletes in-flight scans

**Severity:** critical · **Introduced:** `7ead213`

`Prunr/PrunrMenuBar.swift:41-47` starts two tasks concurrently at launch:

```swift
Task { @MainActor [menuBarManager] in
    await menuBarManager.configureMonitoringOnLaunch()   // can start a scan
}
Task.detached(priority: .utility) {
    _ = try? await DatabaseCleanupService.shared.cleanupAbandonedSnapshots()  // NO idle gate
    await DatabaseCleanupService.shared.performStartupMaintenance()           // has idle gate
}
```

`7ead213` widened the cleanup query (`Prunr/Services/DatabaseCleanupService.swift:176-192`)
to include `WHERE s.lifecycle != 'complete'`. `ScanService` now creates snapshots with
`lifecycle: .scanning` and only promotes them at the very end, so that clause
unconditionally matches the snapshot a *running* scan is writing.

Failure chain:

1. Live snapshot row is deleted mid-scan.
2. FKs are ON with `onDelete: .cascade` (`DatabaseManager.swift:55, 104, 183, 275, 330`),
   so its `snapshotEntry` rows are destroyed too.
3. Subsequent entry inserts throw `SQLITE_CONSTRAINT_FOREIGNKEY`.
4. `markSnapshotComplete(id:)` issues an `UPDATE` with **no rowcount check**, so 0 rows
   updated reports success.

Net result is either silent data loss or a scan failure with a misleading error. This is a
plausible new generator of the unresolved `code=0` failure class.

`compactDatabaseNow()` (`DatabaseCleanupService.swift:217`) calls it ungated as well.
`performAutoCleanup()` does not — that path is fine.

### Fix

Three independent changes, all needed:

**1. Don't treat a fresh `scanning` snapshot as abandoned.** Add a staleness threshold to
the lifecycle clause so only snapshots old enough to imply process death qualify:

```swift
private static let abandonedScanGracePeriod: TimeInterval = 15 * 60

// in the SQL:
WHERE (s.lifecycle != ? AND s.createdAt < ?)
   OR (s.trackedPathId != ''
       AND ws.latestWorkingSetUpdate IS NOT NULL
       AND s.createdAt > ws.latestWorkingSetUpdate)

// arguments:
[Snapshot.Lifecycle.complete.rawValue,
 Date().addingTimeInterval(-Self.abandonedScanGracePeriod)]
```

**2. Gate the launch call.** In `PrunrMenuBar.swift`, either move
`cleanupAbandonedSnapshots()` inside `performStartupMaintenance()` (which already waits
for idle) or wrap it in the same `waitForAppToBeIdle` call.

**3. Make `markSnapshotComplete` fail loudly.** In `DatabaseManager.swift`:

```swift
func markSnapshotComplete(id: Int64) async throws {
    guard let dbPool = dbPool else { throw DatabaseError.notInitialized }
    try await dbPool.write { db in
        try db.execute(sql: "UPDATE snapshot SET lifecycle = ? WHERE id = ?",
                       arguments: [Snapshot.Lifecycle.complete.rawValue, id])
        guard db.changesCount == 1 else {
            throw DatabaseError.snapshotVanished(id)
        }
    }
}
```

---

## B — Any FTS error kills the whole scan

**Severity:** severe · **Introduced:** `7ead213`

`Prunr/Services/FileScanner.swift:216-228`:

```swift
case FTS_DNR, FTS_ERR, FTS_NS:
    let errno = entry.pointee.fts_errno
    ...
    if errno == EACCES || errno == EPERM {
        continuation.finish(throwing: ScanError.permissionDenied(path))
    } else {
        continuation.finish(throwing: ScanError.traversalFailed(path))
    }
    return
```

Previously this logged and continued. Now a single `ENOENT` — a file vanishing
mid-traversal, which is routine in `~/Library/Caches` — aborts the entire scan.
`FTS_NS` (stat failed) is fatal too.

The intent behind `ScanError.traversalFailed` ("the previous inventory was kept so
unreadable files are not mistaken for deletions") is correct. The blast radius is not.
Combined with s1's backoff, the user-visible symptom is "scans quietly stop happening."

Also: `let errno = entry.pointee.fts_errno` shadows the global `errno`.

### Fix

Abort only on errors that mean the resulting inventory would be systematically wrong;
skip and continue on transient per-entry errors.

```swift
case FTS_DNR, FTS_ERR, FTS_NS:
    let entryErrno = entry.pointee.fts_errno
    if entryErrno != 0 {
        let message = String(cString: strerror(entryErrno))
        Self.logger.error("FTS error at \(path, privacy: .public): \(message, privacy: .public)")
    } else {
        Self.logger.error("FTS error at \(path, privacy: .public)")
    }

    switch entryErrno {
    case ENOENT, ESTALE:
        continue                      // entry vanished mid-scan; not our problem
    case EACCES, EPERM:
        continuation.finish(throwing: ScanError.permissionDenied(path))
        return
    default:
        continuation.finish(throwing: ScanError.traversalFailed(path))
        return
    }
```

Consider counting skipped entries and surfacing the total in the diagnostics window line,
so a directory that is silently unreadable still shows up.

---

## C — Diagnostics log write went O(1) → O(n) on the MainActor

**Severity:** moderate · **Introduced:** `e67f674` (s5)

`Prunr/Extensions/PerfSignpost.swift`, `append()`:

```swift
let existing = (try? Data(contentsOf: url)).map {
    Data(Self.redactingFilesystemPaths(in: String(decoding: $0, as: UTF8.self)).utf8)
} ?? Data()
let data = Data(Self.redactingFilesystemPaths(in: line).utf8)
let bounded = Self.newestCompleteRecords(in: existing + data, maximumBytes: Self.maximumLogBytes)
try? bounded.write(to: url, options: .atomic)
```

Every flush reads the full file (up to `maximumLogBytes = 1_000_000`), runs
`NSRegularExpression` over the whole megabyte, concatenates, re-bounds, and atomically
rewrites — on the MainActor. It was `FileHandle` seek-to-end + write before. Re-redacting
already-redacted content is also pure waste.

### Fix

Redact on write only, append via `FileHandle`, and rewrite only when the file actually
exceeds the cap:

```swift
private func append(_ text: String) {
    guard let url = logFileURL else { return }
    let line = text.hasSuffix("\n") ? text : text + "\n"
    let data = Data(Self.redactingFilesystemPaths(in: line).utf8)

    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
        return
    }

    rotateIfNeeded(url: url)
}

/// Only pays the read-rewrite cost when the file is actually over the cap.
private func rotateIfNeeded(url: URL) {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    guard let size, size > Self.maximumLogBytes else { return }
    guard let existing = try? Data(contentsOf: url) else { return }
    let bounded = Self.newestCompleteRecords(in: existing, maximumBytes: Self.maximumLogBytes)
    try? bounded.write(to: url, options: .atomic)
}
```

---

## D — `privacy: .public` unredaction shipped in alpha.10

**Severity:** privacy regression, already fixed on main · **Introduced:** `e67f674`,
**reverted:** `7ead213`

`e67f674` committed the temporary diagnostic at `ScanService.swift:~511` that logs
filesystem paths as `.public`. `7ead213` reverted it — but `97a9427` (alpha.10) sits
between the two commits, so alpha.10 contains it.

Scope: on-device unified log only, never transmitted by Prunr. But it is visible in
Console.app and lands in any sysdiagnose. Given the project's own rule — *no file names,
paths, or folder names ever leave the machine* — a sysdiagnose attached to a support
thread would violate it.

### Fix

No code change needed; main is clean. This is a release decision:

- **Respin alpha.10** as alpha.11 off current main, or
- **Leave it** and avoid asking alpha users for sysdiagnoses until the next build ships.

Process change worth making either way: cut releases from a commit that has had its
temporary diagnostics stripped, and grep for `privacy: .public` in the release checklist.

---

## E — Cleanup gating still misses `isReconciling`

**Severity:** minor, same shape as A · **Pre-existing, worsened by** `e67f674`

`runDeferredAutoCleanupIfNeeded` (`MenuBarManager.swift:3442`) and `isAppBusy`
(`DatabaseCleanupService.swift:355-369`) do not check `isReconciling`. s2 added that flag
to `performRecentChangeRefresh`'s guard but did not propagate it here. More consequential
now that reconciliation writes staged snapshots.

### Fix

`DatabaseCleanupService.isAppBusy()`:

```swift
return manager.isLoading
    || manager.isAutoScanning
    || manager.isAnalyzingChanges
    || manager.isCleaningUp
    || manager.isReconciling          // add
    || manager.isInventoryRefreshInProgress   // add — same reasoning
```

Apply the same addition to `runDeferredAutoCleanupIfNeeded`'s guard.

---

## Minor

| Where | Issue | Fix |
|---|---|---|
| `SettingsView.swift:294-318` | `feedbackNotice.hasPrefix("Could not")` used as the error-state sentinel | Track state in a `Bool` or small enum alongside the message string |
| `PerfSignpost.swift` redaction regex | `#"/(?:Users\|Volumes)(?:/[^\s\]\[\(\),;\"']*)?"#` doesn't cover `~/` tilde paths | Add a `~/…` alternation |
| `PerfSignpost.swift:53` | `DiagnosticsAppContext.scopePaths` stores real paths although only `.count` is read (`:381`) | Store `scopePathCount: Int` instead — removes the footgun entirely |

---

## Verified clean

- **s1 backoff** — `min(60 * 2^(n-1), 1800)`; `recordFullScanAttempt()` advances
  `lastFullScanAttemptAt` on *every* attempt and both cooldown checks consult it.
- **s2 concurrency** — shared `isCancelled` replaced by `[UUID: ScanCancellationToken]`
  keyed per scan; `onCancel:` calls the token directly rather than hopping to the actor.
- **s3 counters** — `diagnosticErrorCode(for:)` emits enum case + numeric code only, never
  `localizedDescription`. Privacy rule satisfied.
- **s4/s5** — scope summary is `roots=N enabled=… watched=…` with no paths;
  `newestCompleteRecords` correctly re-bases `Data` slice indices.
- **Migration v20** — `.notNull().defaults(to: complete)`, tolerant `init(row:)` decode.
  Both snapshot read paths filtered (`DatabaseManager.swift:780, 811`) — the only two
  `Snapshot.all()` queries. Publish-last ordering correct.
- **s6 `website/api/feedback.js`** — size caps, UUID regex on `installId`, base64
  round-trip check, `escapeHtml`, `replyTo` only when supplied, correct
  405/413/400/401/500/502. Absent origin policy is deliberate and correct for a native
  client.
- **s7 `FeedbackService`** — install ID is a random UUID persisted to `UserDefaults`,
  never hardware-derived.

---

## Suggested order

1. **B** — smallest diff, biggest user-visible win (scans stop failing spuriously)
2. **A** — three changes: staleness threshold, idle gate, rowcount check
3. **E** — two-line addition
4. **C** — perf only
5. **D** — release decision, not a code change

## Test gaps to close alongside

`testStartupCleanupDeletesAbandonedNewerSnapshot` asserts the deletion behaviour from
`7ead213` but instantiates no concurrent scan, so it passes *because of* Finding A rather
than despite it. Worth adding:

- A `scanning` snapshot created seconds ago survives `cleanupAbandonedSnapshots()`.
- A `scanning` snapshot older than the grace period is still deleted.
- `markSnapshotComplete` throws when the row is gone.
- `FileScanner` completes a scan when a file disappears mid-traversal.
