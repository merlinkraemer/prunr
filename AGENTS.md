# Prunr — agent notes

macOS menu bar app (Swift/SwiftUI, XcodeGen `project.yml`) plus `website/` (Vite, Vercel API, GitHub Pages).
Docs index: `docs/README.md`. Lessons: `docs/lessons.md`.

## Unattended

platform: mac for the app (code on lab2, builds/tests via `mac-queue`); box for `website/`
validation: app → `mac-queue add <dir> <ref> test Prunr` green; website → `cd website && npm ci && npx vite build && npm run test:api`
may land: docs, scripts, tests, website/api backend, and non-UI app slices of the core-screen PRD (validation green); UI slices wait for Merlin
must ask: user-visible (UI, copy, UX, visuals, website pages), data/schema, scan/storage logic, pricing, roadmap/scope
never: push to main (CI + Pages deploy), release workflow, notarise, Sparkle appcast, Vercel/Pages deploy, Brevo sends, secrets
scope fence: `docs/appcast.xml`, `Releases/`, `.github/workflows/`, release/notarise scripts
lane rules: core screen settled 2026-10-11 (Merlin lifted the "no code" rule); build per docs/core-screen-episodes-prd-2026-10-11.md
