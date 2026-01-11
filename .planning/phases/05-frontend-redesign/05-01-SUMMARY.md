# Phase 5 Plan 01: Models and Persistence Summary

**Created foundational data models for the Finder-style sidebar with UserDefaults persistence.**

## Accomplishments

- **TrackedPath model**: Codable struct for user-configurable scan paths with UUID-based identity, display names, default path protection, and security-scoped bookmark support for sandbox compatibility
- **DeltaCategory enum**: Six-category classification system (apps, packages, containers, caches, developer, other) with SF Symbol icons and pattern-based path matching via `categorize(path:)` static method
- **PathManager**: @Observable @MainActor ViewModel managing path persistence via UserDefaults with JSON serialization, following the established MainViewModel pattern

## Files Created/Modified

- `Prunr/Models/TrackedPath.swift` - Path tracking model with default paths (Home, Desktop, Documents, Downloads, Developer)
- `Prunr/Models/DeltaCategory.swift` - Category classification enum with display metadata and path pattern matching
- `Prunr/ViewModels/PathManager.swift` - Path management with UserDefaults persistence and CRUD operations

## Decisions Made

**UserDefaults instead of @AppStorage**: The @AppStorage property wrapper conflicts with @Observable's macro-generated backing storage. Using UserDefaults directly with manual save/load provides the same persistence while maintaining @Observable compatibility for SwiftUI reactivity.

**Security-scoped bookmarks**: Included `bookmarkData` property on TrackedPath for future sandbox compatibility, even though the app may currently distribute outside the Mac App Store.

## Issues Encountered

**@AppStorage + @Observable conflict**: Initial implementation used `@AppStorage("trackedPaths")` directly on the PathManager property, causing a "invalid redeclaration of synthesized property '_pathData'" compile error. Fixed by using `UserDefaults.standard.set(_:forKey:)` directly in `savePaths()` and `loadPaths()` methods.

## Next Step

Ready for 05-02-PLAN.md (Sidebar View)
