# Prunr — Design System

> **Prunr** is a macOS menu-bar utility that tracks *what's growing* on your
> disk, not just what's big — so you catch build caches, `node_modules`, Docker
> images and download junk **before** they quietly fill your SSD.
> *"See what's growing on disk."*

This repository is the brand + product design system for Prunr. It contains the
typographic and color foundations, reusable React UI primitives, and two
high-fidelity UI kits — the **marketing website** and the **native macOS
menu-bar app** — so any design agent can produce on-brand Prunr work.

---

## Sources

Everything here was reverse-engineered from, and should be kept in sync with,
these inputs. They are referenced for provenance — do not assume the reader has
access, but explore them if you do:

- **App source code** — `github.com/merlinkraemer/prunr` (private during alpha).
  A SwiftUI/AppKit macOS app. Current version `0.1.3-alpha.2`, signed & notarized.
  Read these to extend the native UI kit faithfully:
  - `Prunr/Views/MenuBarView.swift` — the 320×480 popover panel + onboarding.
  - `Prunr/Views/CategoryGrowthListView.swift` — category / file list rows.
  - `Prunr/Views/DriveBarView.swift`, `GrowthBarView.swift`, `SizeBarView.swift` — the bars.
  - `Prunr/Models/GrowthCategory.swift` — the canonical category names, SF Symbol icons & colors.
  - `Prunr/Views/SettingsView.swift` — settings surface.
- **App icon** — `uploads/Icon-iOS-Default-1024x1024@1x.png` (the green leaf squircle).

> Explore the `merlinkraemer/prunr` repository directly to recreate views with
> higher fidelity — the Swift views are the source of truth for the native app.

---

## Two surfaces, two palettes

Prunr deliberately presents **two visual registers**. Don't mix them.

| | **Marketing web** | **Native macOS app** |
|---|---|---|
| Vibe | Quiet, premium, Apple-adjacent | Native macOS, system-faithful |
| Type | Manrope + General Sans | SF Pro / system |
| Accent | Sky blue `--theme-accent` (swappable) | macOS system colors + category palette |
| Neutrals | Warm off-white, accent-tinted ink | macOS vibrancy grays |
| Shape | Pills + soft shadows + 24px cards | 8–16px cards, 12px bars, native rows |

The green leaf only lives in the **app icon**. The website is blue; the app is
system-colored. The leaf is a mark, not a palette.

> **This design system owns the marketing/brand layer — not the app's chrome.**
> The native app is stock **macOS 26 "Liquid Glass"** (see
> `assets/app-popover-dark.png` + `assets/app-settings-dark.png`) and is not
> re-styled here. What this system provides for the app surface is: the
> category color palette + growth semantics (`tokens/app.css`), a set of
> dark-glass tokens (`--glass-dark-*`) for marketing mocks, and the authoritative
> product screenshots. When you need to *show* the app in marketing, use the real
> screenshot (or the interactive mock in `ui_kits/macos-app/`).

---

## Content fundamentals

**Voice — plain, technical, a little dry.** Prunr talks to people who know what
`node_modules` and Docker images are. It never dumbs things down and never
hypes. Copy is concrete and noun-heavy: *"See what's growing on disk."* /
*"macOS menu bar utility for seeing what is growing on disk."*

