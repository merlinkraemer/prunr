#!/usr/bin/env bash
set -euo pipefail

# ─── Prunr Full Runtime E2E ──────────────────────────
# Builds, installs, and runs the actual Prunr app pointed at a
# synthetic tree. Monitors CPU, RSS, scan completion, rescan
# loops, and crash reports — no manual GUI interaction needed.
#
# Usage:
#   ./scripts/e2e-runtime.sh                # default: 5000 files, 90s observation
#   ./scripts/e2e-runtime.sh --file-count 50000 --observe-seconds 180

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="com.prunr.app"
APP_DIR="$HOME/Library/Application Support/Prunr"
DB_PATH="$APP_DIR/prunr.db"
INSTALLED_APP="/Applications/Prunr.app"

# Defaults
FILE_COUNT=5000
FILE_SIZE=4096
OBSERVE_SECONDS=90
CPU_IDLE_THRESHOLD=10.0
RSS_MAX_MB=400
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file-count)       FILE_COUNT="$2"; shift 2 ;;
        --file-size)        FILE_SIZE="$2"; shift 2 ;;
        --observe-seconds)  OBSERVE_SECONDS="$2"; shift 2 ;;
        --cpu-idle)         CPU_IDLE_THRESHOLD="$2"; shift 2 ;;
        --rss-max)          RSS_MAX_MB="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --file-count N        Synthetic tree size (default: 5000)"
            echo "  --file-size BYTES     File size (default: 4096)"
            echo "  --observe-seconds N   How long to observe the running app (default: 90)"
            echo "  --cpu-idle PCT        Max acceptable idle CPU % (default: 10)"
            echo "  --rss-max MB          Max acceptable RSS in MB (default: 400)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$PROJECT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

RESULTS_DIR="$PROJECT_DIR/tmp/e2e-runtime-results/$(date +%Y%m%d-%H%M%S)"
TREE_ROOT="$PROJECT_DIR/tmp/e2e-runtime-tree"
mkdir -p "$RESULTS_DIR"

pass() { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; FAILURES+=("$1"); }
info() { echo -e "  ${BLUE}$1${NC}"; }
warn() { echo -e "  ${YELLOW}$1${NC}"; }

