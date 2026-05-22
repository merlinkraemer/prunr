#!/usr/bin/env bash
set -euo pipefail

# ─── Prunr E2E Test Runner ────────────────────────────
# Builds the app, runs the full end-to-end test suite:
#   1. Database init
#   2. Synthetic tree creation
#   3. First baseline scan
#   4. Working set + category totals verification
#   5. Idempotent rescan (no false growth)
#   6. Incremental refresh (mutate + add files → working-set update)
#   7. FSEvents watcher round-trip
#   8. Noise filter correctness
#   9. Post-scan stability (no rescan loops)
#  10. SQLite integrity check
#
# Usage:
#   ./scripts/e2e.sh                    # default: 5000 files
#   ./scripts/e2e.sh --file-count 50000 # larger dataset

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
FILE_COUNT=5000
FILE_SIZE=4096
WATCHER_TIMEOUT=8

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file-count)      FILE_COUNT="$2"; shift 2 ;;
        --file-size)       FILE_SIZE="$2"; shift 2 ;;
        --watcher-timeout) WATCHER_TIMEOUT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --file-count N        Number of files in synthetic tree (default: 5000)"
            echo "  --file-size BYTES     Size of each file (default: 4096)"
            echo "  --watcher-timeout SEC Timeout for FSEvents watcher test (default: 8)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

E2E_RUNNER=".build/derivedData/Build/Products/Debug/Prunr.app/Contents/MacOS/Prunr"
RESULTS_DIR="$PROJECT_DIR/tmp/e2e-results/$(date +%Y%m%d-%H%M%S)"

echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Prunr E2E Test Runner${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Build ──────────────────────────────────────
echo -e "${BLUE}[1/3] Building...${NC}"
if ! make build 2>&1 | tail -1; then
    echo -e "${RED}Build failed. Run 'make build' for full output.${NC}"
    exit 1
fi
echo -e "${GREEN}Build OK.${NC}"
echo ""

# ── Step 2: Kill any running instances ─────────────────
echo -e "${BLUE}[2/3] Stopping running Prunr instances...${NC}"
pkill -x "Prunr" 2>/dev/null || true
sleep 0.5
echo ""

# ── Step 3: Run E2E ────────────────────────────────────
echo -e "${BLUE}[3/3] Running E2E tests (${FILE_COUNT} files)...${NC}"
echo ""

mkdir -p "$RESULTS_DIR"

set +e
"$E2E_RUNNER" e2e \
    --results-dir "$RESULTS_DIR" \
    --file-count "$FILE_COUNT" \
    --file-size "$FILE_SIZE" \
    --watcher-timeout "$WATCHER_TIMEOUT"
EXIT_CODE=$?
set -e

echo ""

if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}E2E PASSED${NC}"
    echo "Results: $RESULTS_DIR/e2e-result.json"
else
    echo -e "${RED}E2E FAILED (exit code $EXIT_CODE)${NC}"
    echo "Results: $RESULTS_DIR/e2e-result.json"
    if [ -f "$RESULTS_DIR/e2e-result.json" ]; then
        echo ""
        echo "Failed phases:"
        python3 -c "
import json, sys
data = json.load(open('$RESULTS_DIR/e2e-result.json'))
for p in data.get('phases', []):
    if not p['passed']:
        print(f\"  ❌ {p['name']}: {p.get('detail', p['message'])}\")
" 2>/dev/null || true
    fi
fi

exit $EXIT_CODE
