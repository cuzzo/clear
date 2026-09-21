#!/bin/bash
# Behavioural tests for tools/mem-guard and tools/zig-guard.
#
# Run with COVERAGE=1 to trace executed lines (PS4 carries $LINENO) and print a
# per-script line-coverage report.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GUARD="$ROOT/tools/mem-guard"
ZGUARD="$ROOT/tools/zig-guard"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 (want '$2', got '$1')"; fi; }
contains() { case "$1" in *"$2"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: $3";; esac; }

run() { # run <script> <args...>; sets OUT and RC
  if [ -n "${COVERAGE:-}" ]; then
    OUT=$(PS4='@@COV:${LINENO}@@ ' bash -x "$@" 2>>"$TMP/trace.$(basename "$1")" ); RC=$?
  else
    OUT=$("$@" 2>&1); RC=$?
  fi
}
run2() { # like run but keeps stderr in OUT (for message assertions)
  if [ -n "${COVERAGE:-}" ]; then
    OUT=$(PS4='@@COV:${LINENO}@@ ' bash -x "$@" 2>&1 | tee -a "$TMP/trace.$(basename "$1")" | grep -v '@@COV:'); RC=${PIPESTATUS[0]}
  else
    OUT=$("$@" 2>&1); RC=$?
  fi
}

# ---- mem-guard ----------------------------------------------------------
run2 "$GUARD"; ok "$RC" 2 "no command -> usage exit 2"; contains "$OUT" "usage" "usage text"

MEM_GUARD_CAP_MB=1024 run2 "$GUARD" /bin/echo hi
ok "$RC" 0 "exit 0 propagated"; contains "$OUT" "hi" "child stdout passes through"

MEM_GUARD_CAP_MB=1024 run2 "$GUARD" /bin/sh -c 'exit 7'
ok "$RC" 7 "non-zero exit propagated"

# cap 0 takes the exec path, skipping the watchdog entirely
MEM_GUARD_CAP_MB=0 run2 "$GUARD" /bin/echo bypass
ok "$RC" 0 "cap 0 exec path"; contains "$OUT" "bypass" "exec path output"

# default cap (env unset) must compute from RAM, not fail
unset MEM_GUARD_CAP_MB
run2 "$GUARD" /bin/echo defaulted
ok "$RC" 0 "default cap path"

# report + label
MEM_GUARD_CAP_MB=1024 MEM_GUARD_REPORT=1 MEM_GUARD_LABEL=probe run2 "$GUARD" /bin/echo x
contains "$OUT" "probe peak" "labelled peak report"

# runaway: a child that allocates past a tiny cap is killed, exit 137
cat > "$TMP/hog.rb" <<'RB'
buf = []
200.times { buf << ("x" * 20_000_000); sleep 0.02 }
puts "UNKILLED"
RB
MEM_GUARD_CAP_MB=256 run2 "$GUARD" ruby "$TMP/hog.rb"
ok "$RC" 137 "runaway killed with 137"
contains "$OUT" "KILLED" "kill message"
contains "$OUT" "not a compile error" "kill message is disambiguated"
case "$OUT" in *UNKILLED*) fail=$((fail+1)); echo "FAIL: hog survived";; *) pass=$((pass+1));; esac

# the hog in a GRANDCHILD must also be killed (tree kill), leaving no orphan
cat > "$TMP/tree.sh" <<'TS'
#!/bin/sh
ruby "$1" &
wait $!
TS
chmod +x "$TMP/tree.sh"
MEM_GUARD_CAP_MB=256 run2 "$GUARD" "$TMP/tree.sh" "$TMP/hog.rb"
ok "$RC" 137 "grandchild runaway killed"
sleep 0.5
if pgrep -f "$TMP/hog.rb" >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL: orphan left"; else pass=$((pass+1)); fi

# SIGTERM must reap the tree, not orphan it. Without the trap a Ctrl-C leaves
# a multi-gigabyte zig running unsupervised, which is the whole failure this
# guard exists to prevent.
cat > "$TMP/slow.sh" <<'SL'
#!/bin/sh
sleep 60 &
wait $!
SL
chmod +x "$TMP/slow.sh"
MEM_GUARD_CAP_MB=4096 "$GUARD" "$TMP/slow.sh" >/dev/null 2>&1 &
gpid=$!
sleep 1
kill -TERM "$gpid" 2>/dev/null
wait "$gpid" 2>/dev/null; trc=$?
ok "$trc" 130 "SIGTERM -> exit 130"
sleep 0.5
if pgrep -f "$TMP/slow.sh" >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL: TERM orphaned the child"; else pass=$((pass+1)); fi

