#!/bin/bash
# bench.sh — Slate benchmark regression checker
#
# Usage:
#   ./Benchmarks/bench.sh           Run benchmarks and compare against committed baseline
#   ./Benchmarks/bench.sh --save    Run benchmarks and save as new baseline
#   ./Benchmarks/bench.sh --list    Show all tasks in the committed baseline
#
# The baseline is stored at Benchmarks/Baselines/main.json and should be
# committed to the repository from the main branch so any branch can diff
# against it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE="$SCRIPT_DIR/Baselines/main.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

cd "$PROJECT_DIR"

# ── helpers ────────────────────────────────────────────────────────────

run_benchmarks() {
  local output="$1"
  swift run -c release SlateBenchmarks run "$output" \
    --mode replace-all \
    --cycles 5 \
    --sizes 1 --sizes 2000 --sizes 10000 \
    2>&1
}

strip_build_noise() {
  grep -v '^Build\|^\[[0-9]*/'
}

# ── list mode ──────────────────────────────────────────────────────────

if [ "${1:-}" = "--list" ]; then
  if [ ! -f "$BASELINE" ]; then
    echo "No baseline found at $BASELINE"
    echo "Run: ./Benchmarks/bench.sh --save"
    exit 1
  fi
  swift run -c release SlateBenchmarks results list-tasks "$BASELINE" 2>&1 | strip_build_noise
  exit 0
fi

# ── save mode ──────────────────────────────────────────────────────────

if [ "${1:-}" = "--save" ]; then
  echo -e "${BOLD}=== Slate Benchmarks — Save Baseline ===${NC}"
  echo ""

  TEMP=$(mktemp /tmp/slate-bench-XXXXXX.json)
  trap "rm -f $TEMP" EXIT

  echo "→ Running benchmarks (~1 sec)..."
  run_benchmarks "$TEMP" | strip_build_noise
  cp "$TEMP" "$BASELINE"

  echo ""
  echo -e "${GREEN}✓${NC} Baseline saved to Benchmarks/Baselines/main.json"
  echo ""
  echo "  To commit:"
  echo "    git add Benchmarks/Baselines/main.json"
  echo "    git commit -m \"Update benchmark baseline\""
  exit 0
fi

# ── compare mode (default) ─────────────────────────────────────────────

echo -e "${BOLD}=== Slate Benchmarks — Regression Check ===${NC}"
echo ""

if [ ! -f "$BASELINE" ]; then
  echo -e "${RED}✗${NC} No baseline at Benchmarks/Baselines/main.json"
  echo ""
  echo "  Generate one first:"
  echo "    ./Benchmarks/bench.sh --save"
  exit 1
fi

TEMP=$(mktemp /tmp/slate-bench-XXXXXX.json)
trap "rm -f $TEMP" EXIT

echo "→ Running benchmarks (~1 sec)..."
run_benchmarks "$TEMP" | strip_build_noise
echo ""

echo "→ Comparing against baseline..."
echo ""

# Run comparison.  --list-cutoff 0 shows all tasks.
COMPARE_OUTPUT=$(swift run -c release SlateBenchmarks results compare \
  "$BASELINE" "$TEMP" \
  --list-cutoff 0 2>&1 || true)

COMPARE_OUTPUT=$(echo "$COMPARE_OUTPUT" | strip_build_noise)

echo "$COMPARE_OUTPUT" | grep -v '^$' | head -1   # header line
echo ""

# Parse: extract lines with scores, check for regressions
REGRESSION_COUNT=0
REGRESSION_TASKS=""

while IFS= read -r line; do
  # Skip header and blank lines
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" =~ ^Tasks ]] && continue
  [[ "$line" =~ ^[[:space:]]*Score ]] && continue

  # Extract fields. Format:
  # "  1.102   0.907   1.000(#1)    0.9074(#2)   Task Name (*)"
  score=$(echo "$line" | awk '{print $1}')
  regressions=$(echo "$line" | awk '{print $4}')
  name=$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//; s/ (\*)//')

  # regressions is like "0.9074(#2)" — extract the numeric part
  reg_num=$(echo "$regressions" | sed 's/(.*//')

  if [ -n "$reg_num" ] && [ "$reg_num" != "1.000" ] && [ "$reg_num" != "1.000(#0)" ]; then
    # regression factor below 0.90 means >10% slower
    if awk -v r="$reg_num" 'BEGIN { exit (r < 0.90 ? 0 : 1) }'; then
      REGRESSION_COUNT=$((REGRESSION_COUNT + 1))
      REGRESSION_TASKS="${REGRESSION_TASKS}  ${RED}${reg_num}${NC}  ${name}\n"
      echo -e "  ${RED}✗${NC} $line"
    else
      echo "    $line"
    fi
  else
    echo "    $line"
  fi
done <<< "$(echo "$COMPARE_OUTPUT" | grep -v '^Tasks\|^  Score\|^$')"

echo ""

if [ "$REGRESSION_COUNT" -gt 0 ] 2>/dev/null; then
  echo -e "${RED}${BOLD}⚠  $REGRESSION_COUNT task(s) regressed >10%${NC}"
  echo ""
  echo -e "  Regressed tasks:"
  echo -e "$REGRESSION_TASKS"
  exit 1
fi

echo -e "${GREEN}✓${NC} No significant regressions detected"
exit 0
