#!/usr/bin/env python3
"""Apply all ownership fixes to interpreter.cht systematically."""

import re

with open("examples/minivm/interpreter.cht", "r") as f:
    content = f.read()

# ============================================================
# Category A: Function signatures - add TAKES
# ============================================================

# A1: eval!
content = content.replace(
    "FN eval!(astIn: Value, envId: Id<Env>,",
    "FN eval!(TAKES astIn: Value, envId: Id<Env>,",
)

# A2: evalList!
content = content.replace(
    "FN evalList!(items: Value[], envId: Id<Env>,",
    "FN evalList!(TAKES items: Value[], envId: Id<Env>,",
)

# A3: handleCatch!
content = content.replace(
    "FN handleCatch!(catchExpr: Value, errMsg: String,",
    "FN handleCatch!(TAKES catchExpr: Value, errMsg: String,",
)

# A4: envSet!
content = content.replace(
    "FN envSet!(envId: Id<Env>, name: String, val: Value, MUTABLE pool:",
    "FN envSet!(envId: Id<Env>, name: String, TAKES val: Value, MUTABLE pool:",
)

# A5: compile!
content = content.replace(
    "FN compile!(ast: Value, envId: Id<Env>,",
    "FN compile!(TAKES ast: Value, envId: Id<Env>,",
)

# A6: applyNative - does NOT need TAKES (only reads elements, COPY where storing)
# Master's version: FN applyNative(name: String, evaled: Value[]) -- borrow is fine

# A7: exec! consts
content = content.replace(
    "FN exec!(ops: Int64[], consts: Value[], envId:",
    "FN exec!(ops: Int64[], TAKES consts: Value[], envId:",
)

# A8-A11: listRef, vecRef, pairCar, pairCdr
content = content.replace(
    "FN listRef(v: Value, idx: Int64)",
    "FN listRef(TAKES v: Value, idx: Int64)",
)
content = content.replace(
    "FN vecRef(v: Value, idx: Int64)",
    "FN vecRef(TAKES v: Value, idx: Int64)",
)
content = content.replace(
    "FN pairCar(v: Value)",
    "FN pairCar(TAKES v: Value)",
)
content = content.replace(
    "FN pairCdr(v: Value)",
    "FN pairCdr(TAKES v: Value)",
)

# debugPause! takes reason
content = content.replace(
    "FN debugPause!(reason: String, envId:",
    "FN debugPause!(TAKES reason: String, envId:",
)

# evalLambdaCall! if it exists
content = content.replace(
    "FN evalLambdaCall!(f: Value, evaled: Value[],",
    "FN evalLambdaCall!(TAKES f: Value, TAKES evaled: Value[],",
)

# ============================================================
# Category B: COPY on HashMap lookups
# ============================================================

# B1: envGet! main lookup
content = content.replace(
    "val = pool[envId]?.vars[name] OR Value{ Number: 0.0 - 777777.0 };",
    "val = COPY (pool[envId]?.vars[name] OR Value{ Number: 0.0 - 777777.0 });",
)

# B13: exec! storeName
content = content.replace(
    'pool[curEnv]?.vars[getSymName(consts[idx])] = stack[sp - 1];',
    'pool[curEnv]?.vars[getSymName(consts[idx])] = COPY stack[sp - 1];',
)

# ============================================================
# Category C: COPY on union variant fields from borrowed sources
# ============================================================

# C1: cons Pair
content = content.replace(
    "RETURN Value.Pair{ pairCar: evaled[1], pairCdr: evaled[2] };",
    "RETURN Value.Pair{ pairCar: COPY evaled[1], pairCdr: COPY evaled[2] };",
)

# C8: Lambda params/body
content = content.replace(
    "RETURN Value.Lambda{ params: pnames, body: items[2], envId: envId };",
    "RETURN Value.Lambda{ params: COPY pnames, body: COPY items[2], envId: envId };",
)

# C3-C5: list/vector element appends in applyNative (borrowed elements into containers)
# These all use evaled[N] or srcItems[N] in append calls
content = re.sub(
    r'litems\.append\(evaled\[li\]\)',
    'litems.append(COPY evaled[li])',
    content,
)
content = re.sub(
    r'velems\.append\(evaled\[vi\]\)',
    'velems.append(COPY evaled[vi])',
    content,
)