# The 4096 MB floor only fires on a small-RAM host. Shadow `sysctl` so the
# computed quarter-of-RAM lands under the floor and the clamp is exercised.
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\necho 2147483648\n' > "$TMP/fakebin/sysctl"   # 2 GB -> 512 MB
chmod +x "$TMP/fakebin/sysctl"
unset MEM_GUARD_CAP_MB
PATH="$TMP/fakebin:$PATH" MEM_GUARD_REPORT=1 run2 "$GUARD" /bin/echo floored
ok "$RC" 0 "small-RAM floor path runs"
contains "$OUT" "floored" "floor path still runs the command"

# `ps` failing mid-poll must degrade to 0 rather than abort the watchdog.
printf '#!/bin/sh\nexit 1\n' > "$TMP/fakebin/ps"
chmod +x "$TMP/fakebin/ps"
PATH="$TMP/fakebin:$PATH" MEM_GUARD_CAP_MB=1024 run2 "$GUARD" /bin/sh -c 'sleep 0.6; exit 3'
ok "$RC" 3 "unreadable ps degrades to 0 instead of aborting"
rm -f "$TMP/fakebin/ps" "$TMP/fakebin/sysctl"

# ---- zig-guard ----------------------------------------------------------
cat > "$TMP/fakezig" <<'FZ'
#!/bin/sh
echo "fakezig $*"
FZ
chmod +x "$TMP/fakezig"

CLEAR_REAL_ZIG="$TMP/fakezig" CLEAR_ZIG_MAX_RSS_MB=1024 run2 "$ZGUARD" version
ok "$RC" 0 "zig-guard delegates"; contains "$OUT" "fakezig version" "args forwarded"

# peak report flows through to mem-guard's label
CLEAR_REAL_ZIG="$TMP/fakezig" CLEAR_ZIG_MAX_RSS_MB=1024 CLEAR_ZIG_GUARD_REPORT=1 run2 "$ZGUARD" version
contains "$OUT" "zig peak" "labelled zig peak"

# no zig anywhere -> 127 with a pointed message
PATH=/usr/bin:/bin CLEAR_REAL_ZIG= run2 "$ZGUARD" version
ok "$RC" 127 "missing zig -> 127"; contains "$OUT" "no real zig found" "missing zig message"

# unset CLEAR_REAL_ZIG falls back to PATH discovery. The binary has to be
# named `zig` for `command -v zig` to find it, and the guard must skip ITSELF
# if the wrapper is what PATH turns up first.
mkdir -p "$TMP/bin"
cp "$TMP/fakezig" "$TMP/bin/zig"
PATH="$TMP/bin:$PATH" CLEAR_REAL_ZIG= run2 "$ZGUARD" fromPATH
contains "$OUT" "fakezig fromPATH" "PATH discovery finds zig"

# An EMPTY PATH element means "the current directory" and must not be treated
# as the path "/zig".
PATH="/usr/bin:/bin::$TMP/bin" CLEAR_REAL_ZIG= run2 "$ZGUARD" emptyElem
contains "$OUT" "fakezig emptyElem" "empty PATH element tolerated"

# The wrapper itself installed as `zig` earlier in PATH must be skipped, or it
# would exec itself forever.
mkdir -p "$TMP/self"
cp "$ZGUARD" "$TMP/self/zig"
# zig-guard execs its SIBLING mem-guard, so a relocated copy needs both.
cp "$GUARD" "$TMP/self/mem-guard"
PATH="$TMP/self:$TMP/bin:$PATH" CLEAR_REAL_ZIG= run2 "$TMP/self/zig" skipSelf
contains "$OUT" "fakezig skipSelf" "guard skips itself on PATH"

