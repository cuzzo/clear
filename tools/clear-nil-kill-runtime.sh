#!/usr/bin/env bash
# nil-kill runtime evidence workload. Run under `nil-kill collect`.
#
# Evidence-collection workload. Stages are isolated from each other: a
# failure does not abort collection immediately, so we keep the runtime
# observed up to it and run every later stage. The script still exits
# nonzero at the end if any stage failed, so a dirty collect cannot look
# clean. Set NIL_KILL_ALLOW_STAGE_FAILURES=1 only when intentionally
# collecting partial evidence from a broken tree.
#
# Speed: under nil-kill's source-instrumentation + tracer each Ruby
# process is ~100x slower, so PARALLELISM is the dominant lever.
# NK_JOBS controls fan-out (default = all cores). Lower it if the box
# is memory-bound (each traced worker loads full src + sorbet-runtime
# + tracer). Per-stage wall-clock is printed so the slow stage is
# obvious.
set -uo pipefail

JOBS="${NK_JOBS:-$(nproc)}"
# parallel_rspec (this `prspec`) reads ENV['WORKERS'] (default 4 --
# that was the ~4-of-32-cores bottleneck). It forwards all CLI args
# to rspec, so a `-n` flag is mis-parsed as a spec file; WORKERS is
# the only correct knob.
export WORKERS="$JOBS"
TOTAL_START=$SECONDS
FAILED_STAGES=()

record_stage_failure() {
  local label="$1"
  FAILED_STAGES+=("$label")
  echo "=== [$label] stage failed, continuing ==="
}

run() {
  local label="$1"; shift
  local t0=$SECONDS
  echo "=== nil-kill workload [$label] start (jobs=$JOBS) ==="
  "$@" || record_stage_failure "$label"
  echo "=== nil-kill workload [$label] done in $((SECONDS - t0))s ==="
}

# Run `ruby <cmd...> <file>` over a NUL-delimited file list, JOBS-way
# parallel. Each child inherits RUBYOPT -> traced; each writes its own
# PID-keyed dump, merged by `infer` (parallel-safe by construction).
par_ruby() { # par_ruby <label> <find-args...> -- <ruby args...>
  local label="$1"; shift
  local find_args=() ruby_args=()
  while [ "$1" != "--" ]; do find_args+=("$1"); shift; done
  shift
  ruby_args=("$@")
  local t0=$SECONDS
  echo "=== nil-kill workload [$label] start (jobs=$JOBS) ==="
  if ! find "${find_args[@]}" -print0 \
    | xargs -0 -P "$JOBS" -I{} ruby "${ruby_args[@]}" {} >/dev/null 2>&1; then
    record_stage_failure "$label"
  fi
  echo "=== nil-kill workload [$label] done in $((SECONDS - t0))s ==="
}

# 1-3. Specs (prspec = parallel_rspec; WORKERS env scales workers to
#       all cores instead of the gem's default of 4).
run unit-specs bundle exec prspec spec/
# Source tracing slows MiniVM subprocesses enough that the normal 10s
# golden timeout can trip even when the VM is healthy. Keep the override
# scoped to nil-kill collection so ordinary integration specs stay strict.
run integration-specs env MINIVM_GOLDEN_TIMEOUT_SECONDS="${NIL_KILL_MINIVM_GOLDEN_TIMEOUT_SECONDS:-120}" bundle exec prspec spec/ --tag integration
run nil-kill-specs bundle exec prspec gems/nil-kill/spec/

# 4. Transpile-tests corpus. gen.rb --single is the same Ruby pipeline
#    (CompilerFrontend + MIRLowering + MIRChecker + MIREmitter) the
#    collated-SimpleCov `transpile-tests` entry runs, per file, with
#    NO shared-file write (stdout only) -> safe to run JOBS-way
#    parallel. We skip `zig test all-tests.zig` (pure Zig, zero Ruby
#    value). Was one serial process over ~468 files -- the biggest
#    single-core bottleneck.
par_ruby transpile-corpus transpile-tests -maxdepth 1 -name '*.cht' -- transpile-tests/gen.rb --single

# 5. Fuzz matrix -- randomized inputs hammer lexer/parser/annotator/MIR.
run fuzz-matrix ruby tools/fuzz/run.rb --matrix \
  --templates access_gate,execution_boundary,stream_into_boundary,loop_carry_collection,mutable_collection_param \
  --out /tmp/clear-nil-kill-fuzz --clean --jobs "$JOBS"

# 6. Transpile example + benchmark corpus (front-to-MIR Ruby pipeline).
# Use the dedicated corpus helper instead of raw per-file transpiles: it
# shards REQUIRE-heavy coverage, skips known MiniVM cleanup exceptions, and
# applies per-file timeouts so a single pathological file cannot stall the
# whole evidence run.
run examples-transpile bash tools/clear-nil-kill-transpile-corpus.sh

# 7. Full default build of every example + benchmark -- MIR checker +
#    backend codegen Ruby that pure transpile skips. Parallel via the
#    CLI (each `clear build` is its own traced process). Keep this
#    timeout-protected: under source tracing, large interpreter examples can
#    run for minutes and should not block the entire collect.
should_skip_build_file() {
  case "$1" in
    examples/mal/*|\
    examples/minivm/*)
      return 0
      ;;
  esac
  return 1
}

has_clear_main() {
  grep -Eq '^[[:space:]]*FN[[:space:]]+main[[:space:]]*\(' "$1"
}

build_one() {
  should_skip_build_file "$1" && return 0
  has_clear_main "$1" || return 0
  local timeout_seconds="${NIL_KILL_BUILD_TIMEOUT:-300}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" ./clear build "$1" -o "/tmp/clear-nk-build.$$.bin" >/dev/null 2>&1
  else
    ./clear build "$1" -o "/tmp/clear-nk-build.$$.bin" >/dev/null 2>&1
  fi
}
export -f should_skip_build_file
export -f has_clear_main
export -f build_one
{
  local_t0=$SECONDS
  echo "=== nil-kill workload [examples-build] start (jobs=$JOBS) ==="
  if ! find examples benchmarks -path '*/bench.profile/*' -prune -o -type f -name '*.cht' -print0 \
    | xargs -0 -P "$JOBS" -I{} bash -c 'build_one "$@"' _ {}; then
    record_stage_failure "examples-build"
  fi
  echo "=== nil-kill workload [examples-build] done in $((SECONDS - local_t0))s ==="
}

# 8. Package / FFI integration (zig build drives the Ruby pipeline).
run module-integration bash -c 'cd transpile-tests/module-integration && zig build test'
run ffi-integration    bash -c 'cd transpile-tests/ffi-integration && zig build test'

# 9. Example test files -- gen.rb --single is the Ruby half (skip Zig).
par_ruby example-tests examples/testing -maxdepth 1 -name '*.cht' -- transpile-tests/gen.rb --single

echo "=== nil-kill workload complete in $((SECONDS - TOTAL_START))s (jobs=$JOBS) ==="
if ((${#FAILED_STAGES[@]} > 0)); then
  echo "=== nil-kill workload failed stages: ${FAILED_STAGES[*]} ===" >&2
  if [ "${NIL_KILL_ALLOW_STAGE_FAILURES:-0}" = "1" ]; then
    echo "=== NIL_KILL_ALLOW_STAGE_FAILURES=1 set; returning success with partial evidence ===" >&2
  else
    exit 1
  fi
fi
