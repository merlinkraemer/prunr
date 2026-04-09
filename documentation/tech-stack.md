# Tech Stack

## Platform
- macOS 14+ (Sonoma)
- Universal binary (Apple Silicon + Intel)

## UI Layer
- **SwiftUI** – native, declarative UI framework and `App` entrypoint
- **AppKit** – menu bar shell, popover/panel presentation, and status item handling

## Data Layer
- **GRDB.swift** – robust Swift SQLite wrapper, type-safe, well-documented
- **FileManager** – directory traversal and file operations
- **URL/FileResourceValues** – modern API for file metadata and sizes

## Background & Scheduling
- **SMAppService** – launch-at-login registration
- App stays alive via menu bar presence
- **Timer** – periodic refresh and scan scheduling while app is running
- **CoreServices FSEvents** – filesystem change monitoring and coalescing

## Architecture
- **Swift concurrency** – async/await, actors for background scanning
- **MVVM pattern** – clean separation of UI and business logic

## Distribution
- Direct download (.dmg)
- Notarized with Developer ID
- App Store decision deferred (requires sandboxing work)

## Key Dependencies
| Package | Purpose | Source |
|---------|---------|--------|
| GRDB.swift | SQLite database | Swift Package Manager |

## Notes
- Minimal third-party dependencies – mostly first-party Apple frameworks
- Full Disk Access permission required for scanning outside sandbox
- Designed to be App Store–adaptable later if needed