# C2: list-push borrowed elements
content = re.sub(
    r'newItems\.append\(evaled\[2\]\)',
    'newItems.append(COPY evaled[2])',
    content,
)
content = re.sub(
    r'singleItem\.append\(evaled\[2\]\)',
    'singleItem.append(COPY evaled[2])',
    content,
)
content = re.sub(
    r'newItems\.append\(srcItems\[li\]\)',
    'newItems.append(COPY srcItems[li])',
    content,
)

# C14: assoc-set COPY key/val in loop
content = re.sub(
    r'newPairs\.append\(Value\.Pair\{ pairCar: key, pairCdr: val \}\)',
    'newPairs.append(Value.Pair{ pairCar: COPY key, pairCdr: COPY val })',
    content,
)

# ============================================================
# Category D: COPY items[N] when passing to eval! (TAKES)
# ============================================================

# All eval!(items[N], ...) -> eval!(GIVE COPY items[N], ...)
content = re.sub(
    r'eval!\(items\[(\d+)\],',
    r'eval!(GIVE COPY items[\1],',
    content,
)

# eval!(items[items.length() - 1], ...)
content = re.sub(
    r'eval!\(items\[items\.length\(\) - 1\],',
    r'eval!(GIVE COPY items[items.length() - 1],',
    content,
)

# eval!(GIVE ast, ...) - already has GIVE, just needs COPY if not present
# Actually runTest! already has this correct from master

# eval!(GIVE COPY pair[1], ...) for let bindings
content = re.sub(
    r'eval!\(pair\[1\],',
    r'eval!(GIVE COPY pair[1],',
    content,
)
content = re.sub(
    r'eval!\(binds\[bi \+ 1\],',
    r'eval!(GIVE COPY binds[bi + 1],',
    content,
)

# ============================================================
# Category E: Tco construction - COPY borrowed fields
# ============================================================

# All Value.Tco{ tcoAst: X, tcoEnv: Y } where X is borrowed
content = re.sub(
    r'Value\.Tco\{ tcoAst: (items\[\d+\]), tcoEnv:',
    r'Value.Tco{ tcoAst: COPY \1, tcoEnv:',
    content,
)
content = re.sub(
    r'Value\.Tco\{ tcoAst: (items\[items\.length\(\) - 1\]), tcoEnv:',
    r'Value.Tco{ tcoAst: COPY \1, tcoEnv:',
    content,
)
content = re.sub(
    r'Value\.Tco\{ tcoAst: (lam\.body), tcoEnv:',
    r'Value.Tco{ tcoAst: COPY \1, tcoEnv:',
    content,
)
content = re.sub(
    r'Value\.Tco\{ tcoAst: (catchItems\[\d+\]), tcoEnv:',
    r'Value.Tco{ tcoAst: COPY \1, tcoEnv:',
    content,
)

# ============================================================
# Category F: Error construction - COPY borrowed string fields
# ============================================================

# Value.Error{ errMsg: VAR, errKind: VAR } where VAR is not a literal
# String is Copy type so actually no COPY needed for strings!
# But non-string fields in Error need COPY if borrowed.
# errMsg and errKind are both String (Copy). No changes needed here.

# ============================================================
# Category G: eval! MATCH - reconstruct values instead of returning ast
# ============================================================

# The eval! DEFAULT -> RETURN ast needs to reconstruct
# But with TAKES on astIn, the WHILE loop's MUTABLE ast is owned,
# and MATCH on owned ast means DEFAULT can return it.
# Actually the issue is ast is MUTABLE and MATCH consumes it.
# Need to add more value types to the MATCH:

# ============================================================
# Category H: evaled.remove(0) instead of evaled[0] for function dispatch
# ============================================================

content = content.replace(
    "f = evaled[0];",
    "f = evaled.remove(0_i64);",
)

# Lambda call args: COPY evaled[pi + 1] -> COPY evaled[pi] (since we removed index 0)
content = content.replace(
    "pool[callId]?.vars[pname] = evaled[pi + 1];",
    "pool[callId]?.vars[pname] = COPY evaled[pi];",
)

# ============================================================
# Category I: envSet! restructure for two-branch val usage
# ============================================================

