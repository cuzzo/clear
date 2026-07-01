#!/usr/bin/env bash
# Side-by-side comparison runner: builds both variants (optimized) and
# prints 5 runs each plus a summary delta on peak RSS.
set -euo pipefail

cd "$(dirname "$0")/../../.."

CLEAR=./clear
BENCH_DIR=benchmarks/clear-only/fsm_concurrency
RUNS=${RUNS:-5}

echo "Building bench_fsm (optimized)..."
$CLEAR build $BENCH_DIR/bench_fsm.clear --optimized -o $BENCH_DIR/bench_fsm > /dev/null

echo "Building bench_stackful (optimized)..."
$CLEAR build $BENCH_DIR/bench_stackful.clear --optimized -o $BENCH_DIR/bench_stackful > /dev/null

run_n() {
  local label="$1" bin="$2" rss_total=0 elapsed_total=0
  echo "=== $label ($RUNS runs) ==="
  for i in $(seq 1 "$RUNS"); do
    out=$(/usr/bin/time -f "elapsed=%e rss_kb=%M minor_pf=%R vol_cs=%w" "$bin" 2>&1 | tail -1)
    echo "$out"
    rss=$(echo "$out" | sed -n 's/.*rss_kb=\([0-9]*\).*/\1/p')
    el=$(echo "$out" | sed -n 's/.*elapsed=\([0-9.]*\).*/\1/p')
    rss_total=$(( rss_total + rss ))
    elapsed_total=$(echo "$elapsed_total + $el" | bc)
  done
  echo "  avg_rss_kb=$(( rss_total / RUNS ))  avg_elapsed=$(echo "scale=3; $elapsed_total / $RUNS" | bc)"
}

run_n "FSM" "$BENCH_DIR/bench_fsm"
run_n "Stackful @xl" "$BENCH_DIR/bench_stackful"
