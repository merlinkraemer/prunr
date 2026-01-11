# Phase 5 UAT Issues

**Date:** 2026-01-11
**Plan:** 05-05 (DaisyDisk-Style Scan Results)

## Issues

### 1. Sidebar path selection doesn't update view
**Severity:** High
**Expected:** Selecting different paths in sidebar updates the main content area
**Actual:** View doesn't change when selecting different paths
**Fix:** Selection change should trigger scan/check and update displayed content

---

### 2. No "Scan Now" button for empty state
**Severity:** Medium
**Expected:** When no snapshot exists for selected path, show "Scan Now" button
**Actual:** No clear action to create initial snapshot
**Fix:** Add empty state with "Scan Now" CTA when `deltas.isEmpty`

---

### 3. Growth bars all show as 100%
**Severity:** High
**Expected:** Growth bar should represent actual growth relative to something
**Actual:** All bars fill completely
**Questions:**
- What should the bar represent? (growth vs total size? growth vs largest growth? absolute scale?)
- Need design decision on bar semantics

---

### 4. Rescan fails on non-test-data folders
**Severity:** High
**Expected:** Clicking Rescan works for any folder
**Actual:** Only works for test_data, other folders show nothing
**Fix:** Debug scanner, check permissions, check error handling

---

### 5. Timeframe selector incomplete
**Severity:** Medium
**Expected:** 1h, 12h, 1d, 3d, 1w, 1m, custom options
**Actual:** Current selector has different options
**Fix:** Update ComparisonPicker with full timeframe range

---

### 6. No feedback when timeframe unavailable
**Severity:** Medium
**Expected:** Show when selected timeframe has no matching snapshot
**Actual:** Unclear what's being compared or if comparison is possible
**Fix:** Add "No snapshot from [timeframe] available. Showing [fallback]." messaging

---

### 7. Unclear what's being compared
**Severity:** Medium
**Expected:** Clear indication of "Comparing [now] vs [then]"
**Actual:** User doesn't know which snapshots are being compared
**Fix:** Add comparison summary header showing dates/times being compared

---

### 8. Fallback when no snapshot available
**Severity:** Low
**Question:** Should we show all files when no historical snapshot exists?
**Options:**
- Show current scan only with "No historical data" badge
- Show current files with 0 change
- Show empty state with "Scan, wait, then compare" message
