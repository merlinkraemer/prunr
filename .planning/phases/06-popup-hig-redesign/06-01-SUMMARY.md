# Phase 06-01 Summary

**Main popup redesigned with macOS system menu style: growth on right, folder name only, better header separation**

## Accomplishments

- Updated MenuBarView to 20pt margins (HIG standard) for header sections
- Redesigned footer buttons to match WiFi/Bluetooth system menus (6pt inset + rounded corners)
- Redesigned GrowthListView: icon + folder name on left, growth amount on right
- Created distinct header with "MONITORING" label + full path (no folder icon to differentiate from list)
- Added 12pt spacing below header for better visual separation
- Changed hover states to light gray with 6pt rounded corners (not full width)

## Files Created/Modified

- `Prunr/Views/MenuBarView.swift` - Updated header (MONITORING label + full path), 12pt bottom spacing, footer buttons with 6pt inset
- `Prunr/Views/GrowthListView.swift` - Folder name only, growth on right side, 6pt inset hover states
- `Prunr/Services/MenuBarManager.swift` - Added `monitoredPathDisplay` computed property with tilde notation

## User Feedback Implemented

1. ✅ **Growth on right side**: Growth amount + arrow now on right side of each item
2. ✅ **Header distinct from list**: "MONITORING" label + full path (no folder icon, different styling)
3. ✅ **Full scanned path**: Header shows full path (e.g., "~/dev/test_data") not just folder name
4. ✅ **Items show folder name only**: List items show just folder/file name (not full path - that's in header)
5. ✅ **Better header separation**: Added 12pt spacing below header to separate from list visually
6. ✅ **Footer hover states**: 6pt inset from edges + 6pt rounded corners like WiFi/Bluetooth
7. ❌ **Aggregation bug (ISS-020)**: Items not combining by parent folder - DEFERRED (requires BaselineService changes)

## Design Decisions

- 6pt corner radius for all hover states (footer buttons and list items)
- 6pt horizontal inset from edges (not full width, like system menus)
- 12pt bottom spacing on header for visual separation from list
- Header styling: "MONITORING" label (caption, semibold, secondary) + full path below (11pt, secondary)
- No folder icon in header (differentiates from list items which have icons)
- List items: Icon + folder name (left) ... growth amount (right)
- Tilde notation for home directory paths in header (e.g., "~/dev" instead of "/Users/username/dev")

## Technical Details

**MenuBarView changes:**
- Header: "MONITORING" label + full path (no folder icon - distinct from list items)
- Header styling: Caption font + semibold weight for label, 11pt secondary color for path
- Header spacing: 12pt bottom padding for visual separation from list
- Footer buttons: 6pt inset + 6pt rounded corners, light gray hover

**MenuBarManager changes:**
- Added `monitoredPathDisplay` computed property
- Returns full path with tilde notation (~/dev instead of /Users/username/dev)
- Converts home directory paths to tilde format automatically

**GrowthListView changes:**
- Layout: Icon (left) + folder name (left) ... growth amount (right)
- Folder name only: Shows `lastPathComponent` not full path
- Growth on right: Arrow + growth amount aligned to right edge
- Hover: 6pt inset + 6pt rounded corners (matches footer buttons)
- Row padding: 12pt horizontal + 6pt vertical
- Row height: 28pt minimum (standard menu row)

## Issues Encountered

**ISS-020 - Aggregation Bug**: Duplicate files show as separate items instead of aggregating by parent directory. This is a BaselineService bug, not UI. The `getGrowthList()` method needs to aggregate items by parent folder before returning results.

**Status:** Logged in ISSUES.md as High priority
**Fix required:** Modify `BaselineService.getGrowthList()` to group items by parent directory and sum their growth amounts

## User Approval

**Approved** ✅ - User verified visual design after multiple iterations:
- Growth amounts on right side
- Distinct header with "MONITORING" label + full path
- Footer buttons with 6pt inset + rounded corners
- List items show folder names only (full path in header)

## Next Step

Ready for 06-02-PLAN.md (Settings & About HIG compliance)

**Option:** Fix ISS-020 (aggregation bug) before continuing to Settings redesign if it affects workflow.

**MenuBarView changes:**
- Header: Folder icon + monitored path (replaced "What Grew" text)
- Header spacing: 12pt bottom padding for visual separation from list
- Footer buttons: 6pt inset + 6pt rounded corners, light gray hover

**GrowthListView changes:**
- Layout: Icon (left) + folder name (left) ... growth amount (right)
- Folder name only: Shows `lastPathComponent` not full path
- Growth on right: Arrow + growth amount aligned to right edge
- Hover: 6pt inset + 6pt rounded corners (matches footer buttons)
- Row padding: 12pt horizontal + 6pt vertical
- Row height: 28pt minimum (standard menu row)

## Next Step

Before 06-02 (Settings & About HIG compliance), consider fixing ISS-020 (aggregation bug) if it affects workflow. Otherwise, ready to proceed with Settings redesign.

Ready for 06-02-PLAN.md (Settings & About HIG compliance)
