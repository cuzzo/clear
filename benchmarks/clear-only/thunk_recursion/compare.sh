#!/usr/bin/env bash
# Phase 5b: deep-recursion comparison.
#
# Builds bench_thunk + bench_reentrant (optimized) and prints
# RUNS measurements each, plus an averaged delta on time + peak
# RSS. The :THUNK variant should match :reentrant on time (same
# work, same body shape) and use dramatically less stack memory
# (heap Frames vs. 50,000 OS-thread frames).
set -euo pipefail

cd "$(dirname "$0")/../../.."

CLEAR=./clear
BENCH_DIR=benchmarks/clear-only/thunk_recursion
RUNS=${RUNS:-5}

echo "Building bench_thunk (optimized)..."
$CLEAR build $BENCH_DIR/bench_thunk.cht --optimized -o $BENCH_DIR/bench_thunk > /dev/null

echo "Building bench_reentrant (optimized)..."
$CLEAR build $BENCH_DIR/bench_reentrant.cht --optimized -o $BENCH_DIR/bench_reentrant > /dev/null

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

run_n "THUNK"     "$BENCH_DIR/bench_thunk"
run_n "REENTRANT" "$BENCH_DIR/bench_reentrant"
