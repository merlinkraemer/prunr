# Prunr

## What This Is

Prunr is a macOS app that tracks what's eating your disk space *over time* and helps you see what grew recently. Unlike tools that show what's big (DaisyDisk) or blindly clean caches (CleanMyMac), Prunr answers: "What grew in the last 24 hours?"

For developers and power users on storage-constrained Macs, it turns a 30-minute scavenger hunt into a 1-minute answer.

## Core Value

**When storage suddenly drops, users can immediately see what consumed it.**

The "what grew in the last 24h" view is the core—everything else supports this.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Disk scanner core — recursively scan folders and calculate sizes
- [ ] Snapshot storage — SQLite database to store folder sizes with timestamps
- [ ] Delta calculation — compare snapshots to show what grew/shrank
- [ ] Main app window — SwiftUI list view showing growth data sorted by change

### Out of Scope

- Cleanup actions — v1 is read-only, shows growth but doesn't delete anything
- App Store distribution — direct distribution only for v1, avoids sandbox complexity
- Category detection/grouping — v1 shows raw folder paths, smart grouping deferred to v2
- Menu bar companion — nice-to-have but not core for first ship
- Low-space alerts — deferred until core value is validated
- Settings UI — hardcode sensible defaults for v1
- Onboarding flow — defer polish until core works

## Context

**Target users:**
- Developers juggling node_modules sprawl, Xcode caches, Docker images
- Creative professionals with large project files and app caches
- Anyone on a 256-512GB Mac who actively manages storage

**Existing landscape:**
- DaisyDisk: shows what's big, no change tracking
- CleanMyMac: blind cleanup, no insight into what grew
- `du` commands: slow, tedious, no history

**Key insight:** Users waste 30+ minutes hunting manually or blindly delete hoping it helps. Prunr provides: accurate size tracking + time-based deltas + clear answers.

## Constraints

- **Platform**: macOS 14+ (Sonoma) — no need to support older versions
- **Distribution**: Direct download (.dmg), notarized with Developer ID — no App Store for v1
- **Permission**: Full Disk Access required for scanning outside user home

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Core 4 features for v1 | Ship the value loop fast, add polish later | — Pending |
| Read-only for v1 | Avoid complexity and risk of deletion features | — Pending |
| Direct distribution | Avoids sandbox restrictions, simpler for v1 | — Pending |
| GRDB.swift for SQLite | Robust, type-safe, well-documented Swift wrapper | — Pending |
| SwiftUI + MVVM | Native, declarative, clean separation | — Pending |

---
*Last updated: 2026-01-10 after initialization*
