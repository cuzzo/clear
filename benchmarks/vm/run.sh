#!/bin/bash
# Benchmark runner: BC VM (CLEAR) vs Python / Ruby / Lua / Node.
LUA=${LUA:-/tmp/lua-5.4.7/src/lua}
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$DIR")/.."

extract_bench_ms() {
  grep -oP "BENCH_RESULT: \K\d+" | tail -1
}

run_one() {
  local name="$1"
  printf "\n=== %s ===\n" "$name"
  printf "%-12s %10s\n" "lang" "ms"
  printf -- "------------ ----------\n"

  # CLEAR BC VM
  if [ -f "$DIR/${name}.cht" ]; then
    out=$(timeout 60 ruby "$DIR/../../examples/minivm/bc_run.rb" "$DIR/${name}.cht" 2>&1)
    ms=$(echo "$out" | extract_bench_ms)
    printf "%-12s %10s\n" "clear-bc" "${ms:-TIMEOUT}"
  fi

  # Puck tutorial Ruby VM (v9)
  if [ -f "$DIR/${name}.puck" ]; then
    out=$(timeout 120 ruby "$DIR/run_puck.rb" "$DIR/${name}.puck" 2>&1)
    ms=$(echo "$out" | extract_bench_ms)
    printf "%-12s %10s\n" "puck-rb" "${ms:-TIMEOUT}"
  fi

  # CLEAR Zig backend (for comparison; --release for ReleaseFast)
  if [ -f "$DIR/${name}.cht" ]; then
    "$(dirname "$DIR")/../clear" build "$DIR/${name}.cht" -o "$DIR/.bench_clear" --optimized > /dev/null 2>&1
    if [ -x "$DIR/.bench_clear" ]; then
      out=$(timeout 60 "$DIR/.bench_clear" 2>&1)
      ms=$(echo "$out" | extract_bench_ms)
      printf "%-12s %10s\n" "clear-zig" "${ms:-TIMEOUT}"
      rm -f "$DIR/.bench_clear"
    fi
  fi

  # Python
  if [ -f "$DIR/${name}.py" ]; then
    out=$(timeout 60 python3 "$DIR/${name}.py" 2>&1)
    ms=$(echo "$out" | extract_bench_ms)
    printf "%-12s %10s\n" "python3" "${ms:-TIMEOUT}"
  fi

  # Ruby
  if [ -f "$DIR/${name}.rb" ]; then
    out=$(timeout 60 ruby "$DIR/${name}.rb" 2>&1)
    ms=$(echo "$out" | extract_bench_ms)
    printf "%-12s %10s\n" "ruby" "${ms:-TIMEOUT}"
  fi

  # Lua
  if [ -f "$DIR/${name}.lua" ] && [ -x "$LUA" ]; then
    out=$(timeout 60 "$LUA" "$DIR/${name}.lua" 2>&1)
    ms=$(echo "$out" | extract_bench_ms)
    printf "%-12s %10s\n" "lua-5.4" "${ms:-TIMEOUT}"
  fi

  # Node
  if [ -f "$DIR/${name}.js" ]; then
    out=$(timeout 60 node "$DIR/${name}.js" 2>&1)
    ms=$(echo "$out" | extract_bench_ms)
    printf "%-12s %10s\n" "node" "${ms:-TIMEOUT}"
  fi
}

if [ -n "$1" ]; then
  run_one "$1"
else
  for f in "$DIR"/*.cht; do
    name=$(basename "$f" .cht)
    run_one "$name"
  done
fi
