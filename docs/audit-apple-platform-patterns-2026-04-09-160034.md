# Apple Platform Patterns Audit

- Date: 2026-04-09
- Time: 16:00:34 +07
- Timezone: Asia/Bangkok
- Reviewer: Codex (GPT-5)
- Scope: `docs/`, `documentation/`, and shipped app code in `Prunr/`
- Goal: extract the biggest Apple-platform code patterns in use and validate each one against Apple documentation

## Biggest patterns in this repo

1. SwiftUI app scenes for app entry and settings
2. AppKit-backed menu bar shell for the actual menubar UI
3. `@MainActor` + `@Observable` state containers for UI state
4. Structured Swift concurrency for scan orchestration and progress delivery
5. CoreServices FSEvents for filesystem monitoring
6. `UserDefaults` plus `SMAppService` for settings and launch-at-login
7. Foundation volume-capacity APIs for disk free-space accounting

## Validation

### 1. SwiftUI app scenes

- Code: [PrunrMenuBar.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/PrunrMenuBar.swift#L5)
- Result: aligned
- Notes:
- Uses SwiftUI `App` as the entry point.
- Uses a `Settings` scene for macOS preferences.
- This matches Apple’s scene-based app structure for SwiftUI apps.
- Apple docs:
- https://developer.apple.com/documentation/swiftui
- https://developer.apple.com/documentation/swiftui/settings

### 2. Menu bar implementation pattern

- Code: [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L539)
- Result: implementation is valid, repo docs are inaccurate
- Notes:
- Runtime code uses `NSStatusItem`, `NSPopover`, and a custom `NSPanel`.
- This is a legitimate AppKit pattern for menu bar utilities.
- However, [tech-stack.md](/Users/merlinkraemer/dev/projects/prunr/documentation/tech-stack.md#L7) claims the app uses SwiftUI `MenuBarExtra`, which it does not.
- Apple docs:
- https://developer.apple.com/documentation/appkit/nsstatusitem
- https://developer.apple.com/documentation/appkit/nspopover
- https://developer.apple.com/documentation/swiftui/menubarextra

### 3. Observation and main-actor UI state

- Code: [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L80), [SettingsStore.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/ViewModels/SettingsStore.swift#L6)
- Result: aligned
- Notes:
- `MenuBarManager`, `SettingsStore`, and related UI models are `@MainActor` and `@Observable`.
- Internal task/stream state is hidden behind `@ObservationIgnored`.
- This fits Apple’s Observation model better than the older repo review docs imply.
- Apple docs:
- https://developer.apple.com/documentation/swift/mainactor
- https://developer.apple.com/documentation/observation/observable
- https://developer.apple.com/documentation/observation/observationignored%28%29/

### 4. Structured concurrency for scans

- Code: [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L451), [MenuBarManager.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/MenuBarManager.swift#L772), [ScanService.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/ScanService.swift#L129)
- Result: mostly aligned and stronger than the internal audit docs say
- Notes:
- Scan progress is delivered through `AsyncStream`, not raw `Task { @MainActor }` callbacks.
- Multi-path scans use `withThrowingTaskGroup`.
- Scan cancellation uses `withTaskCancellationHandler`.
- The older platform audit docs in `docs/` are stale on this point.
- Apple docs:
- https://developer.apple.com/documentation/swift/asyncstream
- https://developer.apple.com/documentation/swift/taskgroup
- https://developer.apple.com/documentation/swift/withtaskcancellationhandler%28operation%3Aoncancel%3Aisolation%3A%29

### 5. FSEvents integration

- Code: [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L63)
- Result: mostly aligned, one cleanup risk remains
- Notes:
- The stream lifecycle is correct: create, schedule, start, stop, invalidate, release.
- It handles `MustScanSubDirs`, dropped-event flags, `RootChanged`, `SinceNow`, and exposes `FlushSync`.
- Remaining weakness: the C callback still hops into the actor via unstructured `Task` at [FSEventsWatcher.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/FSEventsWatcher.swift#L132).
- That bridge is the least clean concurrency boundary left in the app.
- Apple docs:
- https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html

### 6. Settings persistence and launch-at-login

- Code: [SettingsStore.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/ViewModels/SettingsStore.swift#L53), [SettingsStore.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/ViewModels/SettingsStore.swift#L421)
- Result: correct, but more manual than necessary
- Notes:
- `UserDefaults` usage is straightforward and correct.
- `SMAppService.mainApp.register()` / `unregister()` is the right Apple API family for launch-at-login management.
- For UI-bound simple defaults, Apple’s SwiftUI direction is generally more `@AppStorage`-oriented than this hand-rolled store.
- Apple docs:
- https://developer.apple.com/documentation/foundation/userdefaults
- https://developer.apple.com/documentation/swiftui/appstorage
- https://developer.apple.com/documentation/servicemanagement

### 7. Free-space accounting

- Code: [ScanService.swift](/Users/merlinkraemer/dev/projects/prunr/Prunr/Services/ScanService.swift#L99)
- Result: aligned
- Notes:
- Uses `URLResourceValues.volumeAvailableCapacityForImportantUsage`.
- This is the right Foundation-level API for the app’s free-space display instead of lower-level filesystem guessing.
- Apple docs:
- https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage?changes=_7

## Repo mismatches and stale claims

1. [tech-stack.md](/Users/merlinkraemer/dev/projects/prunr/documentation/tech-stack.md#L7) says the UI uses `MenuBarExtra`, but the app actually uses AppKit primitives.
2. [tech-stack.md](/Users/merlinkraemer/dev/projects/prunr/documentation/tech-stack.md#L10) lists `SwiftUI Charts`, but no shipped app code imports or uses Charts.
3. [tech-stack.md](/Users/merlinkraemer/dev/projects/prunr/documentation/tech-stack.md#L23) lists `UserNotifications`, but no shipped app code uses that framework today.
4. Older internal architecture review docs still describe progress delivery as unordered `Task { @MainActor }` work even though current code uses `AsyncStream`.

## Bottom line

- The current codebase is broadly aligned with Apple’s platform patterns.
- The biggest problem is documentation drift, not implementation drift.
- The one implementation area I would still keep on the watchlist is the FSEvents callback bridge.
