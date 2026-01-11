# Phase 7: Category-Based Growth View - Context

**Gathered:** 2026-01-12
**Status:** Ready for planning

<vision>
## How This Should Work

When storage drops and the user opens Prunr, they see a clean, single list of categories ordered by size—biggest growth at the top. Instead of seeing 50 scattered node_modules folders or dozens of Homebrew files, they see one line: "node_modules (8 projects) +1.2 GB [▶]". The moment of clarity is immediate: "+4.1 GB Homebrew" at the top tells them exactly what happened.

Big individual files (>100MB) nest within their parent category. Everything belongs to a category—no orphan files at the top level. Unknown stuff becomes "Other."

The entire current folder-based list transforms into this category-based view. It should feel native and closely aligned with macOS design patterns.

</vision>

<essential>
## What Must Be Nailed

- **Instant answers** — Within one second of opening, the user knows what consumed their storage. The biggest category is at the top, with its total growth clearly shown.
- **Accurate categorization** — Files are correctly grouped into categories (Homebrew, node_modules, Downloads, caches, etc.) with reasonable detection patterns.
- **Clear, native display** — The list renders properly, categories are expandable, big files nest correctly, and it feels like a macOS interface.

</essential>

<boundaries>
## What's Out of Scope

- **Cleanup actions** — The spec mentions uninstall actions (brew uninstall, npm install, clear caches). Those are NOT for this phase. This is view-only.
- **Smart scanning** — Auto-detecting what tools the user has installed and only showing relevant categories is deferred. Show all categories for now.

</boundaries>

<specifics>
## Specific Ideas

- Use the spec (documentation/grouping_feature_spec.md) as a guide, but flexible on specific details
- Closely aligned with macOS design spec — should feel native
- Spec suggests 10 categories: Homebrew, node_modules, ~/Library/Caches, Downloads, Docker, Spotify, browser cache, Mail attachments, Trash, Other
- 100MB threshold for "big file" designation is a reasonable starting point
- Categories sorted by total size (descending)
- Big files nested within parent category
- Expandable categories with [▶] disclosure indicators

</specifics>

<notes>
## Additional Context

User's excitement is about the **moment of clarity**: when storage drops and they see "+4.1 GB Homebrew" at the top, they immediately know what happened. The current folder-based list scatters related files everywhere—making it hard to see the forest for the trees. Categories aggregate everything into instantly understandable groupings.

The transformation is complete: the entire folder list becomes a category list. No hybrid view, no toggle. Clean and focused.

</notes>

---

*Phase: 07-category-growth-view*
*Context gathered: 2026-01-12*
