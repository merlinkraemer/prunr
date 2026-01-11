# Phase 2: Scanner & Storage - Context

**Gathered:** 2026-01-10
**Status:** Ready for planning

<vision>
## How This Should Work

The scanner walks the filesystem recursively and captures folder sizes at a point in time. When a user triggers a scan, it should feel responsive - not blocking the UI, with feedback showing what's being processed.

Scan results get stored as "snapshots" in SQLite - a complete picture of the filesystem at that moment. Each snapshot contains every folder scanned with its path and size. These snapshots are the raw material for the core feature: comparing two snapshots to see what changed.

The user should be able to configure which paths get scanned through a Settings UI. Initially, sensible defaults like home folder + /opt/homebrew, but fully customizable.

Scanning should handle edge cases gracefully: permission errors, hidden files, system directories. The app shouldn't crash or hang - it should log what it can't access and keep scanning the rest.

</vision>

<essential>
## What Must Be Nailed

- **Accurate size data** - Every folder's size must be correctly calculated and stored
- **Non-blocking scans** - Async/await so the UI stays responsive during large scans
- **Progress feedback** - User knows what's being scanned and how many folders processed
- **Persistent storage** - Snapshots survive app restarts, stored in SQLite via GRDB
- **Configurable paths** - Settings UI to add/remove scan paths (not hardcoded)
- **Performance** - Scans should be fast enough for hourly periodic use

</essential>

<boundaries>
## What's Out of Scope

- **Delta comparison** - Comparing snapshots to show growth/shrinkage is Phase 3
- **Growth visualization UI** - The main window showing "what grew" is Phase 4
- **Background scheduler** - Hourly automatic scanning is deferred (manual trigger for now)
- **Full Disk Access permissions UI** - Basic scanning only; permission handling can come later
- **Smart exclusions** - Not filtering node_modules, .git, etc. in this phase (user can exclude via paths)
- **Snapshot cleanup/retention** - Not implementing 7-day retention logic yet

</boundaries>

<specifics>
## Specific Ideas

**Default scan paths:**
- `~/` (user home directory)
- `/opt/homebrew` or `/usr/local` (Homebrew installations)

**Scanner behavior from mission docs:**
- Recursive walk of folder tree
- Use `FileManager.default.enumerator(at:includingPropertiesForKeys:)` API
- `URLResourceKey.fileSizeKey` for folder sizes
- Skip hidden files (starting with `.`)
- Handle permission errors gracefully (log and continue)

**Storage schema:**
- `Snapshot` table: id, createdAt timestamp
- `SnapshotEntry` table: id, snapshotId (foreign key), path, sizeBytes

**Settings UI should allow:**
- Add new paths to scan
- Remove existing paths
- See current list of paths

</specifics>

<notes>
## Additional Context

From the original documentation:
- "Snapshot-based monitoring - Periodic snapshots of folder sizes (hourly default)"
- "7 days of history stored locally"
- "Lightweight database (~50-200MB)"

The user emphasized that both accuracy AND performance are equally important. Scans need to be correct but also fast enough for practical use.

The Settings UI is being added to Phase 2 (instead of Phase 4) because configurable paths are essential before the scanner is useful - different users have different filesystem layouts.

</notes>

---

*Phase: 02-scanner-storage*
*Context gathered: 2026-01-10*
