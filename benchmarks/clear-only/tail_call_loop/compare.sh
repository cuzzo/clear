#!/usr/bin/env bash
# Phase 5b: TCO parity check.
#
# `:TAIL_CALL` should compile to the same self-`jmp` loop a
# hand-written WHILE produces -- wall time should match within
# noise. Different numbers indicate a TCO regression.
set -euo pipefail

cd "$(dirname "$0")/../../.."

CLEAR=./clear
BENCH_DIR=benchmarks/clear-only/tail_call_loop
RUNS=${RUNS:-5}

echo "Building bench_tail_call (optimized)..."
$CLEAR build $BENCH_DIR/bench_tail_call.clear --optimized -o $BENCH_DIR/bench_tail_call > /dev/null

echo "Building bench_loop (optimized)..."
$CLEAR build $BENCH_DIR/bench_loop.clear --optimized -o $BENCH_DIR/bench_loop > /dev/null

run_n() {
  local label="$1" bin="$2" rss_total=0 elapsed_total=0
  echo "=== $label ($RUNS runs) ==="
  for i in $(seq 1 "$RUNS"); do
    out=$(/usr/bin/time -f "elapsed=%e rss_kb=%M" "$bin" 2>&1 | tail -1)
    echo "$out"
    rss=$(echo "$out" | sed -n 's/.*rss_kb=\([0-9]*\).*/\1/p')
    el=$(echo "$out" | sed -n 's/.*elapsed=\([0-9.]*\).*/\1/p')
    rss_total=$(( rss_total + rss ))
    elapsed_total=$(echo "$elapsed_total + $el" | bc)
  done
  echo "  avg_rss_kb=$(( rss_total / RUNS ))  avg_elapsed=$(echo "scale=3; $elapsed_total / $RUNS" | bc)"
}

run_n "TAIL_CALL" "$BENCH_DIR/bench_tail_call"
run_n "LOOP"      "$BENCH_DIR/bench_loop"
