#!/usr/bin/env bash
set -u

status=0
tracer="gems/nil-kill/lib/nil_kill/runtime_trace.rb"
jobs="${NIL_KILL_JOBS:-${NK_JOBS:-$(nproc 2>/dev/null || echo 1)}}"

should_skip_live_data_file() {
  case "$1" in
    benchmarks/concurrent/12_false_sharing/bench.cht|\
    benchmarks/concurrent/13_rwlock_starvation/bench.cht|\
    benchmarks/concurrent/14_nested_lock/bench.cht|\
    benchmarks/concurrent/19_atomic_ptr/bench.cht|\
    benchmarks/inter-clear/03_concurrent_mvcc_vs_rwlock/bench.cht|\
    benchmarks/inter-clear/04_concurrent_mvcc_fat_struct/bench.cht|\
    benchmarks/inter-clear/05_concurrent_mvcc_pure_read/bench.cht|\
    benchmarks/inter-clear/06_concurrent_mvcc_writer_pressure/bench.cht|\
    examples/minivm/_bc_runner.cht|\
    examples/minivm/_scheme_runner.cht|\
    examples/minivm/bench_pool_ops.cht|\
    examples/minivm/bench_pool_ops_nosync.cht|\
    examples/minivm/debugger.cht|\
    examples/minivm/parser.cht|\
    examples/minivm/register_debugger.cht|\
    examples/minivm/sus-int.cht|\
    examples/minivm/types.cht|\
    examples/minivm/vm.cht|\
    examples/minivm/vtest.cht)
      # Temporary live-data exclusions for .cht files that do not currently
      # transpile. The minivm files are corpus/compiler-cleanup exceptions.
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

run_transpiler_with_timeout() {
  local file="$1"
  local timeout_seconds="${NIL_KILL_REQUIRE_CHT_TIMEOUT:-120}"

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" bash -c 'NIL_KILL_NOOP_SORBET="${NIL_KILL_NOOP_SORBET:-1}" RUBYOPT="${RUBYOPT:+$RUBYOPT }-rbundler/setup -r./gems/nil-kill/lib/nil_kill/runtime_trace.rb" ruby src/backends/transpiler.rb "$1"' _ "$file"
  else
    run_transpiler "$file"
  fi
}

export -f run_transpiler run_transpiler_with_timeout should_skip_live_data_file
export tracer

run_require_corpus() {
  local require_file="$1"
  local shard_size="${NIL_KILL_REQUIRE_CHT_SHARD_SIZE:-1}"
  local shard_dir
  shard_dir="$(dirname "$require_file")"
  local failures=0

  rm -f "$shard_dir"/require-corpus-shard-*.cht
  mkdir -p "$shard_dir"

  ruby - "$require_file" "$shard_dir" "$shard_size" <<'RUBY'
require "fileutils"

source = ARGV.fetch(0)
out_dir = ARGV.fetch(1)
shard_size = Integer(ARGV.fetch(2), 10)
raise "shard size must be positive" unless shard_size.positive?

requires = File.readlines(source).grep(/\AREQUIRE\b/)
requires.each_slice(shard_size).with_index do |lines, index|
  body = +"# Generated shard from #{source}\n"
  body << "# Do not edit by hand.\n\n"
  body << lines.join
  body << "\nFN main() RETURNS Void ->\n"
  body << "  RETURN;\n"
  body << "END\n"
  File.write(File.join(out_dir, format("require-corpus-shard-%04d.cht", index)), body)
end
RUBY

  find "$shard_dir" -maxdepth 1 -type f -name 'require-corpus-shard-*.cht' -print0 \
    | sort -z \
    | xargs -0 -P "$jobs" -I{} bash -c '
        if ! run_transpiler_with_timeout "$1" >/dev/null; then
          echo "nil-kill corpus shard failed: $1" >&2
          exit 1
        fi
      ' _ {} || failures=$?

  return "$failures"
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
  if run_require_corpus "$require_file"; then
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

find examples benchmarks -path '*/bench.profile/*' -prune -o -type f -name '*.cht' -print0 \
  | sort -z \
  | xargs -0 -P "$jobs" -I{} bash -c '
      file="$1"
      should_skip_live_data_file "$file" && exit 0
      run_transpiler_with_timeout "$file" >/dev/null
    ' _ {} || status=1

exit "$status"