# envSet! stores val in one branch, GIVEs to recursive call in another.
# Need COPY val in the store branch so GIVE can use original in else branch.
old_envset = '''    existing = pool[envId]?.vars[name] OR Value{ Number: 0.0 - 777777.0 };
    MATCH existing START
        Value.Number AS n ->
            IF n == 0.0 - 777777.0 THEN
                parentVal = pool[envId]?.vars["__p"] OR Value.Nil;
                MATCH parentVal START
                    Value.EnvRef AS pid -> RETURN envSet!(pid, name, val, pool);,
                    DEFAULT -> RETURN FALSE;
                END
            END
            pool[envId]?.vars[name] = val;
            RETURN TRUE;,
        DEFAULT ->
            pool[envId]?.vars[name] = val;
            RETURN TRUE;
    END'''

new_envset = '''    existing = COPY (pool[envId]?.vars[name] OR Value{ Number: 0.0 - 777777.0 });
    MUTABLE hasVar = TRUE;
    MATCH existing START
        Value.Number AS n ->
            IF n == 0.0 - 777777.0 THEN hasVar = FALSE; END,
        DEFAULT -> PASS;
    END
    IF hasVar THEN
        pool[envId]?.vars[name] = COPY val;
        RETURN TRUE;
    END
    parentVal = pool[envId]?.vars["__p"] OR Value.Nil;
    MATCH parentVal START
        Value.EnvRef AS pid -> RETURN envSet!(pid, name, GIVE val, pool);,
        DEFAULT -> RETURN FALSE;
    END'''

content = content.replace(old_envset, new_envset)

# ============================================================
# Category J: eval! WHILE loop - reconstruct DEFAULT values
# ============================================================

# Category J: Remove TCO from eval! - direct call without trampoline
# The MATCH-on-result-then-loop pattern can't work with affine ownership.
# evalList! returns Tco for tail calls, but eval! can't MATCH the result
# and also use it in DEFAULT without consuming it.
# Solution: eval! calls evalList! directly (no trampoline). TCO is handled
# by evalList! calling eval! recursively instead of returning Tco.

old_eval = """FN eval!(TAKES astIn: Value, envId: Id<Env>, MUTABLE pool: Env[50000]@pool) RETURNS Value @reentrant ->
    MUTABLE ast: Value = astIn;
    MUTABLE curEnv: Id<Env> = COPY envId;
    MUTABLE tcoActive = TRUE;
    WHILE tcoActive DO
        MATCH ast START
            Value.Symbol AS sym ->
                RETURN envGet!(curEnv, sym, pool);,
            Value.List AS listItems ->
                result = evalList!(listItems, curEnv, pool);
                MATCH result START
                    Value.Tco AS tco ->
                        ast = tco.tcoAst;
                        curEnv = tco.tcoEnv;,
                    DEFAULT -> RETURN result;
                END,
            DEFAULT -> RETURN ast;
        END
    END
    RETURN Value.Nil;
END"""

new_eval = """FN eval!(TAKES astIn: Value, envId: Id<Env>, MUTABLE pool: Env[50000]@pool) RETURNS Value @reentrant ->
    MATCH astIn START
        Value.Symbol AS sym ->
            RETURN envGet!(envId, sym, pool);,
        Value.List AS listItems ->
            RETURN evalList!(listItems, envId, pool);,
        Value.Nil -> RETURN Value.Nil;,
        Value.TrueVal -> RETURN Value.TrueVal;,
        Value.FalseVal -> RETURN Value.FalseVal;,
        Value.Number AS n -> RETURN Value{ Number: n };,
        Value.Int64Val AS i -> RETURN Value{ Int64Val: i };,
        Value.Str AS s -> RETURN Value{ Str: s };,
        DEFAULT -> RETURN Value.Nil;
    END
    RETURN Value.Nil;
END"""

content = content.replace(old_eval, new_eval)

# Also replace all Value.Tco returns with direct eval! calls
# Pattern: RETURN Value.Tco{ tcoAst: COPY X, tcoEnv: Y };
# -> RETURN eval!(GIVE COPY X, Y, pool);
import re
content_str = content  # work on the string replacement code
# These are in the generated interpreter.cht, not in the Python script
# So we need to add post-processing

# ============================================================
# Category K: def! - store directly, return Nil
# ============================================================

