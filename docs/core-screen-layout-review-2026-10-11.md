# R5: review of E1 and the E5 redesign

## 1. What makes E1 cluttered (ranked by impact)

1. **Three orange focal points.** The 48 GB in the headline, the +31/+9/+5 amounts and the filled orange button all use the same accent. The eye has nowhere to land; nothing is "the" message.
2. **Four-column grid puts the name third.** Time (70 px) and amount (62 px) sit before the icon+name, so the thing the user recognises starts 150 px in, and the row reads when / how much / what / chevron: two scans per row. Amounts are left-aligned in a monospace font; macOS lists put numbers trailing, right-aligned, tabular.
3. **Five text sizes** (20 / 14 / 13 / 12 / 11) plus two font families (mono for numbers). Secondary lines (free line, "Updated just now", reconciliation, "Earlier this month", footer) are all 12 px muted, so five unrelated things look like one class.
4. **Uniform 14 px gap, no grouping.** Header, headline, list, reconciliation, button, "Earlier", footer are all spaced the same; nothing is a section. Then `margin-top:auto` on the footer leaves ~170 px of dead space in a 600 px popover. HIG popovers size to content.
5. **The button is a dialog element in a popover.** A full-width filled CTA says "confirm". It also duplicates the row chevron: the row already drills, so the top episode has two affordances to the same place. And it hard-codes one row's name into a button, which breaks for row 2 and 3.
6. **Redundant text.** "Docker images / Docker disk image" says the same thing twice; "Updated just now" says nothing a user acts on; "Earlier this month ›" duplicates what the tail row (11 smaller changes) and the 30-day list already cover.
7. **Reconciliation line in the wrong place and below its own threshold.** 6 GB of 48 is 12.5 %, under the model's 15 % rule (r4 section 4), so by the model it would not even be shown. Where it sits (between list and button) it interrupts the sum story and the action.
8. **Three navigation styles.** Text "›" chevrons on rows, a muted "Earlier this month ›" line and "Biggest places ›" in the footer: same meaning, three looks, three positions. The tail row's chevron also lands in a different column than the others.
9. **Static "selected" first row.** The first row is painted as hovered/selected with nothing selected; it reads as a stuck state.
10. **99 % grey bar.** A 6 px bar filled 99 % under "19 GB free" reads as a progress indicator, and it repeats the number next to it. The bar in the shipped app carries category colours; this one carries none.
11. **Chevron + per-row subtitle crowd the 350 px width.** With four columns and a 10 px chevron column, names get ~170 px and ellipsise early.

## 2. Decisions in E5

- **One focal point.** Only the headline number is orange: `+48 GB more used` under a small "LAST 7 DAYS" caption. Row amounts are plain white, semibold. Nothing else is coloured except category icons.
- **Free space merges into the header.** `19 GB free of 2 TB` is the third line of the header. The bar is gone: the text is exact, the bar at 99 % added nothing.
- **Two-line rows, no time column.** Row = icon | name + date caption | amount (right, tabular) | 20 px action slot. The date ("Tuesday 14:20", "Yesterday", "Monday") replaces the redundant subtitle; the secondary detail (project, file) joins the name with a middle dot. Order stays biggest-first, as the owner liked; the date caption makes the order free.
- **No day section headers.** With three episodes on three different days, headers would triple the chrome for no grouping gain. The caption carries the date.
- **Show in Finder is a per-row hover action.** A folder-arrow icon appears in the trailing slot on hover (first row drawn in the hover state). Row click = reveal the unit's folder (r4 item 9). The big button is gone. Chevrons are gone from episode rows; only the tail row keeps one, because only it opens a subview (all changes).
- **Tail row** stays on the name column with its amount right-aligned, muted, so the three episodes plus tail visibly sum to the headline.
- **Removed:** "Updated just now" (state belongs in the footer only while scanning), the reconciliation line (below threshold here; when it does apply it belongs in the all-changes detail view), "Earlier this month" (covered by the tail row), the free-space bar.
- **Footer:** one divider, "Biggest places ›" left, settings gear right, 13 px. Popover sizes to content (~340 px) instead of a fixed 600 px.
- **Three text sizes:** 22 (headline), 13 (everything else), 11 (captions). One font family, tabular numerals.
- **Alignment:** all text starts at 16 px; names and the tail line share the 50 px column; all amounts share one right edge; one 20 px trailing column for every row.
- **Spacing:** header 14/16 px padding, 44 px rows at 8 px inset, 6 px before the footer divider; grouping comes from the divider and the row backgrounds, not from gaps.
- Contrast: body #f0f3f7 and muted #a3b2c4 on #1c2e42 are above 4.5:1; accent #ffb060 well above.
