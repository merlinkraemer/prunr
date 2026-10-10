# Prunr — agent notes

macOS menu bar app (Swift/SwiftUI, XcodeGen `project.yml`) plus `website/` (Vite, Vercel API, GitHub Pages).
Docs index: `docs/README.md`. Lessons: `docs/lessons.md`.

## Unattended

platform: mac for the app (code on lab2, builds/tests via `mac-queue`); box for `website/`
validation: app → `mac-queue add <dir> <ref> test Prunr` green; website → `cd website && npm ci && npx vite build && npm run test:api`
may land: docs, scripts, tests, website/api backend (validation green); never app code while the lane rule below holds
must ask: user-visible (UI, copy, UX, visuals, website pages), data/schema, scan/storage logic, pricing, roadmap/scope
never: push to main (CI + Pages deploy), release workflow, notarise, Sparkle appcast, Vercel/Pages deploy, Brevo sends, secrets
scope fence: `Prunr/` app code, `docs/appcast.xml`, `Releases/`, `.github/workflows/`
lane rules: Compass — "no code until the core screen is settled"; app work is design/docs only until Merlin lifts it
