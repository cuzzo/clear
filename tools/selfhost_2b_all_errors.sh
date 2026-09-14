#!/bin/bash
# Stage 2b with EVERY error, not just the first.
#
# `./clear build` halts at the first annotation error, so one ~50 minute round
# reported one blocker and no denominator -- six rounds for six classes. The
# annotator's own accumulator (tools/probe_multi_error.rb) already solves this:
# it catches at the statement boundary, records, and carries on. The build runs
# the transpiler in-process, so loading it via RUBYOPT applies to the build.
#
# Later errors are guidance, not verdicts -- after a failed statement the
# session state is whatever that statement left behind. The point is a work
# list with a count instead of one blocker per round.
set -uo pipefail
cd /home/yahn/cheat
S=/tmp/claude-1000/-home-yahn-cheat/7ed765ab-7265-4fd7-87dd-cf01db5c8e57/scratchpad
ENTRY=tmp/stage2/stage2_entry.clear
[ -f "$ENTRY" ] || { echo "no $ENTRY" >&2; exit 1; }

# .clear-cache is the ZIG build dir, not the module cache -- cheap to drop.
# NEVER drop zig/.clear-module-cache: it holds the per-package compiled units
# keyed by source digest, and it is what keeps an unchanged package from being
# recompiled every round.
#
# The cap matters as much as the cache. module_cache.rb says it outright: "a
# cache too small for one generation evicts records as fast as they are
# written: the run stays permanently cold and the cache costs time instead of
# saving it." The corpus needs ~400MB+ per generation, so a 512MB cap (the
# default, which this script used to pass explicitly) thrashes. 6GB holds
# several generations.
rm -rf zig/.clear-cache
mapfile -t PKGS < <(bundle exec ruby -e '
$PROGRAM_NAME = "selfhost_stage2_support"
require_relative "tools/parser_compat"
GEN = File.join(Dir.pwd, "compiler", "src")
groups = ParserCompat.package_groups(GEN)
groups.each { |n, m| puts "#{n}=#{m.map { |r| File.join(GEN, r) }.join(",")}" }
ParserCompat.generated_relatives(GEN).each { |r| puts "#{ParserCompat.package_name(r)}=#{File.join(GEN, r)}" }
')
ARGS=(); for p in "${PKGS[@]}"; do ARGS+=(--pkg "$p"); done

rm -f "$S/census.tsv"
RUBYOPT="-r/home/yahn/cheat/tools/probe_multi_error" \
CLEAR_PROBE_CENSUS_FILE="$S/census.tsv" \
CLEAR_PROBE_ERROR_CAP="${CAP:-4000}" \
CLEAR_MODULE_CACHE_MAX_BYTES="${CACHEMAX:-6442450944}" \
  timeout "${T:-5400}" ./clear build "$ENTRY" "${ARGS[@]}" --no-stack-check 2>&1 \
  | tee "$S/2b_all.log" | grep -c "Compiler Error" || true

echo "=== FUNCTION CENSUS (the denominator):"
grep "@@CENSUS" "$S/2b_all.log" | tail -1
# The journal survives a hard death, which at_exit does not.
if [ -f "$S/census.tsv" ]; then
  awk -F'\t' '/^UNIT/ { n += $2 } /^FAIL/ { f[$2] = 1 } END {
    printf "@@JOURNAL functions=%d failed=%d passing=%d rate=%.2f%%\n", n, length(f), n - length(f), (n ? (n - length(f)) * 100.0 / n : 0)
  }' "$S/census.tsv"
fi
echo "--- failing functions:"
grep "@@FN" "$S/2b_all.log" | sed 's/@@FN //' | cut -c1-150 | head -40
echo "--- failing function count: $(grep -c '@@FN' "$S/2b_all.log")"

echo "--- distinct blockers:"
grep 'Compiler Error' "$S/2b_all.log" | sed 's/@@PL=[0-9]*@@PC=[0-9]*//' | sort | uniq -c | sort -rn | head -25
echo "--- total: $(grep -c 'Compiler Error' "$S/2b_all.log") errors"
