# Phase 3 Plan 01: Baseline & Growth Tracking Summary

**Created BaselineService for single baseline management with smart drill-down algorithm using 70% threshold and boundary-aware stopping.**

## Accomplishments

- Created BaselineService actor with baseline lifecycle (create, reset, get)
- Implemented getGrowthList with 70% threshold drill-down algorithm
- Added boundary-aware drill-down that stops at generated content folders
- Integrated FSEvents detection with baseline service for future auto-rescans
- Added BoundaryConfig.swift and BaselineService.swift to Xcode project

## Files Created/Modified

### Created
- `Prunr/Services/BaselineService.swift` - Baseline management and growth list calculation
  - `createBaseline(trackedPath:)` - Creates baseline snapshot and stores ID in UserDefaults
  - `getCurrentBaseline()` - Retrieves current baseline snapshot
  - `resetBaseline()` - Clears baseline from storage and database
  - `hasBaseline()` - Checks if baseline exists
  - `getGrowthList(trackedPath:)` - Calculates growth list with 70% threshold
  - `drillDown(path:trackedPath:)` - Boundary-aware drill-down for subdirectories
  - `GrowthItem` struct - Identifiable growth data with percent of parent calculation
  - `BaselineError.noBaseline` - Error for missing baseline

- `Prunr/Models/BoundaryConfig.swift` - Boundary folder configuration (already existed, added to project)
  - 20+ standard boundary patterns (node_modules, .git, build/, etc.)
  - `shouldStopDrillDown(at:)` - Tests if a path should stop drill-down

### Modified
- `Prunr/Services/MenuBarManager.swift` - FSEvents integration updated
  - Added `baselineService` reference
  - Updated FSEvents callback to check for baseline and detect changes under tracked paths
  - Logging for detected changes (Phase 4 will add actual rescan triggering)

- `Prunr.xcodeproj/project.pbxproj` - Added new files to project
  - BaselineService.swift in Services group
  - BoundaryConfig.swift in Models group

## Decisions Made

**Single baseline design per MVP roadmap decision** - Using UserDefaults for baseline ID storage is simple and sufficient for the MVP's single-baseline requirement. No complex multi-baseline tracking needed.

**70% threshold algorithm** - Growth items are included if they represent >= 70% of parent growth OR if they are direct children. This surfaces meaningful contributors without overwhelming noise.

**Boundary-aware drill-down** - Stops at known generated content folders (node_modules, .git, build/, etc.) using BoundaryConfig to prevent wasting resources scanning dependency directories.

## Issues Encountered

- **BaselineService.swift and BoundaryConfig.swift not in Xcode project** - Initially created the files but they weren't added to the Xcode project structure. Fixed by manually editing project.pbxproj to add:
  - PBXBuildFile entries for compilation
  - PBXFileReference entries for file references
  - Group memberships (Services and Models)
  - Sources build phase entries

## Implementation Notes

- Uses actor isolation for thread-safe baseline and growth operations
- @MainActor property `isCreatingBaseline` for UI state updates
- Leverages existing DatabaseManager.calculateDeltas() for SQL-based comparison
- Integrates with ScanService for scanning operations
- Growth list sorted by growthBytes descending for prioritized display
- Drill-down filters to children of given path and stops at boundary folders

## Next Step

Ready for **Phase 04: Menu Bar UI** - growth list popover with drive bar