- **Person.** Address the user as **you** ("Pick the scope for your first
  scan."). Prunr refers to itself as **Prunr** in the third person ("Prunr
  checks whether the folder you chose is actually reachable.").
- **Casing.** Sentence case everywhere — titles, buttons, settings. Title Case
  is reserved for proper product nouns (Docker, Homebrew, Ableton, Git Repos).
  Never ALL-CAPS for emphasis.
- **Length.** Short. Labels are 1–3 words ("Setup Path", "Run First Scan",
  "Start Scan"). Descriptions are one calm sentence ("This can take a while for
  a full-disk scan or large drives.").
- **Numbers & units.** Always monospaced, no space before the unit in compact
  contexts (`120GB`), a space in prose (`+1.2 GB`). Growth is signed (`+500 MB`).
  Time is relative and human ("just now", "12 minutes ago", "3 days ago").
- **The core metaphor is *growth*, not size.** Copy talks about what *changed*
  ("Nothing significant has changed recently", "what's growing on disk"), not
  just what's large. Lead with the delta.
- **Tone in empty/success states is reassuring, never cute.** "Your disk is
  stable" / "Nothing significant has changed recently." No exclamation marks,
  no mascots.
- **No emoji.** Ever. Iconography is SF Symbols (app) or Lucide (web). The leaf
  glyph is the only decorative mark.
- **Honesty about limits.** When macOS blocks access, say so plainly and give
  the one action ("Open Privacy Settings"), not a wall of apology.

---

## Visual foundations

### Color
- **Accent-tinted neutrals — the signature move.** There is **no pure black** on
  web. Headings are `color-mix(theme-accent 8%, #0a0a0a)` and body is
  `color-mix(theme-accent 22%, #4a4a4a)`, so the whole page reads as one warm,
  slightly-cool family rather than ink-on-paper.
- **One swappable accent.** `--theme-accent` (sky blue `#0a94f5`) drives every
  button, link, focus ring and active state on web. Royal blue `--accent`
  (`#2a6ef5`) is the secondary/link mark. Swapping `--theme-accent` re-themes
  the entire site — that's the intended hook.
- **Warm off-white page** (`#fafaf8`) with **pure-white cards** (`#fff`). The
  warmth comes from the page, the crispness from the cards on top.
- **App palette is separate.** The native app uses macOS system colors and a
  fixed 8-color category palette (orange=Developer, purple=Audio, indigo=Apps,
  pink=Media, blue=Downloads, teal=Caches, red=Trash, brown=Other). Status is
  green→orange→red for disk fill, and **red=growth / green=shrinkage** in bars.

### Type
- **Manrope** for headings (600/700, tracking **-0.035em**, line-height 1.12) —
  tight, confident, premium. **General Sans** for body (default weight **500**,
  line-height **1.55**). System SF for app chrome and all numerals.
- Big editorial jump: 76px hero → 22px subtitle → 16px body. Numbers are always
  monospaced (SF Mono) so columns of sizes align.

### Shape, surface & depth
- **Pills everywhere interactive** — buttons, CTAs, nav buttons and chips use
  `--radius-pill` (999px). Large content cards are **24px**, app cards **8–16px**,
  the app-icon squircle **7px**, device frames **28px** (content = frame − 6px).
- **Soft shadows only.** `0 8px 24px rgba(0,0,0,.12)` lifts cards and devices;
  a `0 0 0 1px rgba(0,0,0,.10)` ring or 1px `--border` hairline defines edges.
  Never hard or colored drop-shadows. No neumorphism.
- **Glass** is `rgba(250,250,248,.82)` + `backdrop-filter: saturate(180%) blur(20px)`
  — used for the sticky nav and floating menus, sparingly.

### Motion & states
- **0.15–0.35s ease** (`cubic-bezier(.4,0,.2,1)`) on color and transform; smooth
  scroll. No bounce on web; the app uses tiny `snappy` spring slides for
  drill-down navigation (~0.28s, no extra bounce).
- **Hover:** primary CTAs lift `translateY(-1px)` + `opacity .92`. App rows fill
  with `rgba(120,120,128,.10)` and round to 8px. Links shift toward the accent.
- **Press:** subtle — opacity dip, no aggressive scale. Focus shows the soft
  accent ring (`0 0 0 2px theme-accent@14%`), never a hard outline.
- The marketing primary CTA carries an **animated diagonal sheen** as a quiet
  hook; keep it subtle.

### Backgrounds & imagery
- Backgrounds are **flat warm neutrals**, never gradients or photographs behind
  text. Imagery, when present, is the product itself (the app popover, the
  menu-bar icon) shown inside a soft-shadowed device/window frame on the warm
  page. No stock photography, no illustration scenes, no texture/grain.

---

## Iconography

- **Native app → SF Symbols.** The macOS app uses Apple's SF Symbols throughout,
  rendered in the category color or a secondary/tertiary label color. Canonical
  mappings live in `Prunr/Models/GrowthCategory.swift` and are mirrored in
  `guidelines/` cards. Examples: `hammer.fill` (Developer), `music.note` (Audio),
  `app.fill` (Applications), `photo.on.rectangle` (Media), `arrow.down.circle.fill`
  (Downloads), `gearshape.fill` (Caches), `trash.fill` (Trash),
  `ellipsis.circle.fill` (Other); `arrow.up.right` for growth deltas,
  `chevron.right` for drill-down. When recreating app screens on the web, use the
  **closest Lucide equivalent** (see below) — SF Symbols aren't licensed for web.
- **Marketing web → Lucide**, stroke-width **1.6**, currentColor. Loaded from CDN
  (`lucide@latest`). This is a *substitution* for SF Symbols on web — flagged so
  you can swap to true SF Symbol exports if a pixel-exact app render is needed.
- **No emoji, no unicode-glyph icons.** The only brand illustration is the leaf
  app icon (`assets/prunr-icon-*.png`).

Lucide stand-ins used in the kits: `hammer` (Developer), `music` (Audio),
`layout-grid`/`app-window` (Applications), `image` (Media), `download` (Downloads),
`settings` (Caches), `trash-2` (Trash), `more-horizontal` (Other),
`arrow-up-right` (growth), `chevron-right` (drill-down), `hard-drive` (disk).

---

## Index / manifest

```
styles.css                  → global entry point (@import manifest only)
tokens/
  fonts.css                 → @font-face / Fontshare + Fontsource imports
  colors.css                → web brand colors + accent-tinted ink
  typography.css            → families, type scale, weights, tracking
  spacing.css               → spacing scale, radii, shadows, glass, motion
  app.css                   → macOS system colors, category palette, dark-glass tokens
guidelines/                 → foundation specimen cards (Design System tab)
components/
  core/                     → Button, IconButton, Pill, Card, Badge, Input, Switch, Tabs, Icon
  app/                      → DriveBar, CategoryRow, GrowthBadge (app primitives)
ui_kits/
  website/                  → marketing landing page (index.html + site-sections.jsx)  ← primary
  macos-app/                → interactive dark-glass product mock (index.html + app-screens.jsx)
assets/
  prunr-icon-1024/256/128.png → app icon (the only brand illustration)
  app-popover-dark.png        → authoritative product screenshot (menu-bar popover)
  app-settings-dark.png       → authoritative product screenshot (settings window)
readme.md                   → this file
SKILL.md                    → Agent-Skill manifest
```

See each `components/<group>/` and `ui_kits/<product>/` directory's card HTML and
README for usage. The Design System tab renders every `@dsCard`-tagged file.
