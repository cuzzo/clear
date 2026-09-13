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

RUBYOPT="-r/home/yahn/cheat/tools/probe_multi_error" \
CLEAR_PROBE_ERROR_CAP="${CAP:-4000}" \
CLEAR_MODULE_CACHE_MAX_BYTES="${CACHEMAX:-536870912}" \
  timeout "${T:-5400}" ./clear build "$ENTRY" "${ARGS[@]}" --no-stack-check 2>&1 \
  | tee "$S/2b_all.log" | grep -c "Compiler Error" || true

echo "--- distinct blockers:"
grep 'Compiler Error' "$S/2b_all.log" | sed 's/@@PL=[0-9]*@@PC=[0-9]*//' | sort | uniq -c | sort -rn | head -25
echo "--- total: $(grep -c 'Compiler Error' "$S/2b_all.log") errors"
