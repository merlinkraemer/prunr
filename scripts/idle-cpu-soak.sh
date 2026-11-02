#!/usr/bin/env bash
# Samples CPU and RSS of a running Prunr process on the Mac for a long idle window.
# Usage: scripts/idle-cpu-soak.sh <pid-or-process-name> <hours> [interval-seconds]
# Run it against a throwaway Prunr instance (not Merlin's real app), left idle after its first scan.
# Recommended: 2 hours for a quick check, 24 hours for issue #31 gating.
# Output: one CSV line per sample to stdout, then a summary line (avg, max, p95 CPU; RSS start/end).
set -euo pipefail

target=${1:?pid or process name}
hours=${2:?hours}
interval=${3:-30}

if [[ $target =~ ^[0-9]+$ ]]; then pid=$target; else pid=$(pgrep -x "$target" | head -1); fi
[[ -n ${pid:-} ]] || { echo "process not found: $target" >&2; exit 1; }

end=$(( $(date +%s) + $(printf '%.0f' "$(echo "$hours * 3600" | bc -l)") ))
echo "timestamp,cpu_percent,rss_mb"
while [[ $(date +%s) -lt $end ]]; do
  read -r cpu rss < <(ps -o %cpu=,rss= -p "$pid") || { echo "process $pid exited" >&2; exit 1; }
  printf '%s,%s,%s\n' "$(date -u +%FT%TZ)" "$cpu" "$((rss / 1024))"
  sleep "$interval"
done | tee /dev/stderr | awk -F, 'NR>1 { n++; s+=$2; if($2>m)m=$2; v[n]=$2; if(n==1)r0=$3; r1=$3 }
  END { asort(v); printf "SUMMARY samples=%d avg=%.2f%% max=%.2f%% p95=%.2f%% rss_start=%sMB rss_end=%sMB\n", n, s/n, m, v[int(n*0.95)+1>n?n:int(n*0.95)+1], r0, r1 }' 2>/dev/null || true