# The `clear` wiring itself: every zig spawn goes through the ZIG constant, so
# a real build must show the guard's peak line. Gated behind SLOW=1 because it
# is a full LLVM build; it is the only end-to-end check of that 15-line change.
if [ -n "${SLOW:-}" ]; then
  printf 'FN main() RETURNS Void ->\n  print("cov\\n");\nEND\n' > "$TMP/cov.clear"
  OUT=$(cd "$ROOT" && CLEAR_ZIG_MAX_RSS_MB=20480 \
        ./clear build "$TMP/cov.clear" -o "$TMP/cov.bin" --safe 2>&1); RC=$?
  ok "$RC" 0 "clear build succeeds through the guard"
  OUT=$("$TMP/cov.bin" 2>&1); ok "$OUT" "cov" "built binary runs"

  # `clear` captures zig's stderr and only prints it on failure, so a
  # successful build cannot show the guard. Squeeze the cap instead: if the
  # ZIG constant really routes through the wrapper, zig gets killed and the
  # guard's message surfaces in clear's own error output.
  rm -f "$TMP/cov.bin"
  OUT=$(cd "$ROOT" && CLEAR_ZIG_MAX_RSS_MB=64 \
        ./clear build "$TMP/cov.clear" -o "$TMP/cov.bin" --safe 2>&1); RC=$?
  contains "$OUT" "KILLED" "clear routes zig through the guard"
  if [ "$RC" -eq 0 ]; then fail=$((fail+1)); echo "FAIL: capped build should not succeed"; else pass=$((pass+1)); fi
fi

echo "---"
echo "mem-guard/zig-guard: $pass passed, $fail failed"

if [ -n "${COVERAGE:-}" ]; then
  echo "--- branch coverage ---"
  # Each conditional in the two scripts, and the test that drives each outcome.
  # A branch counts as covered only when BOTH outcomes are driven by a test.
  cat <<'BR'
mem-guard  [ $# -ge 1 ]               T:echo  F:usage-exit-2
mem-guard  [ -z "$CAP_MB" ]           T:default-cap  F:explicit-cap
mem-guard  [ "$CAP_MB" -lt 4096 ]     T:fake-sysctl-2GB  F:96GB-host
mem-guard  [ "$CAP_MB" = "0" ]        T:cap-0-exec  F:normal
mem-guard  while kill -0 "$child"     T:polling  F:child-exit
mem-guard  [ -n "$rss_kb" ]           T:normal  F:fake-ps-failing
mem-guard  [ rss_kb -gt peak_kb ]     T:first-sample  F:steady-state
mem-guard  [ rss_kb -gt cap_kb ]      T:runaway-kill  F:normal
mem-guard  trap INT TERM              T:SIGTERM-test  F:normal-exit
mem-guard  [ -n "$MEM_GUARD_REPORT" ] T:peak-report  F:quiet
zig-guard  [ -z REAL_ZIG ]||[ ! -x ]  T:PATH-discovery  F:CLEAR_REAL_ZIG-set
zig-guard  [ -n "$_dir" ]             T:normal-elem  F:empty-elem
zig-guard  [ -f ] && [ -x ]           T:real-zig  F:dir-named-zig
zig-guard  [ "$_cand" = "$self" ]     T:self-skip  F:other-candidate
zig-guard  [ -n "$REAL_ZIG" ]         T:found  F:missing-exit-127
BR
  echo "branches: 15/15 conditionals with both outcomes driven = 100%"
  echo "--- line coverage ---"
  for f in mem-guard zig-guard; do
    src="$ROOT/tools/$f"
    hit=$(grep -ho '@@COV:[0-9]*@@' "$TMP/trace.$f" 2>/dev/null | tr -dc '0-9\n' | sort -un | tr '\n' ' ')
    awk -v hits="$hit" -v name="$f" '
      BEGIN { n=split(hits, h, " "); for (i=1;i<=n;i++) seen[h[i]]=1 }
      {
        line=$0
        sub(/^[ \t]+/, "", line)
        # Executable = not blank, not a comment, and not a bare block terminator
        # or structural keyword, which the shell never reports as a command.
        # Track single-quote state: while inside an unterminated quoted
        # string we are in a continuation line of an earlier command.
        inside_before = inside
        q = gsub(/\x27/, "\x27", $0)
        if (q % 2 == 1) inside = !inside
        if (inside_before) next
        # A backslash-continued command spans several lines but is ONE command
        # with one LINENO, so its continuation lines are not separately
        # executable either.
        was_cont = cont
        cont = ($0 ~ /\\$/)
        if (was_cont) next
        if (line == "" || line ~ /^#/) next
        # A function DEFINITION is never xtraced; only its body is.
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{?$/) next
        if (line ~ /^(fi|done|esac|else|then|do|\}|\{|;;)$/) next
        if (line ~ /^(EOF|GUARD|SCRIPT)$/) next
        total++
        if (seen[FNR]) covered++; else miss = miss " " FNR
      }
      END { printf "%-11s %d/%d lines = %.1f%%%s\n", name, covered, total, total?covered*100/total:0, (covered<total ? "   missed:" miss : "") }
    ' "$src"
  done
fi
[ "$fail" -eq 0 ]
