# Roadmap: Prunr

## Overview

Build a macOS disk space tracker that shows what grew recently. Start with project setup, add scanning and storage, implement delta calculations, then wrap it in a SwiftUI interface. Four phases to deliver the core "what grew in the last 24h" value.

## Domain Expertise

None

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [x] **Phase 1: Foundation** - Xcode project setup with GRDB dependency
- [x] **Phase 2: Scanner & Storage** - Disk scanner + SQLite snapshot storage
- [x] **Phase 3: Delta Engine** - Compare snapshots to show growth/shrinkage
- [x] **Phase 4: UI & Polish** - SwiftUI main window displaying growth data
- [ ] **Phase 5: Finder-Style Redesign** - Complete UX overhaul with sidebar, column view, and simplified comparison
- [ ] **Phase 6: Cleanup Actions** - Add delete/move functionality for freeing space (future)

## Phase Details

### Phase 1: Foundation
**Goal**: Working Xcode project with GRDB.swift integrated and basic app structure
**Depends on**: Nothing (first phase)
**Research**: Unlikely (standard project setup)
**Plans**: TBD

Plans:
- [x] 01-01: Xcode project + GRDB integration

### Phase 2: Scanner & Storage
**Goal**: Scan disk recursively, store folder sizes with timestamps in SQLite
**Depends on**: Phase 1
**Research**: Unlikely (GRDB decided, FileManager APIs standard)
**Plans**: TBD

Plans:
- [x] 02-01: Disk scanner implementation
- [x] 02-02: SQLite schema + snapshot storage

### Phase 3: Delta Engine
**Goal**: Compare two snapshots and calculate what grew/shrank between them
**Depends on**: Phase 2
**Research**: Unlikely (internal calculation logic)
**Plans**: TBD

Plans:
- [x] 03-01: Delta calculation + sorting by change

### Phase 4: UI & Polish
**Goal**: SwiftUI window showing growth data sorted by change, ready to ship
**Depends on**: Phase 3
**Research**: Unlikely (SwiftUI patterns)
**Plans**: TBD

Plans:
- [x] 04-01: Main window UI
- [x] 04-02: App chrome + build for distribution

### Phase 5: Finder-Style Redesign
**Goal**: Complete UX overhaul with Finder-style sidebar, column view navigation, and simplified "since X ago" comparison
**Depends on**: Phase 4
**Research**: Complete (RESEARCH.md created)
**Plans**: TBD (run /gsd:plan-phase 5 to break down)

**User Requirements:**
1. **Left Sidebar**: Scan paths like Finder (customizable, add/remove, default list, persistent)
2. **Column View**: 3-column layout like Finder:
   - Column 1: Categories (Apps, Packages, Containers, Files/Folders, etc.)
   - Column 2: Items within selected category
   - Column 3: Details about selected item
3. **Simplified Comparison**: "Compare Since" dropdown (1h, 12h, 24h, 3d, 7d, custom) - always compares vs current state
4. **Top Bar**: Rescan button + comparison picker (no 2-snapshot selection needed)

**Technical Approach:**
- NavigationSplitView for sidebar + main layout
- @AppStorage for persisting tracked paths
- Custom HStack of Lists for 3-column view (or NSBrowser via NSViewRepresentable)

Plans:
- [x] 05-01: TrackedPath and PathManager models
- [x] 05-02: Sidebar View with NavigationSplitView
- [ ] 05-03: Three-Column View
- [ ] 05-04: Simplified Comparison

### Phase 6: Cleanup Actions
**Goal**: Add delete/move functionality to free disk space directly from Prunr
**Depends on**: Phase 5
**Research**: Likely (file operations, undo/redo patterns, safety measures)
**Plans**: TBD

**Future Considerations:**
- Move to Trash vs permanent delete
- Batch operations
- Undo/redo support
- Safety confirmations
- Preview before delete

Plans:
- [ ] TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2026-01-10 |
| 2. Scanner & Storage | 2/2 | Complete | 2026-01-10 |
| 3. Delta Engine | 1/1 | Complete | 2026-01-10 |
| 4. UI & Polish | 2/2 | Complete | 2026-01-10 |
| 5. Finder-Style Redesign | 2/4 | In progress | — |
| 6. Cleanup Actions | 0/0 | Future | — |