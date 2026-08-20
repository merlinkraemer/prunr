# Session Handoff — Prunr CPU Investigation

**Date:** 2026-06-11  
**Status:** Mechanism confirmed; attempting unredacted error capture

## Problem

Prunr CPU spikes to ~70% constant, driven by an **infinite full-scan retry loop**:
- Full scans complete the entire 2.25M-file traversal (~6 min)
- Fail in the final DB-write phase with `Unknown scan error domain=<private> code=0`
- Since `lastFullScanCompletedAt` is never advanced, the cooldown gate stays open permanently
- FSEvents + reconciliation backstop continuously re-trigger expensive scans

## Root Cause Puzzle: `code=0`

**Empirically verified:** `code=0` in NSError bridging → a **custom enum `Error`'s first case** (enum cases = code 0, 1, 2...; struct errors → code 1; CustomNSError → domain-specific code).

**The contradiction:**
- `code=0` must be an enum's first case
- Only enum reachable in scanBody's catch is `DatabaseError.directoryNotFound` (code 0)
- But `directoryNotFound` is thrown ONLY in `initialize()`, never the write path
- Alternative enums checked and ruled out: `EncodingError` → code 4866, `CancellationError` → code 1, GRDB errors → SQLite codes

**Status:** Ground truth unredacted error string needed to resolve.

## Diagnostic Patch Applied

**File:** `Prunr/Services/ScanService.swift:522`  
**Change:** Added unredacted logging:
```swift
logger.error("Unknown scan error domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public): \(error.localizedDescription, privacy: .public) | reflect=\(String(reflecting: error), privacy: .public)")
```

## Attempt 1: Debug Build from /tmp

**Result:** TCC permissions issue
- Moved installed app to `Prunr.app.bak` to prevent launchd respawn
- Built Debug config to `/tmp/prunr-dd/...`, unredacted patch included
- Ran directly; traversals returned 0 files, then 167 files (permission denied at root; no Full Disk Access grant on dev-signed binary)
- Incomplete test — need full 2.25M-file scan to reach the actual write failure

**Files involved:**
- `/tmp/prunr-stream3.log` — unified log capture (no unredacted error yet; 0/167-file scans don't hit the write phase)
- Patch is in working tree `ScanService.swift`

## Next Steps

**Option A (recommended):** Apply patch to release build
1. Rebuild as **Release** config (or copy installed app to `/tmp`, sign with dev cert, patch, use)
2. Overwrite `/Applications/Prunr.app` or run patched release from /tmp with Full Disk Access
3. Let full scan (2.25M files) traverse and fail; capture unredacted error

**Option B:** Grant TCC to debug binary
1. Add entitlements to debug app or use `tccutil grant` to grant Full Disk Access
2. Rerun debug build; full scan should complete; error captured

**Option C (lower priority):** Search codebase for other `Error` enums
- Grep showed: `ScanError` (first case `.cancelled`?), `StressCommandError`, `BaselineError`, GRDB's `RecordError`
- Check if any of these are reachable in the write path

## Cleanup Required

- `/Applications/Prunr.app.bak` must be restored to `/Applications/Prunr.app` when done
- Unredacted patch in `ScanService.swift` should remain until error is captured, then possibly keep (or revert to privacy:default after fix is shipping)

## Files to Resume With

- **Prunr/Services/ScanService.swift** — unredacted patch at line 522, ready to rebuild
- **~/Library/Logs/Prunr/diagnostics.log** — historical tester data (large, already extracted)
- **/tmp/prunr-stream3.log** — live capture of debug run (up to 16:11)
