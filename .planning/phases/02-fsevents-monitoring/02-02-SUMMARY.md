# Phase 2 Plan 02: FSEvents Watcher Summary

**Created FSEvents-based file system watcher with debounce and lifecycle service integration.**

## Performance

- **Duration:** 25 min
- **Started:** 2026-01-11
- **Completed:** 2026-01-11
- **Tasks:** 3
- **Files created/modified:** 4

## Accomplishments

- Created FSEventsWatcher actor with FSEventStream management
- Implemented 3-second debounce to prevent rescan spam
- Created FSEventsService for lifecycle management
- Integrated FSEvents watching into MenuBarManager
- FSEvents detects and logs file system changes

## Task Commits

Each task was committed atomically:

1. **Task 1: Create FSEventsWatcher actor with stream and debounce** - `56c62f7` (feat)
2. **Task 2: Create FSEventsService for lifecycle management** - `33b338c` (feat)
3. **Task 3: Integrate FSEventsService with MenuBarManager** - `1a9d16b` (feat)

**Plan metadata:** `88a862a` (docs)

_Note: No TDD tasks in this plan_

## Files Created/Modified

- `Prunr/Services/FSEventsWatcher.swift` - FSEventStream wrapper with debounce
- `Prunr/Services/FSEventsService.swift` - Lifecycle management service
- `Prunr/Services/MenuBarManager.swift` - Added FSEvents integration
- `Prunr.xcodeproj/project.pbxproj` - Added new files to Xcode project

## Decisions Made

- **3-second debounce** (within 2-5s requirement from ROADMAP)
- **FSEventStream with 0.5s latency** for responsiveness
- **Actor isolation** for thread-safe stream management
- **Async startWatching** for proper actor isolation
- **RunLoop.Mode.default** for run loop scheduling
- **Log changes for now** (full integration in Phase 3)

## Issues Encountered

### Build Errors Fixed

1. **FSEventStreamCreate API**: Fixed parameters for correct types
   - Used `UInt64(kFSEventStreamEventIdSinceNow)` for event ID
   - Used `FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)` for flags

2. **Actor isolation**: Made `startWatching` async in FSEventsService
   - Required `await` when calling `setOnChange` on actor

3. **RunLoop mode scheduling**: Used `RunLoop.Mode.default.rawValue as CFString`
   - `kCFRunLoopDefaultMode` is obsolete in Swift

4. **Memory pointer handling**: Fixed event path extraction from C callback
   - Used `assumingMemoryBound(to:)` correctly for opaque pointers

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed FSEventsWatcher compilation issues**

- **Found during:** Task 1 (build verification)
- **Issue:** Multiple FSEvents API type mismatches and actor isolation errors
- **Fix:** Rewrote FSEventsWatcher with correct CoreServices API usage
- **Files modified:** Prunr/Services/FSEventsWatcher.swift, Prunr/Services/FSEventsService.swift
- **Verification:** Build succeeded after fixes
- **Committed in:** `1a9d16b` (part of Task 3 commit)

### Deferred Enhancements

None

---

**Total deviations:** 1 auto-fixed (blocking), 0 deferred
**Impact on plan:** Fix was necessary for build to succeed. No scope creep.

## Next Phase Readiness

- FSEvents monitoring infrastructure complete
- Permission detection available from 02-01
- Boundary patterns defined for drill-down (Phase 3)
- Ready for **Phase 03: Baseline & Growth Tracking**

---

*Phase: 02-fsevents-monitoring*
*Plan: 02-02*
*Completed: 2026-01-11*
