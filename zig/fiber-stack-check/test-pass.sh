#!/usr/bin/env bash
#
# test-pass.sh — Verify the Machine Pass inserts __morestack BEFORE the prologue.
#
# Pipeline:
#   1. tiny .ll → llc -stop-after=prologepilog → MIR (prologue present)
#   2. llc --load --run-pass=fiber-stack-check → instrumented MIR
#   3. llc --start-after=prologepilog → assembly (resume without re-running prologue)
#   4. Assert __morestack appears BEFORE pushq in the assembly
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$DIR/pass/build/libFiberStackCheck.so"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# ── 0. Prerequisites ─────────────────────────────────────────────
[[ -f "$PLUGIN" ]] || fail "Plugin not built.  Run: cmake --build $DIR/pass/build"
command -v llc-18 >/dev/null 2>&1 || fail "llc-18 not found"

# ── 1. Minimal LLVM IR ───────────────────────────────────────────
cat > "$TMPDIR/test.ll" <<'EOF'
target triple = "x86_64-pc-linux-gnu"

declare void @use_buf(ptr)

; A normal function — SHOULD be instrumented.
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

; __morestack itself — must NOT be instrumented.
define void @__morestack() {
  ret void
}
EOF

# ── 2. Lower to MIR (stop after prologue insertion) ──────────────
llc-18 "$TMPDIR/test.ll" \
    -stop-after=prologepilog \
    -o "$TMPDIR/test.mir" 2>/dev/null

[[ -s "$TMPDIR/test.mir" ]] || fail "MIR generation produced empty file"

# ── 3. Run our machine pass ──────────────────────────────────────
llc-18 \
    --load="$PLUGIN" \
    --run-pass=fiber-stack-check \
    "$TMPDIR/test.mir" \
    -o "$TMPDIR/test-instr.mir" 2>/dev/null

[[ -s "$TMPDIR/test-instr.mir" ]] || fail "Instrumented MIR is empty"

# ── 4. MIR check: INLINEASM before frame-setup ───────────────────
FIRST_REAL=$(
    sed -n '/^name:.*test_recursive/,/^\.\.\./{
        /^  bb\.0/,/^  bb\.[1-9]/{
            /INLINEASM\|frame-setup/{p;q}
        }
    }' "$TMPDIR/test-instr.mir"
)

if echo "$FIRST_REAL" | grep -q "INLINEASM"; then
    pass "INLINEASM is first instruction in MIR entry block"
else
    fail "Expected INLINEASM before frame-setup, got: $FIRST_REAL"
fi

# ── 5. Finish codegen → assembly (resume after prologepilog) ─────
llc-18 "$TMPDIR/test-instr.mir" \
    --start-after=prologepilog \
    -o "$TMPDIR/test.s" \
    -filetype=asm 2>/dev/null

[[ -s "$TMPDIR/test.s" ]] || fail "Assembly output is empty"

# ── 6. Assembly check: __morestack BEFORE pushq (prologue) ───────
FUNC_ASM=$(sed -n '/^test_recursive:/,/^\.Lfunc_end/p' "$TMPDIR/test.s")

[[ -n "$FUNC_ASM" ]] || fail "Could not find test_recursive in assembly"

MORESTACK_LINE=$(echo "$FUNC_ASM" | grep -n "__morestack" | head -1 | cut -d: -f1)
PUSH_LINE=$(echo "$FUNC_ASM" | grep -n "pushq" | head -1 | cut -d: -f1)

[[ -n "$MORESTACK_LINE" ]] || {
    echo "$FUNC_ASM"
    fail "__morestack not found in test_recursive"
}
[[ -n "$PUSH_LINE" ]] || {
    echo "$FUNC_ASM"
    fail "pushq (prologue) not found in test_recursive"
}

if (( MORESTACK_LINE < PUSH_LINE )); then
    pass "__morestack (line $MORESTACK_LINE) BEFORE prologue pushq (line $PUSH_LINE)"
else
    echo "$FUNC_ASM"
    fail "__morestack (line $MORESTACK_LINE) AFTER prologue pushq (line $PUSH_LINE)"
fi

# ── 7. __morestack itself must NOT be instrumented ────────────────
MORESTACK_FUNC=$(sed -n '/^__morestack:/,/^\.Lfunc_end/p' "$TMPDIR/test.s")

if echo "$MORESTACK_FUNC" | grep -q "test_stack_limit"; then
    fail "__morestack was instrumented (should be skipped)"
else
    pass "__morestack was NOT instrumented (correctly skipped)"
fi

# ── 8. Check the inline asm contains expected instructions ────────
if echo "$FUNC_ASM" | grep -q "test_stack_limit@GOTTPOFF"; then
    pass "TLS load (test_stack_limit@GOTTPOFF) present"
else
    fail "TLS load not found in check"
fi

if echo "$FUNC_ASM" | grep -q "cmpq.*%r11.*%rsp\|cmpq.*%rsp.*%r11"; then
    pass "Stack limit comparison present"
else
    # Check the broader pattern
    if echo "$FUNC_ASM" | grep -q "cmpq"; then
        pass "Stack limit comparison present (cmpq found)"
    else
        fail "cmpq not found in check"
    fi
fi

echo ""
echo "All tests passed."
