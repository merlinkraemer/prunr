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
2026-10-11 16:50 orchestrator Q5 landed: s5 developer names (8f17bbd) merged after combined test with s6/s7 (mac-queue PASS 20261011-054540)
2026-10-11 17:00 orchestrator Q5 blocked: s2b change feed green (5ccdfeb, mac-queue PASS 20261011-054819, 168 tests); UI → waits for Merlin visual check
2026-10-11 17:00 orchestrator Q5 answered: s2b perf question (2.4 s worst-case rebuild) → accept for now, re-measure on real data before s9
2026-10-11 17:00 orchestrator Q5 spawn: s3 header + categories view, stacked on s2b (feat/s3-header)
2026-10-11 17:30 orchestrator Q5 blocked: s3 header + categories green (afa47ce, mac-queue PASS 20261011-060237, 207 tests); UI → waits for Merlin
2026-10-11 17:30 orchestrator Q5 spawn: s4 adaptive rows/30 days/states, stacked on s3 (feat/s4-feed-states)
2026-10-11 18:00 orchestrator Q5 blocked: s4 adaptive rows/30d/states green (5cc040f, mac-queue PASS 20261011-062635, 223 tests); UI → waits for Merlin
2026-10-11 18:00 orchestrator Q5 followup: s4 left tests writing real UserDefaults, no panel Stop during manual scan, measure line missing → folded into s9 (same scope)
2026-10-11 18:00 orchestrator Q5 spawn: s9 remove old overview + followups, stacked on s4 (feat/s9-cleanup)
2026-10-11 18:10 orchestrator Q5 decided: Merlin keeps onboarding + manual-scan full-screen card as before; s9 restores the card s4 removed (no footer Stop)
2026-10-11 19:00 orchestrator Q5 blocked: s9 cleanup green (b15237e, mac-queue PASS 20261011-071132, 225 tests); full v1 stack in feat/s9-cleanup waits for Merlin review; measure 4.5 s worst case
2026-10-11 19:00 orchestrator - cleanup: removed finished worktrees and merged/agent branches; stacked slice branches kept
- 2026-10-11 mac-queue b15237e8d mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-11 12:10 orchestrator Q5 spawn: Debug build of feat/s9-cleanup installed on the Mac (mac-queue 20261011-120614 PASS) for Merlin's review
2026-10-11 13:30 orchestrator Q5 followup: Merlin review of v1 build: hard to read at a glance; direction = plain chronological day list; Fable proposed one 1 GB rule (docs/core-screen-simple-list-model-2026-10-11.md), mockups S1/S2
2026-10-11 13:45 orchestrator - decided: Merlin picked the 1 GB rule (s10) and real icons now (s11, hybrid app/file icon + category fallback)
2026-10-11 13:50 orchestrator Q5 spawn: s10 one 1 GB rule (feat/s10-one-rule) and s11 real icons (feat/s11-icons), both from feat/s9-cleanup
- 2026-10-11 mac-queue 4432402f1 mac-install-Prunr PASS: 10-xcodegen=PASS 20-macinstall-Prunr-build=PASS 20-macinstall-Prunr-install=PASS
2026-10-11 14:10 orchestrator Q5 blocked: s10 (b2bf6e3) + s11 (df67108) merged into feat/v1-review (conflict in EpisodeBuilder resolved, mac-queue PASS 20261011-131629); Debug install PASS 20261011-132233 (2nd attempt, after box reset); waits for Merlin review
2026-10-11 14:30 orchestrator Q5 followup: Merlin review of v1-review build: too heavy, opaque date headers, non-native fade, coloured tiles, heavy header; drop "free of" (menu bar shows it). Icons root cause: only 12/247 journal buckets on his Mac have unit keys (pre-update data) → category icons. Polish mockups V1–V3 spawned.
2026-10-11 15:00 orchestrator Q5 spawn: s12 polish (V1 rows single-line, no tiles, no date band, native bottom edge, header bar + divider + This week row, no free-of), branch feat/s12-polish from feat/v1-review
2026-10-11 15:05 orchestrator Q5 dropped: s12 polish build stopped at Merlin's request (mockups first); partial branch feat/s12-polish (2 commits, untested) parked
2026-10-11 15:10 orchestrator Q5 decided: list is a pure log for v1 (no click/hover); cleanup awareness (gone rows, current size) noted as PRD L4
2026-10-11 15:20 orchestrator Q5 spawn: Merlin approved W2 + icons option 1 (old coloured category glyphs, real app icon where known, no tiles, pure log); worker continues feat/s12-polish, test + Mac install
