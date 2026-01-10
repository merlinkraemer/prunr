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
- [ ] **Phase 5: Frontend Redesign** - Complete UX overhaul with improved visual hierarchy and polish

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

### Phase 5: Frontend Redesign
**Goal**: Complete UX overhaul with improved visual hierarchy, better data presentation, and polished app experience
**Depends on**: Phase 4
**Research**: Likely (explore modern macOS UI patterns, data visualization best practices)
**Plans**: 3

Plans:
- [ ] 05-01: Layout & Visual Hierarchy
- [ ] 05-02: Delta List Redesign
- [ ] 05-03: Polish & Visual Feedback

**Details:**
Complete redesign focusing on:
- Main window layout rethink
- Delta list presentation improvements
- Visual feedback enhancements
- Overall polish and professional feel

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2026-01-10 |
| 2. Scanner & Storage | 2/2 | Complete | 2026-01-10 |
| 3. Delta Engine | 1/1 | Complete | 2026-01-10 |
| 4. UI & Polish | 2/2 | Complete | 2026-01-10 |
| 5. Frontend Redesign | 0/3 | Ready to Start | — |
