#!/usr/bin/env bash
set -u

status=0
tracer="tools/nil-kill/runtime_trace.rb"

should_skip_live_data_file() {
  case "$1" in
    examples/brnfk/brnfk.cht|\
    examples/footguns/06_memory_ordering/main.cht|\
    examples/footguns/07_causal_ordering/main.cht|\
    examples/mal/interpreter.cht|\
    examples/minivm/_bc_runner.cht|\
    examples/minivm/_scheme_runner.cht|\
    examples/minivm/bench_pool_ops.cht|\
    examples/minivm/bench_pool_ops_nosync.cht|\
    examples/minivm/debugger.cht|\
    examples/minivm/parser.cht|\
    examples/minivm/sus-int.cht|\
    examples/minivm/types.cht|\
    examples/minivm/vtest.cht)
      # Temporary live-data exclusions for .cht files that do not currently
      # transpile. 06/07 are blocked by the pending BG promise-capture bug;
      # the rest are stale corpus/compiler-cleanup items found by the live
      # data inventory. Remove these once the repository is cleaned up.
      return 0
      ;;
  esac
  return 1
}

run_transpiler() {
  NIL_KILL_NOOP_SORBET="${NIL_KILL_NOOP_SORBET:-1}" \
    RUBYOPT="${RUBYOPT:+$RUBYOPT }-rbundler/setup -r./${tracer}" \
    ruby src/backends/transpiler.rb "$1"
}

# Temporary repository-specific tolerance: some .cht files either intentionally
# do not compile today or are blocked by current compiler regressions. Once the
# repository is cleaned up, this script should stop skipping failures and every
# .cht file should contribute runtime collection data.
#
# The raw concatenated corpus is still a compiler debugging artifact: requiring
# each file is the preferred fast path because it preserves file/module
# boundaries while exercising the corpus in one command.
#
# The require-wrapper corpus is the fast path because it asks the compiler to
# keep file/module boundaries while still exercising the corpus in one command.
if [ "${NIL_KILL_REQUIRE_CHT_CORPUS:-1}" = "1" ]; then
  require_file="$(ruby tools/clear-nil-kill-require-cht-corpus.rb)"
  if run_transpiler "$require_file" >/dev/null; then
    exit 0
  fi

  status=1
  if [ "${NIL_KILL_REQUIRE_CHT_ONLY:-0}" = "1" ]; then
    exit "$status"
  fi
fi

if [ "${NIL_KILL_COMBINED_CHT_CORPUS:-0}" = "1" ]; then
  combined_file="$(ruby tools/clear-nil-kill-combine-cht-corpus.rb)"
  if run_transpiler "$combined_file" >/dev/null; then
    exit 0
  fi

  status=1
  if [ "${NIL_KILL_COMBINED_CHT_ONLY:-0}" = "1" ]; then
    exit "$status"
  fi
fi

while IFS= read -r -d '' file; do
  if should_skip_live_data_file "$file"; then
    continue
  fi

  if ! run_transpiler "$file" >/dev/null; then
    status=1
  fi
done < <(find examples benchmarks -type f -name '*.cht' -print0 | sort -z)

exit "$status"
