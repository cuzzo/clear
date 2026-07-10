#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
root="$(cd ../../.. && pwd)"
out="${TMPDIR:-/tmp}/clear-node-bench"
runs="${RUNS:-5}"
cpu="${BENCH_CPU:-0}"
mkdir -p "$out"

"$root/clear" build bench_node.clear --optimized -o "$out/bench_clear_node"
zig build-exe -O ReleaseFast -lc --dep clear_runtime -Mroot=bench_node_manual.zig \
  -Mclear_runtime="$root/zig/graph-benchmark-runtime.zig" \
  -femit-bin="$out/bench_node_manual"

for rep in $(seq 1 "$runs"); do
  echo "NODE_RUN rep=$rep impl=clear-node"
  taskset -c "$cpu" "$out/bench_clear_node"
  echo "NODE_RUN rep=$rep impl=manual-zig-slotmap"
  taskset -c "$cpu" "$out/bench_node_manual"
done
