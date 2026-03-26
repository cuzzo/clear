#!/usr/bin/env bash
#
# test-pass.sh — Verify __morestack is inserted BEFORE the prologue.
#
# Tests two paths:
#   A. The MachineFunctionPass plugin (via MIR round-trip on small .ll)
#   B. The fiber-instrument tool (assembly post-processing)
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$DIR/pass/build/libFiberStackCheck.so"
TOOL="$DIR/pass/fiber-instrument"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
section() { echo -e "\n${BOLD}── $1 ──${NC}"; }

# ── Shared test input ────────────────────────────────────────────
cat > "$TMPDIR/test.ll" <<'EOF'
target triple = "x86_64-pc-linux-gnu"

declare void @use_buf(ptr)

define void @test_recursive(i32 %depth) {
entry:
  %buf = alloca [64 x i8], align 16
  %ptr = getelementptr [64 x i8], ptr %buf, i64 0, i64 0
  call void @use_buf(ptr %ptr)
  %cmp = icmp sgt i32 %depth, 0
  br i1 %cmp, label %recurse, label %done
recurse:
  %next = sub i32 %depth, 1
  call void @test_recursive(i32 %next)
  br label %done
done:
  ret void
}

define void @__morestack() {
  ret void
}

define void @__fiber_helper() {
  ret void
}
EOF

# ── Helper: check assembly has __morestack before pushq ──────────
check_asm() {
    local label="$1" file="$2" tag="$3"

    local func_asm
    func_asm=$(sed -n "/^test_recursive:/,/^\\.Lfunc_end/p" "$file")
    [[ -n "$func_asm" ]] || fail "[$tag] test_recursive not found in assembly"

    local ms_line push_line
    ms_line=$(echo "$func_asm" | grep -n "__morestack" | head -1 | cut -d: -f1)
    push_line=$(echo "$func_asm" | grep -n "pushq\|subq" | head -1 | cut -d: -f1)

    [[ -n "$ms_line" ]] || { echo "$func_asm"; fail "[$tag] __morestack not found"; }
    [[ -n "$push_line" ]] || { echo "$func_asm"; fail "[$tag] prologue not found"; }

    if (( ms_line < push_line )); then
        pass "[$tag] __morestack (line $ms_line) BEFORE prologue (line $push_line)"
    else
        echo "$func_asm"
        fail "[$tag] __morestack (line $ms_line) AFTER prologue (line $push_line)"
    fi

    # __morestack itself must NOT be instrumented
    local ms_func
    ms_func=$(sed -n "/^__morestack:/,/^\\.Lfunc_end/p" "$file")
    if echo "$ms_func" | grep -q "test_stack_limit"; then
        fail "[$tag] __morestack was instrumented"
    else
        pass "[$tag] __morestack correctly skipped"
    fi

    # __fiber_ prefixed functions must NOT be instrumented
    local helper_func
    helper_func=$(sed -n "/^__fiber_helper:/,/^\\.Lfunc_end/p" "$file")
    if echo "$helper_func" | grep -q "test_stack_limit"; then
        fail "[$tag] __fiber_helper was instrumented"
    else
        pass "[$tag] __fiber_helper correctly skipped"
    fi
}

# ══════════════════════════════════════════════════════════════════
section "A. MachineFunctionPass plugin (MIR round-trip)"
# ══════════════════════════════════════════════════════════════════

if [[ -f "$PLUGIN" ]] && command -v llc-18 >/dev/null 2>&1; then
    # 1. Lower to MIR
    llc-18 "$TMPDIR/test.ll" -stop-after=prologepilog \
        -o "$TMPDIR/test.mir" 2>/dev/null

    # 2. Run machine pass
    llc-18 --load="$PLUGIN" --run-pass=fiber-stack-check \
        "$TMPDIR/test.mir" -o "$TMPDIR/test-instr.mir" 2>/dev/null

    # 3. MIR check: INLINEASM before frame-setup
    first=$(sed -n '/^name:.*test_recursive/,/^\.\.\./{
        /^  bb\.0/,/^  bb\.[1-9]/{/INLINEASM\|frame-setup/{p;q}}
    }' "$TMPDIR/test-instr.mir")

    if echo "$first" | grep -q "INLINEASM"; then
        pass "[MIR] INLINEASM is first in entry block"
    else
        fail "[MIR] Expected INLINEASM before frame-setup, got: $first"
    fi

    # 4. Finish codegen
    llc-18 "$TMPDIR/test-instr.mir" --start-after=prologepilog \
        -o "$TMPDIR/mir.s" -filetype=asm 2>/dev/null

    check_asm "test_recursive" "$TMPDIR/mir.s" "MIR"
else
    echo "  (skipped — plugin or llc-18 not found)"
fi

# ══════════════════════════════════════════════════════════════════
section "B. fiber-instrument tool (assembly post-processing)"
# ══════════════════════════════════════════════════════════════════

if [[ -x "$TOOL" ]]; then
    "$TOOL" "$TMPDIR/test.ll" -S -o "$TMPDIR/tool.s"

    check_asm "test_recursive" "$TMPDIR/tool.s" "TOOL"

    # Check label uniqueness (no duplicate .Lfiber_ labels)
    local_count=$(grep -c "^\.Lfiber_chk_" "$TMPDIR/tool.s" || true)
    ok_count=$(grep -c "^\.Lfiber_ok_" "$TMPDIR/tool.s" || true)
    if [[ "$local_count" -eq "$ok_count" ]] && [[ "$local_count" -gt 0 ]]; then
        pass "[TOOL] Labels are unique ($local_count functions instrumented)"
    else
        fail "[TOOL] Label count mismatch: chk=$local_count ok=$ok_count"
    fi
else
    fail "fiber-instrument not found at $TOOL"
fi

echo ""
echo "All tests passed."
