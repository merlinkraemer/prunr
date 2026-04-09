---
name: prunr-reset
description: Fully reset the local Prunr app install for fresh-version testing. Use when the user asks to wipe the installed app, clear Prunr caches and Application Support data, rebuild the app, and reinstall it into /Applications.
---

# Prunr Reset

Run a full local reset for Prunr with the bundled script:

```bash
bash .agents/skills/prunr-reset/scripts/reset-prunr.sh
```

What it does:

1. Stops any running `Prunr` process.
2. Removes `/Applications/Prunr.app` if present.
3. Deletes Prunr state under `~/Library/Application Support/Prunr`.
4. Deletes Prunr cache/state files under the standard macOS user-library paths for bundle id `com.prunr.app`.
5. Rebuilds and reinstalls the app by running `make install-app` from the repo root.

Use the script directly instead of retyping the cleanup steps. It is intentionally deterministic and repo-specific.
