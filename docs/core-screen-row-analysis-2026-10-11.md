# Round 6 — why the row families failed, and what the owner is actually reacting to

## Evidence from the files

- Shipped app (images/1.png): 3-cell rows `icon | name | amount`, big icon (~28px) hard left, ~68px tall rows,
  tabular mono numbers, nothing else. That is the owner's baseline for "calm and native".
- E1 (liked structure, "clunky"): 4 grid columns `70px time | 62px | 1fr | 10px`, 14px text, time in a text
  column. The owner liked that *the leftmost thing you read going down is a time*, not the column itself.
- E5 (clean, "lost the history feel"): `24px icon | name+caption | amount`. Time demoted to a caption *after*
  the name; reading order became what -> when. The chronology stopped being the first thing the eye scans.
- T1–T5: each adds a second structure on top of the rows (day headers with their own sums = a second numeric
  column; a rail with dots; a week strip; fading opacity; "Now"/"7 days" bookends). All of them explain time
  with extra furniture. Rejected for the same reason: furniture, not hierarchy.
- L1–L4: `time-stack | icon | name | amount` plus a trailing action glyph: 5 cells, icon in position 2.
- C2 ("ok-ish"): `66px time | icon+name | amount`. Closest so far, but a text column of mixed widths
  ("Today 08:40" vs "Mon") left-aligned looks ragged, and a 66px fixed column steals width from long titles.
- D1–D5: variations of where the time token sits; D4 pill = chrome. D5 `day | clock | icon+name | amount` was
  "better" but puts the icon in cell 3 -> "uneasy". F1/F2/F3 then permuted icon/time/name order: F1 and F3
  put a clock next to the amount, which creates two right-aligned number columns and breaks "rightmost =
  amounts only"; F2 keeps the icon left but the time becomes an orphan text column in the middle.

## The real tension

Both things the owner wants on the left edge are *scanning anchors*: the icon is the row's identity anchor
(macOS convention), the time is the list's chronology anchor. Every mockup so far gave the two anchors
separate grid columns, so one of them always ends up in the "wrong" place, or the row grows to 4–5 cells and
stops feeling like the shipped 3-cell row. Permuting columns cannot fix this. The resolution has to be:
keep the shipped 3-cell row (icon | text | amount), and make time part of the icon cell or of the hierarchy
inside the text cell, or move it out of rows into structure the owner already accepts (plain group labels).

## Three resolutions built

G1 fused anchor: the icon and the time are ONE leftmost element: icon on top, "Tue" / "14:20" stacked under
it in 11px. Scanning the left column shows app + time together; the text cell never shares width with it,
so long titles cannot break it; row stays 3 cells.

G2 eyebrow (Notification Center hierarchy): icon leftmost, text cell is two lines with the time FIRST
("Tuesday 14:20" muted, 11px) and the name below. Opposite of E5: the time is read before the name, so the
history feel is back, while the row is exactly the shipped app's shape.

G3 Finder date groups: rows are literally the shipped rows (icon | name · detail | amount). Day words sit as
plain group labels like Finder's "Today / Yesterday" groups, no sums, no rail; the clock becomes the row's
caption. Time is carried by structure, not by a column.
