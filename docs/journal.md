# Prunr — journal

2026-10-10 18:10 orchestrator - init: moved from Mac to lab2 (bundle + notes + memory), rulebook, state, gates; website build + api tests green
2026-10-10 18:10 orchestrator Q1 spawn: mac-queue test Prunr @ f616b88
2026-10-10 18:20 orchestrator - decided: Merlin ok to push main (docs only, CI)
- 2026-10-10 mac-queue f616b88c4 test-Prunr PASS: 10-xcodegen=PASS 20-test-Prunr=PASS
2026-10-11 10:00 orchestrator Q4 landed: 6 core-screen mockups (artifact), rec Ledger + glyph; waiting on Merlin
2026-10-11 11:00 orchestrator Q4 followup: mockups rejected; Fable model (episodes, named places, 30d list + 7d net) in docs/core-screen-communication-model-2026-10-11.md
2026-10-11 12:00 orchestrator Q4 followup: Merlin picked episode list (E1); Fable refined layout (E5) in artifact, review in docs/core-screen-layout-review-2026-10-11.md
2026-10-11 13:30 orchestrator Q4 followup: row layouts C/D/F rejected; Fable G1-G3 (icon+time fused, eyebrow, Finder groups) published; analysis docs/core-screen-row-analysis-2026-10-11.md
2026-10-11 15:00 orchestrator Q4 landed: core screen settled on G3; PRD docs/core-screen-episodes-prd-2026-10-11.md (Opus draft, Fable review applied). Q5 queued, blocked on approval
2026-10-11 15:30 orchestrator Q1 landed: mac-queue test green on main (2026-10-10)
2026-10-11 15:30 orchestrator - decided: Merlin approved PRD, drilldown out of v1 (L0), lifted no-code lane rule; s2 split into s2a (pure names) + s2b
2026-10-11 15:35 orchestrator Q5 spawn: workers s1 (feat/s1-scan-residual) and s2a (feat/s2a-unit-names), worktrees, validation via mac-queue
2026-10-11 16:00 orchestrator Q5 landed: s2a unit names (c46d469, mac-queue PASS 20261011-052455) merged to main
2026-10-11 16:00 orchestrator Q5 blocked: s1 scan residual green (f15e350, mac-queue PASS 20261011-052340) but schema/scan logic = must-ask; branch feat/s1-scan-residual waits for Merlin
2026-10-11 16:20 orchestrator Q5 landed: s7 media names (84bfbd9, mac-queue PASS) merged; followup noted: any '<X> Project' folder reads as Ableton project
2026-10-11 16:30 orchestrator Q5 landed: s6 app/cache names (7533497, mac-queue PASS) merged; orchestrator fixed one stale UnitResolverTests assertion (Widget data -> Widget cache)
