#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

out="${TMPDIR:-/tmp}/clear-graph-slotmap-bench"
results="${RESULTS_FILE:-${TMPDIR:-/tmp}/clear-graph-slotmap-matrix.txt}"
runs="${RUNS:-5}"
sizes="${SIZES:-4096 16384 65536 262144 1000000}"
cpu="${BENCH_CPU:-0}"
mkdir -p "$out"

zig build-exe bench.zig -O ReleaseFast -lc -femit-bin="$out/bench_zig"
zig build-exe -O ReleaseFast -lc --dep clear_runtime -Mroot=bench_clear_runtime.zig \
  -Mclear_runtime=../../../zig/graph-benchmark-runtime.zig \
  -femit-bin="$out/bench_clear_runtime"
cc -O3 -march=native -std=c11 -D_POSIX_C_SOURCE=200809L bench.c -o "$out/bench_c"
rustc -C opt-level=3 bench.rs -o "$out/bench_rust"
go build -o "$out/bench_go" bench.go

: > "$results"
for size in $sizes; do
  for rep in $(seq 1 "$runs"); do
    for impl in bench_c bench_zig bench_clear_runtime bench_rust bench_go; do
      echo "MATRIX size=$size rep=$rep binary=$impl" >> "$results"
      BENCH_N="$size" GOMAXPROCS=1 taskset -c "$cpu" "$out/$impl" >> "$results" 2>&1
    done
  done
done

echo "$results"
