@AGENTS.md

## Orchestrator

This project runs as one long-lived orchestrator thread (see the `orchestrator` skill), on lab2 as a Claude Desktop SSH session in this folder. Live state: `docs/STATE.md`; history: `docs/journal.md`; rulebook: `AGENTS.md` `## Unattended`.

- Workers are capped `claude -p` runs in worktrees (credits); subagents only for quick scouting.
- Hard gates are the `permissions.ask` rules in `.claude/settings.json`; only the orchestrator runs them, in the foreground. Everything else Merlin decides goes to STATE.md "Waiting on Merlin" with a recommendation and a branch.
- Merlin keeps roadmap, anything user-visible, outward actions and taste.
