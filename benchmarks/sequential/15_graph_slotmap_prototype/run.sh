#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

out="${TMPDIR:-/tmp}/clear-graph-slotmap-bench"
mkdir -p "$out"

zig build-exe bench.zig -O ReleaseFast -lc -femit-bin="$out/bench_zig"
zig build-exe -O ReleaseFast -lc --dep clear_runtime -Mroot=bench_clear_runtime.zig \
  -Mclear_runtime=../../../zig/graph-benchmark-runtime.zig \
  -femit-bin="$out/bench_clear_runtime"
cc -O3 -march=native -std=c11 -D_POSIX_C_SOURCE=200809L bench.c -o "$out/bench_c"
rustc -C opt-level=3 bench.rs -o "$out/bench_rust"
go build -o "$out/bench_go" bench.go

runs="${RUNS:-5}"
scale="${BENCH_SCALE:-1.0}"

echo "Zig proposed safe generational slot map:"
for _ in $(seq 1 "$runs"); do BENCH_SCALE="$scale" "$out/bench_zig"; done

echo "CLEAR actual runtime (manual Pool, then Rc/WeakRc LINK/RESOLVE primitives):"
for _ in $(seq 1 "$runs"); do BENCH_SCALE="$scale" "$out/bench_clear_runtime"; done

echo "Rust idiomatic safe Rc<RefCell<Node>> + Weak:"
for _ in $(seq 1 "$runs"); do BENCH_SCALE="$scale" "$out/bench_rust"; done

echo "Go tracing GC with raw language-level pointers (forced post-collapse GC):"
for _ in $(seq 1 "$runs"); do BENCH_SCALE="$scale" "$out/bench_go"; done

echo "C ideal unchecked index, raw-pointer, and unsafe slotmap lower bounds:"
for _ in $(seq 1 "$runs"); do BENCH_SCALE="$scale" "$out/bench_c"; done