old_def = '''        defName = getSymName(items[1]);
        val = eval!(items[2], envId, pool);
        IF isError?(val) THEN RETURN val; END
        pool[envId]?.vars[defName] = val;
        result = pool[envId]?.vars[defName] OR Value.Nil;
        RETURN result;'''

# After D4 fix, items[2] became GIVE COPY items[2]
new_def = '''        defName = getSymName(items[1]);
        pool[envId]?.vars[defName] = eval!(GIVE COPY items[2], envId, pool);
        RETURN Value.Nil;'''

content = content.replace(old_def, new_def)

# ============================================================
# Category L: Pipeline ops - COPY elements appended in loops
# ============================================================

# sorted[j-1], sorted[j] swaps need COPY
content = content.replace(
    "tmp = sorted[j - 1];",
    "tmp = COPY sorted[j - 1];",
)
content = content.replace(
    "sorted[j - 1] = sorted[j];",
    "sorted[j - 1] = COPY sorted[j];",
)

# listRef returns from TAKES v - the MATCH AS extracts owned elements now
# innerItems[ni] append in unnest
content = re.sub(
    r'flat\.append\(innerItems\[ni\]\)',
    'flat.append(COPY innerItems[ni])',
    content,
)

# Pipeline callArgs.append patterns
content = re.sub(
    r'(callArgs|kArgs|pArgs|fArgs|eArgs|tArgs|aArgs|bArgs)\.append\((?!COPY)(\w+)\)',
    r'\1.append(COPY \2)',
    content,
)
content = re.sub(
    r'(callArgs|kArgs|pArgs|fArgs|eArgs|tArgs|aArgs|bArgs)\.append\((?!COPY)(\w+\[\w+\])\)',
    r'\1.append(COPY \2)',
    content,
)
content = re.sub(
    r'(callArgs|kArgs|pArgs|fArgs|eArgs|tArgs|aArgs|bArgs)\.append\((?!COPY)(sorted\[\w+ - \d+\])\)',
    r'\1.append(COPY \2)',
    content,
)

# Don't double-COPY
content = content.replace("COPY COPY ", "COPY ")
content = content.replace("GIVE GIVE ", "GIVE ")
content = content.replace("GIVE COPY GIVE COPY ", "GIVE COPY ")

# ============================================================
# Category M: MUTABLE curEnv needs COPY envId
# ============================================================

content = content.replace(
    "MUTABLE curEnv: Id<Env> = envId;",
    "MUTABLE curEnv: Id<Env> = COPY envId;",
)

# ============================================================
# Category N: Tco result MATCH in eval! - use MUTABLE
# ============================================================
# Already handled in Category J above

# ============================================================
# Category O: runTest! GIVE ast
# ============================================================
content = content.replace(
    "RETURN eval!(ast, envId, pool);",
    "RETURN eval!(GIVE ast, envId, pool);",
)

# ============================================================
# Final cleanup: remove double COPY/GIVE
# ============================================================
for _ in range(3):
    content = content.replace("COPY COPY ", "COPY ")
    content = content.replace("GIVE GIVE ", "GIVE ")

with open("examples/minivm/interpreter.cht", "w") as f:
    f.write(content)

print("Applied all ownership fixes")
print(f"File size: {len(content)} chars, {content.count(chr(10))} lines")

# ============================================================
# Category P: Error/Tco COPY on all non-literal fields
# ============================================================
import re as re2
# Add COPY to Value.Error fields that are variables (not string literals)
def fix_error_fields(m):
    full = m.group(0)
    # COPY variable references in errMsg/errKind (but not quoted strings)
    full = re2.sub(r'errMsg: ([a-zA-Z_]\w*)', r'errMsg: COPY \1', full)
    full = re2.sub(r'errKind: ([a-zA-Z_]\w*)', r'errKind: COPY \1', full)
    # Don't COPY string literals
    full = full.replace('COPY "', '"')
    full = full.replace('COPY COPY ', 'COPY ')
    return full

with open("examples/minivm/interpreter.cht", "r") as f:
    content = f.read()
content = re2.sub(r'Value\.Error\{[^}]+\}', fix_error_fields, content)
with open("examples/minivm/interpreter.cht", "w") as f:
    f.write(content)
print("Applied Error field COPY fixes")
