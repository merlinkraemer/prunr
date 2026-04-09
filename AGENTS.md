# Prunr Agent Notes

## Runtime Monitor

Use the live scan monitor when validating scan refactors, CPU/RSS behavior, category totals, autoscan timing, or disk-access regressions.

Commands:

```bash
npm run monitor -- --help
npm run monitor -- --samples 20 --interval 5
npm run monitor -- --json
```

What it checks:

- live `Prunr` process CPU and RSS
- active snapshot growth in `~/Library/Application Support/Prunr/prunr.db`
- working-set vs category-total drift or unexpected category growth
- autoscan/root settings from `defaults export com.prunr.app -`
- permission and scan anomalies from unified logs

Use this before and after scan-pipeline changes, especially for long home-directory scans.
