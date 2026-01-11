```markdown
# Prunr Grouping Feature Spec

## Problem Statement

Storage is low, apps like Photoshop can't open (need scratch disk), and users don't know what accumulated recently that can be safely removed. A simple "biggest files" list doesn't work because things like npm packages consist of thousands of small files that add up.

## Core Concept

A single list of **categories**, ordered by size (biggest first), where:
- Known sources get grouped into categories (Homebrew, node_modules, caches, etc.)
- Big individual files (>100MB) appear nested under their parent category
- Unknown stuff becomes "Other" category
- Everything is a category - no orphan files at top level

## Top-Level View

```
Growth since baseline
────────────────────────────────
Homebrew                    +4.1 GB  [▶]
Downloads                   +2.5 GB  [▶]
  └─ big-video-export.mov   +2.3 GB
  └─ random-download.zip    +400 MB
node_modules (8 projects)   +1.2 GB  [▶]
Docker images               +890 MB  [▶]
~/Library/Caches            +650 MB  [▶]
Other                       +580 MB  [▶]
  └─ backup-2024.tar.gz     +500 MB
Browser cache               +320 MB  [▶]
```

### Rules
- Categories sorted by total size (descending)
- Big files (>100MB threshold) within a category shown as nested sub-items
- Category total includes everything (no double-counting issues)
- Drill-down [▶] available on all categories to see full contents

## Categories for v1

| Category | What it matches |
|----------|-----------------|
| Homebrew | Homebrew packages and cache |
| node_modules | All node_modules folders across projects |
| ~/Library/Caches | Application caches |
| Downloads | ~/Downloads folder |
| Docker images/volumes | Docker storage |
| Spotify/music cache | Spotify cache |
| Browser cache | Chrome, Safari, Firefox caches |
| Mail attachments | Mail.app attachments |
| Trash | ~/.Trash |
| Other | Everything else |

## Drill-Down View

When clicking [▶] on a category:

```
Downloads                   +2.5 GB
────────────────────────────────
big-video-export.mov        +2.3 GB
random-download.zip         +400 MB
presentation.key            +150 MB
42 files under 100MB        +120 MB  [▶]
```

### Rules
- Files above threshold shown individually, sorted by size
- Small files collapsed into "X files under Y MB" row
- Collapsed row is expandable for detail

### TBD
- Subfolder handling in drill-down
- Threshold for drill-down (same 100MB or smaller?)

## How It Works With Existing System

- Uses existing baseline/delta tracking (growth since last baseline)
- Category detection runs on top of existing file scan data
- Boundaries system still applies (stops recursion into node_modules etc., measures total size)
- Monitor path defaults to home folder

## Future (Not MVP)

- **Smart scan**: Auto-detect what tools user has installed, only show relevant categories
- **Uninstall actions**: 
  - `brew uninstall` for Homebrew packages
  - Delete node_modules (user can `npm install` again)
  - Clear caches with one click
  - Move to trash / permanent delete options

## Open Questions

1. Exact threshold for "big file" (100MB hardcoded for now)
2. How to handle subfolders in drill-down view
3. Whether drill-down threshold should be smaller than top-level
4. Category detection: pattern matching on paths vs. smarter detection
```