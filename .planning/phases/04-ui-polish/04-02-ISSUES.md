# UAT Issues: Phase 4 Plan 02

**Tested:** 2026-01-10
**Source:** .planning/phases/04-ui-polish/04-02-SUMMARY.md
**Tester:** User via /gsd:verify-work

## Resolved Issues

### UAT-001: Window can be resized to very small size ✅

**Discovered:** 2026-01-10
**Resolved:** 2026-01-10
**Phase/Plan:** 04-02-FIX
**Severity:** Minor
**Feature:** Window configuration
**Description:** Window can be resized to a very tiny size, ignoring expected minimum constraints
**Fix:** Added `.frame(minWidth: 600, minHeight: 400)` to MainView in PrunrApp.swift
**Verification:** Window now has minimum size constraint, cannot be resized smaller than 600x400

### UAT-002: Scan fails with "failed to create snapshot" error ✅

**Discovered:** 2026-01-10
**Resolved:** 2026-01-10
**Phase/Plan:** 04-02-FIX
**Severity:** Blocker
**Feature:** Scan Home Folder (Cmd+R)
**Description:** Pressing Cmd+R triggers scan but it fails with error message
**Root Cause:** Snapshot and SnapshotEntry conformed to `PersistableRecord` instead of `MutablePersistableRecord`, preventing `insert()` from mutating the struct to populate the auto-incremented id
**Fix:** Changed conformance to `MutablePersistableRecord` and updated DatabaseManager to use `var entry` instead of `let entry`
**Verification:** Scan completes successfully, snapshot is created with valid id, appears in UI pickers

### UAT-003: Refresh Snapshots command does nothing ✅

**Discovered:** 2026-01-10
**Resolved:** 2026-01-10
**Phase/Plan:** 04-02-FIX
**Severity:** Major
**Feature:** View > Refresh Snapshots (Cmd+Shift+R)
**Description:** Menu item exists but pressing Cmd+Shift+R or clicking menu item has no visible effect
**Fix:** Added `refreshSnapshots()` method to MainViewModel that preserves selection by ID, then restores selection and re-triggers comparison
**Verification:** Refresh reloads snapshots while preserving current selection, deltas update if selection remains valid

## Open Issues

None - all issues resolved!

---

*Phase: 04-ui-polish*
*Plan: 02*
*Tested: 2026-01-10*
*All issues resolved: 2026-01-10*
