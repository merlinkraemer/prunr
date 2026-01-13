---
phase: 09-visual-improvements
plan: 02
completed: 2026-01-12
status: completed
---

# Column Alignment Fixes Implementation Summary

## Overview
Fixed critical column alignment issues in CategoryGrowthListView, addressing oversized columns, missing percentage displays for big file children, and category title alignment problems.

## Issues Resolved

### 1. Column Width Optimization
**Issue**: Columns were using excessive space, not sized to fit their actual content
**Solution**:
- Updated `ColumnWidths` enum with more appropriate dimensions:
  - `count`: 70pt (fits "9999 items" with space)
  - `size`: 90pt (fits "+999.9 GB" with arrow icon)
  - `name`: 140pt (flexible remaining space)
- Removed unnecessary fixed frame sizes that were creating gaps
- Used `.fixedSize()` on numeric displays to prevent expansion

### 2. Big Files Children Percentage Display
**Issue**: Big file children in drill-down view didn't show percentage differences
**Solution**:
- Updated `ItemRow` to display size with percentage badge
- Added conditional percentage badge showing contribution to parent folder
- Implemented smaller, more subtle styling for nested items
- Updated `NestedBigItemRow` to maintain consistent percentage display

### 3. Category Title Alignment Fix
**Issue**: Category titles in drill-down header weren't properly left aligned
**Solution**:
- Changed category title text style to `.foregroundStyle(.primary)`
- Added `.weight(.medium)` for better visual hierarchy
- Ensures consistent appearance with other category titles

## Technical Implementation Details

### Column Structure Changes
```swift
enum ColumnWidths {
    static let count: CGFloat = 70  // Fits "9999 items" with space
    static let size: CGFloat = 90   // Fits "+999.9 GB" with arrow icon
    static let name: CGFloat = 140 // Flexible remaining space
}
```

### Percentage Badge Implementation
```swift
// For main items
if let percent = String(format: "%.0f%%", item.percentOfParent * 100), item.percentOfParent > 0 {
    Text(percent)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 3))
}

// For nested items (smaller)
.padding(.horizontal, 3)
.padding(.vertical, 0)
.foregroundStyle(.tertiary)
.background(Color.tertiaryLabel.opacity(0.15))
```

## Results Achieved
- ✅ **Properly sized columns** that match content width without gaps
- ✅ **Consistent percentage display** across all item types (including big files children)
- ✅ **Consistent category title styling** with proper left alignment
- ✅ **Professional appearance** matching macOS Finder-style layout
- ✅ **No visual jumping** when switching between different data sets

## Verification
- Column boundaries are now stable and aligned
- Percentage badges appear consistently for all file types
- Visual hierarchy is maintained across main view and drill-down views
- All column headers are properly left-aligned with consistent styling

## Files Modified
- `Prunr/Views/CategoryGrowthListView.swift`: Updated all row implementations with optimized column widths and percentage displays
- `Prunr/Views/MenuBarView.swift`: Fixed category title alignment in drill-down header
- `Prunr/Models/GrowthItem.swift`: Created standalone GrowthItem model to resolve actor isolation issues

The column alignment fixes provide a much more polished and professional user experience, with all data properly aligned and formatted according to macOS design standards.