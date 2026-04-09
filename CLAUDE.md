# Prunr Claude Notes

## Monitor

For runtime verification, use the repo-local monitor instead of ad-hoc `ps` and `sqlite3` commands.

```bash
npm run monitor -- --help
npm run monitor -- --samples 12 --interval 10
```

Useful flags:

- `--json` for machine-readable output
- `--log-lookback-minutes 30` when checking permission or watcher issues

The monitor reports:

- process CPU and memory trends
- full-scan snapshot growth
- working-set/category-total consistency
- autoscan interval and root context
- permission-denied / blocked-location log signals