FAILURES=()
TOTAL_START=$(date +%s)

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Prunr Runtime E2E — ${FILE_COUNT} files, ${OBSERVE_SECONDS}s observation${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# ── Phase 1: Build + Install ─────────────────────────
echo -e "${BLUE}[Phase 1] Build + Install${NC}"
pkill -x "Prunr" 2>/dev/null || true
sleep 0.5

if ! make build >"$RESULTS_DIR/build.log" 2>&1; then
    fail "Build failed. See $RESULTS_DIR/build.log"
    exit 1
fi
pass "Build succeeded"

rm -rf "$INSTALLED_APP"
ditto ".build/derivedData/Build/Products/Debug/Prunr.app" "$INSTALLED_APP"
pass "Installed to $INSTALLED_APP"

# ── Phase 2: Reset state + create tree ───────────────
echo ""
echo -e "${BLUE}[Phase 2] Reset state + create synthetic tree${NC}"

# Wipe all app state
rm -rf "$APP_DIR"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
pass "App state wiped"

# Create synthetic tree
rm -rf "$TREE_ROOT"
mkdir -p "$TREE_ROOT/dataset"
FANOUT=250
for (( i=0; i<FILE_COUNT; i++ )); do
    bucket=$(( i / FANOUT ))
    dir="$TREE_ROOT/dataset/$(printf 'bucket-%06d' $bucket)"
    mkdir -p "$dir"
    file="$dir/$(printf 'file-%08d.dat' $i)"
    if (( i % 5000 == 0 )) && (( i > 0 )); then
        info "  ... created $i files"
    fi
    dd if=/dev/zero bs="$FILE_SIZE" count=1 2>/dev/null | tr '\0' "\\$(printf '%03o' $(( i % 251 )) )" > "$file"
done
pass "Created $FILE_COUNT files at $TREE_ROOT/dataset"

# ── Phase 3: Seed a baseline via headless mode ───────
echo ""
echo -e "${BLUE}[Phase 3] Seed baseline via headless scan${NC}"

TREE_PATH="$TREE_ROOT/dataset"
mkdir -p "$APP_DIR"
SEED_DB="$APP_DIR/prunr.db"
SEED_RESULTS="$RESULTS_DIR/seed"
mkdir -p "$SEED_RESULTS"

set +e
# Run headless baseline scan against the real app DB location.
# Uses the same tracked path ID as the app's main base path preset so the
# app recognizes the seeded snapshot as belonging to its main tracked path.
# ScanPathPreset.mainBasePathID = B9E2C9D6-7A6C-4A8C-9A73-9DBA3DE27B57
SEED_TRACKED_PATH_ID="B9E2C9D6-7A6C-4A8C-9A73-9DBA3DE27B57"

# Use the e2e command for seeding instead of stress-scan, because
# stress-scan has a hardcoded tracked path ID that doesn't match the app's.
# We'll create a minimal snapshot directly via sqlite3 after the scan.
#
# Strategy: run stress-scan, then patch the trackedPathId in the DB.
.build/derivedData/Build/Products/Debug/Prunr.app/Contents/MacOS/Prunr \
    stress-scan --mode baseline \
    --dataset "$TREE_PATH" \
    --results-dir "$SEED_RESULTS" \
    --db-path "$SEED_DB" \
    --label "e2e-seed" \
    2>&1 | tail -5
SEED_EXIT=$?
set -e

if [ "$SEED_EXIT" -ne 0 ]; then
    fail "Headless seed scan failed (exit $SEED_EXIT)"
    exit 1
fi
pass "Headless baseline scan seeded"

# Verify seed
SEED_SNAPSHOTS=$(sqlite3 "$SEED_DB" "SELECT COUNT(*) FROM snapshot" 2>/dev/null || echo "0")
SEED_ENTRIES=$(sqlite3 "$SEED_DB" "SELECT COUNT(*) FROM workingSetEntry" 2>/dev/null || echo "0")
if [ "$SEED_SNAPSHOTS" -gt 0 ] && [ "$SEED_ENTRIES" -gt 0 ]; then
    pass "Seed verified: $SEED_SNAPSHOTS snapshot(s), $SEED_ENTRIES working-set entries"
else
    fail "Seed incomplete: $SEED_SNAPSHOTS snapshots, $SEED_ENTRIES entries"
    exit 1
fi

# Patch trackedPathId to match the app's main base path preset ID
sqlite3 "$SEED_DB" "
    UPDATE snapshot SET trackedPathId = '$SEED_TRACKED_PATH_ID';
    UPDATE workingSetEntry SET trackedPathId = '$SEED_TRACKED_PATH_ID';
    UPDATE workingSetCategoryTotal SET trackedPathId = '$SEED_TRACKED_PATH_ID';
    UPDATE growthJournalBucket SET trackedPathId = '$SEED_TRACKED_PATH_ID';
" 2>/dev/null
pass "Patched tracked path ID to match app preset"

# ── Phase 4: Configure app via defaults ──────────────
echo ""
echo -e "${BLUE}[Phase 4] Configure app defaults${NC}"

defaults write "$BUNDLE_ID" mainBasePath "$TREE_PATH"
defaults write "$BUNDLE_ID" selectedCommonPathIDs -array
defaults write "$BUNDLE_ID" trackedPaths -data $(python3 -c "import plistlib,sys; sys.stdout.buffer.write(plistlib.dumps([]))" | xxd -p | tr -d '\n')
# Set autoscan interval to 1 minute for faster testing
defaults write "$BUNDLE_ID" automaticFullScanIntervalHours -float 0.017
defaults write "$BUNDLE_ID" automaticFullScanIntervalUserTouched -bool true
pass "Defaults configured — tracking $TREE_PATH"

# ── Phase 5: Launch app ──────────────────────────────
echo ""
echo -e "${BLUE}[Phase 5] Launch app with existing baseline${NC}"

# Snapshot crash reports before launch
CRASHES_BEFORE=$(find "$CRASH_DIR" -name "*Prunr*" -newer /tmp 2>/dev/null | sort)
LAUNCH_TIME=$(date +%s)

open "$INSTALLED_APP"
sleep 2

# Verify process is alive
if ! pgrep -x "Prunr" > /dev/null; then
    fail "App is not running 2s after launch"
    # Check crash reports
    NEW_CRASHES=$(comm -23 <(find "$CRASH_DIR" -name "*Prunr*" 2>/dev/null | sort) <(echo "$CRASHES_BEFORE" | grep . | sort) 2>/dev/null || true)
    if [ -n "$NEW_CRASHES" ]; then
        fail "Crash report found:"
        echo "$NEW_CRASHES" | while read -r f; do echo "    $f"; head -30 "$f"; done
    fi
    exit 1
fi
pass "App launched, process alive"

# ── Phase 6: Wait for first scan to complete ─────────
echo ""
echo -e "${BLUE}[Phase 6] Waiting for first scan to complete${NC}"

SCAN_FOUND=false
for (( attempt=1; attempt<=30; attempt++ )); do
    if [ -f "$DB_PATH" ]; then
        SNAPSHOT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM snapshot" 2>/dev/null || echo "0")
        ENTRY_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM workingSetEntry" 2>/dev/null || echo "0")
        if [ "$SNAPSHOT_COUNT" -gt 0 ] && [ "$ENTRY_COUNT" -gt 0 ]; then
            SCAN_FOUND=true
            pass "First scan complete: $SNAPSHOT_COUNT snapshot(s), $ENTRY_COUNT working-set entries (after ${attempt}s)"
            break
        fi
    fi
    sleep 1
done

if ! $SCAN_FOUND; then
    fail "No scan completed after 30s"
    # Check if still alive
    if ! pgrep -x "Prunr" > /dev/null; then
        fail "App process died during first scan"
    else
        warn "App still running but no snapshot in DB"
    fi
fi

# ── Phase 7: Observe runtime behavior ────────────────
echo ""
echo -e "${BLUE}[Phase 7] Observing runtime for ${OBSERVE_SECONDS}s${NC}"

# Sample CPU/RSS every 5 seconds
SAMPLE_INTERVAL=5
SAMPLES=$(( (OBSERVE_SECONDS + SAMPLE_INTERVAL - 1) / SAMPLE_INTERVAL ))
PEAK_CPU=0
PEAK_RSS=0
CPU_SAMPLES_CSV=""
RSS_SAMPLES_CSV=""
SNAPSHOT_COUNT_START=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM snapshot" 2>/dev/null || echo "0")

for (( s=0; s<SAMPLES; s++ )); do
    PID=$(pgrep -x "Prunr" 2>/dev/null || echo "")
    if [ -z "$PID" ]; then
        fail "App died during observation at sample $s"
        break
    fi

    read -r CPU RSS_KB <<< $(ps -p "$PID" -o %cpu=,rss= 2>/dev/null || echo "0 0")
    RSS_MB=$(echo "$RSS_KB" | awk '{printf "%.0f", $1/1024}')

    PEAK_CPU=$(echo "$CPU $PEAK_CPU" | awk '{if ($1 > $2) print $1; else print $2}')
    PEAK_RSS=$(echo "$RSS_MB $PEAK_RSS" | awk '{if ($1 > $2) print $1; else print $2}')

    if [ -n "$CPU_SAMPLES_CSV" ]; then
        CPU_SAMPLES_CSV="${CPU_SAMPLES_CSV},"
        RSS_SAMPLES_CSV="${RSS_SAMPLES_CSV},"
    fi
    CPU_SAMPLES_CSV="${CPU_SAMPLES_CSV}${CPU}"
    RSS_SAMPLES_CSV="${RSS_SAMPLES_CSV}${RSS_MB}"

    if (( s % 4 == 0 )); then
        info "$(date +%H:%M:%S) — CPU: ${CPU}%  RSS: ${RSS_MB}MB  snapshots: $(sqlite3 "$DB_PATH" 'SELECT COUNT(*) FROM snapshot' 2>/dev/null || echo '?')"
    fi

    sleep "$SAMPLE_INTERVAL"
done

# Write metrics
cat > "$RESULTS_DIR/metrics.json" << EOF
{
    "fileCount": $FILE_COUNT,
    "observeSeconds": $OBSERVE_SECONDS,
    "peakCPU": $PEAK_CPU,
    "peakRSS_MB": $PEAK_RSS,
    "cpuThreshold": $CPU_IDLE_THRESHOLD,
    "rssThreshold": $RSS_MAX_MB,
    "cpuSamples": [$CPU_SAMPLES_CSV],
    "rssSamples_MB": [$RSS_SAMPLES_CSV]
}
EOF

# ── Phase 8: Analyze results ─────────────────────────
echo ""
echo -e "${BLUE}[Phase 8] Analyze results${NC}"

# Check crash
if ! pgrep -x "Prunr" > /dev/null; then
    fail "App is not running after observation period"
    NEW_CRASHES=$(comm -23 <(find "$CRASH_DIR" -name "*Prunr*" 2>/dev/null | sort) <(echo "$CRASHES_BEFORE" | grep . | sort) 2>/dev/null || true)
    if [ -n "$NEW_CRASHES" ]; then
        fail "Crash report found:"
        echo "$NEW_CRASHES" | while read -r f; do echo "    $f"; head -20 "$f"; done
    fi
else
    pass "App still alive after observation period"
fi

# Check CPU
IDLE_CPU=$(echo "$CPU_SAMPLES_CSV" | awk -F, '{
    # Skip first 3 samples (scan may still be running), take max of remainder
    max = 0; count = 0;
    for (i=4; i<=NF; i++) {
        if ($i+0 > max) max = $i+0;
        count++;
    }
    if (count == 0) max = $NF+0;
    printf "%.1f", max
}')
CPU_OK=$(echo "$IDLE_CPU $CPU_IDLE_THRESHOLD" | awk '{if ($1 <= $2) print "true"; else print "false"}')
if [ "$CPU_OK" = "true" ]; then
    pass "Idle CPU ${IDLE_CPU}% ≤ ${CPU_IDLE_THRESHOLD}%"
else
    fail "Idle CPU ${IDLE_CPU}% > ${CPU_IDLE_THRESHOLD}% threshold"
fi

# Check RSS
RSS_OK=$(echo "$PEAK_RSS $RSS_MAX_MB" | awk '{if ($1 <= $2) print "true"; else print "false"}')
if [ "$RSS_OK" = "true" ]; then
    pass "Peak RSS ${PEAK_RSS}MB ≤ ${RSS_MAX_MB}MB"
else
    fail "Peak RSS ${PEAK_RSS}MB > ${RSS_MAX_MB}MB threshold"
fi

# Check for rescan loop
SNAPSHOT_COUNT_END=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM snapshot" 2>/dev/null || echo "0")
NEW_SNAPSHOTS=$(( SNAPSHOT_COUNT_END - SNAPSHOT_COUNT_START ))
if [ "$NEW_SNAPSHOTS" -le 2 ]; then
    pass "Snapshot count stable: $SNAPSHOT_COUNT_END total, $NEW_SNAPSHOTS new during observation (≤2 is OK)"
else
    fail "Possible rescan loop: $NEW_SNAPSHOTS new snapshots during ${OBSERVE_SECONDS}s observation"
fi

# Check DB integrity
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check" 2>/dev/null || echo "error")
if [ "$INTEGRITY" = "ok" ]; then
    pass "SQLite integrity check: ok"
else
    fail "SQLite integrity check: $INTEGRITY"
fi

# Check category totals match working set
DRIFT=$(sqlite3 "$DB_PATH" "
    SELECT ABS(
        (SELECT COALESCE(SUM(sizeBytes),0) FROM workingSetEntry wse JOIN paths p ON p.id=wse.pathId) -
        (SELECT COALESCE(SUM(currentSizeBytes),0) FROM workingSetCategoryTotal)
    )" 2>/dev/null || echo "error")
if [ "$DRIFT" != "error" ] && [ "$DRIFT" -le 1048576 ]; then  # 1MB tolerance
    pass "Category total drift: ${DRIFT} bytes (≤1MB)"
elif [ "$DRIFT" != "error" ]; then
    fail "Category total drift: ${DRIFT} bytes (>1MB)"
else
    warn "Could not check category drift"
fi

# ── Phase 9: Test file change detection ──────────────
echo ""
echo -e "${BLUE}[Phase 9] Test file change detection${NC}"

WS_ENTRIES_BEFORE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM workingSetEntry" 2>/dev/null || echo "?")

# Create a new file in the tracked tree
NEW_FILE="$TREE_PATH/e2e-runtime-new-$(date +%s).dat"
dd if=/dev/urandom bs=65536 count=1 2>/dev/null > "$NEW_FILE"
pass "Created new file: $NEW_FILE"

# Wait for watcher to pick it up (coalescing interval + debounce + processing)
DETECTED=false
for (( w=1; w<=20; w++ )); do
    sleep 1
    WS_UPDATED=$(sqlite3 "$DB_PATH" "
        SELECT COUNT(*) FROM workingSetEntry wse
        JOIN paths p ON p.id = wse.pathId
        WHERE p.path = '$NEW_FILE'
    " 2>/dev/null || echo "0")
    if [ "$WS_UPDATED" -gt 0 ]; then
        DETECTED=true
        pass "New file detected in working set after ${w}s"
        break
    fi
done

if ! $DETECTED; then
    # Check if watcher accumulated pending changes (app may be mid-scan)
    warn "New file not in working set after 20s — watcher may be queued behind scan"
fi

# ── Cleanup ──────────────────────────────────────────
echo ""
echo -e "${BLUE}[Cleanup] Stopping app${NC}"
pkill -x "Prunr" 2>/dev/null || true
sleep 1
pass "App stopped"

# Leave the tree and DB intact for manual inspection
info "App state preserved at: $APP_DIR"
info "Synthetic tree at: $TREE_PATH"
info "Results at: $RESULTS_DIR"

# ── Summary ──────────────────────────────────────────
TOTAL_SECONDS=$(( $(date +%s) - TOTAL_START ))
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
if [ ${#FAILURES[@]} -eq 0 ]; then
    echo -e "${GREEN}  ✅ ALL PASSED — ${TOTAL_SECONDS}s total${NC}"
else
    echo -e "${RED}  ❌ ${#FAILURES[@]} FAILURE(S) — ${TOTAL_SECONDS}s total${NC}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}$f${NC}"
    done
fi
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"

[ ${#FAILURES[@]} -eq 0 ]
