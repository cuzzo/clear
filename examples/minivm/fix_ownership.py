#!/usr/bin/env python3
"""Apply all ownership fixes to interpreter.cht systematically.

Rules:
- Function params are implicit borrows (can read, cannot store)
- TAKES params are owned (can store, move, return)
- MATCH consumes owned values (CLEAR lacks MATCH-borrow; workaround: COPY before MATCH)
- Storing into HashMap/union variant requires owned value
- COPY makes explicit deep copy
- GIVE transfers ownership at call site
- Copy types (Int64, Float64, String, Bool, Id<Env>) are freely copyable
"""

import re

with open("examples/minivm/interpreter.cht", "r") as f:
    content = f.read()

# ============================================================
# A: Function signatures - add TAKES where params are consumed
# ============================================================

sigs = {
    "FN eval!(astIn: Value, envId:": "FN eval!(TAKES astIn: Value, envId:",
    "FN evalList!(items: Value[], envId:": "FN evalList!(TAKES items: Value[], envId:",
    "FN handleCatch!(catchExpr: Value, errMsg:": "FN handleCatch!(TAKES catchExpr: Value, errMsg:",
    "FN envSet!(envId: Id<Env>, name: String, val: Value, MUTABLE pool:":
        "FN envSet!(envId: Id<Env>, name: String, TAKES val: Value, MUTABLE pool:",
    "FN compile!(ast: Value, envId:": "FN compile!(TAKES ast: Value, envId:",
    "FN exec!(ops: Int64[], consts: Value[], envId:": "FN exec!(ops: Int64[], TAKES consts: Value[], envId:",
    "FN listRef(v: Value, idx:": "FN listRef(TAKES v: Value, idx:",
    "FN vecRef(v: Value, idx:": "FN vecRef(TAKES v: Value, idx:",
    "FN pairCar(v: Value)": "FN pairCar(TAKES v: Value)",
    "FN pairCdr(v: Value)": "FN pairCdr(TAKES v: Value)",
    "FN debugPause!(reason: String, envId:": "FN debugPause!(TAKES reason: String, envId:",
    "FN evalLambdaCall!(f: Value, evaled: Value[],":
        "FN evalLambdaCall!(TAKES f: Value, TAKES evaled: Value[],",
}
for old, new in sigs.items():
    content = content.replace(old, new)

# applyNative does NOT need TAKES - it only reads elements via borrow

# ============================================================
# B: COPY on HashMap lookups that are returned/stored
# ============================================================

content = content.replace(
    "val = pool[envId]?.vars[name] OR Value{ Number: 0.0 - 777777.0 };",
    "val = COPY (pool[envId]?.vars[name] OR Value{ Number: 0.0 - 777777.0 });",
)

# exec! storeName - stack element into HashMap
content = content.replace(
    'pool[curEnv]?.vars[getSymName(consts[idx])] = stack[sp - 1];',
    'pool[curEnv]?.vars[getSymName(consts[idx])] = COPY stack[sp - 1];',
)

# ============================================================
# C: COPY on union variant construction from borrowed sources
# ============================================================

# Pair cons from borrowed evaled elements
content = content.replace(
    "RETURN Value.Pair{ pairCar: evaled[1], pairCdr: evaled[2] };",
    "RETURN Value.Pair{ pairCar: COPY evaled[1], pairCdr: COPY evaled[2] };",
)

# Lambda params/body from borrowed items elements
content = content.replace(
    "RETURN Value.Lambda{ params: pnames, body: items[2], envId: envId };",
    "RETURN Value.Lambda{ params: COPY pnames, body: COPY items[2], envId: envId };",
)

# Tco from borrowed items elements - add COPY
content = re.sub(
    r'Value\.Tco\{ tcoAst: (items\[\d+\]),',
    r'Value.Tco{ tcoAst: COPY \1,',
    content,
)
content = re.sub(
    r'Value\.Tco\{ tcoAst: (items\[items\.length\(\) - 1\]),',
    r'Value.Tco{ tcoAst: COPY \1,',
    content,
)
content = re.sub(
    r'Value\.Tco\{ tcoAst: (lam\.body),',
    r'Value.Tco{ tcoAst: COPY \1,',
    content,
)
content = re.sub(
    r'Value\.Tco\{ tcoAst: (catchItems\[\d+\]),',
    r'Value.Tco{ tcoAst: COPY \1,',
    content,
)

# Error fields - COPY variable references (String is Copy but compiler requires it for union fields)
def fix_error_fields(m):
    full = m.group(0)
    full = re.sub(r'errMsg: ([a-zA-Z_]\w*)', r'errMsg: COPY \1', full)
    full = re.sub(r'errKind: ([a-zA-Z_]\w*)', r'errKind: COPY \1', full)
    full = full.replace('COPY "', '"')  # don't COPY string literals
    full = full.replace('COPY COPY ', 'COPY ')
    return full

content = re.sub(r'Value\.Error\{[^}]+\}', fix_error_fields, content)

# ============================================================
# D: COPY items[N] when passing to eval! (which TAKES)
# ============================================================

content = re.sub(r'eval!\(items\[(\d+)\],', r'eval!(GIVE COPY items[\1],', content)
content = re.sub(
    r'eval!\(items\[items\.length\(\) - 1\],',
    r'eval!(GIVE COPY items[items.length() - 1],',
    content,
)
content = re.sub(r'eval!\(pair\[1\],', r'eval!(GIVE COPY pair[1],', content)
content = re.sub(r'eval!\(binds\[bi \+ 1\],', r'eval!(GIVE COPY binds[bi + 1],', content)

# runTest! GIVE ast
content = content.replace(
    "RETURN eval!(ast, envId, pool);",
    "RETURN eval!(GIVE ast, envId, pool);",
)

# ============================================================
# E: eval! - COPY before TCO MATCH (wasteful, remove when MATCH borrows by default)
# ============================================================

old_tco_match = '''                result = evalList!(listItems, curEnv, pool);
                MATCH result START
                    Value.Tco AS tco ->
                        ast = tco.tcoAst;
                        curEnv = tco.tcoEnv;,
                    DEFAULT -> RETURN result;
                END,'''

new_tco_match = '''                -- TODO: remove COPY when MATCH borrows by default (MATCH TAKES for explicit consume)
                MUTABLE tcoResult: Value = evalList!(listItems, curEnv, pool);
                MUTABLE tcoResultCopy: Value = COPY tcoResult;
                MATCH tcoResult START
                    Value.Tco AS tco ->
                        ast = COPY tco.tcoAst;
                        curEnv = tco.tcoEnv;,
                    DEFAULT -> RETURN tcoResultCopy;
                END,'''

content = content.replace(old_tco_match, new_tco_match)

# eval! DEFAULT -> reconstruct values instead of returning consumed ast
content = content.replace(
    "            DEFAULT -> RETURN ast;\n        END",
    """            Value.Nil -> RETURN Value.Nil;,
            Value.TrueVal -> RETURN Value.TrueVal;,
            Value.FalseVal -> RETURN Value.FalseVal;,
            Value.Number AS n -> RETURN Value{ Number: n };,
            Value.Int64Val AS i -> RETURN Value{ Int64Val: i };,
            Value.Str AS s -> RETURN Value{ Str: s };,
            DEFAULT -> RETURN Value.Nil;
        END""",
)

# MUTABLE curEnv needs COPY envId (Id<Env> is Copy but compiler may require explicit)
content = content.replace(
    "MUTABLE curEnv: Id<Env> = envId;",
    "MUTABLE curEnv: Id<Env> = COPY envId;",
)

# ============================================================
# F: def! - store eval result directly, return Nil
# ============================================================

old_def = '''        defName = getSymName(items[1]);
        val = eval!(items[2], envId, pool);
        IF isError?(val) THEN RETURN val; END
        pool[envId]?.vars[defName] = val;
        result = pool[envId]?.vars[defName] OR Value.Nil;
        RETURN result;'''

new_def = '''        defName = getSymName(items[1]);
        pool[envId]?.vars[defName] = eval!(GIVE COPY items[2], envId, pool);
        RETURN Value.Nil;'''

content = content.replace(old_def, new_def)

# ============================================================
# G: let bindings - store eval result directly
# ============================================================

content = content.replace(
    "bVal = eval!(GIVE COPY binds[bi + 1], letId, pool);\n"
    "                        IF isError?(bVal) THEN RETURN bVal; END\n"
    "                        pool[letId]?.vars[bName] = bVal;",
    "pool[letId]?.vars[bName] = eval!(GIVE COPY binds[bi + 1], letId, pool);",
)

# ============================================================
# H: evaled.remove(0) + COPY lambda args
# ============================================================

content = content.replace("f = evaled[0];", "f = evaled.remove(0_i64);")

content = content.replace(
    "pool[callId]?.vars[pname] = evaled[pi + 1];",
    "pool[callId]?.vars[pname] = COPY evaled[pi];",
)

# ============================================================
# I: envSet! restructure for two-branch val usage
# ============================================================

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
# J: applyNative - COPY elements into containers (not TAKES, just borrow + COPY)
# ============================================================

content = re.sub(r'litems\.append\(evaled\[li\]\)', 'litems.append(COPY evaled[li])', content)
content = re.sub(r'velems\.append\(evaled\[vi\]\)', 'velems.append(COPY evaled[vi])', content)
content = re.sub(r'newItems\.append\(evaled\[2\]\)', 'newItems.append(COPY evaled[2])', content)
content = re.sub(r'singleItem\.append\(evaled\[2\]\)', 'singleItem.append(COPY evaled[2])', content)
content = re.sub(r'newItems\.append\(srcItems\[li\]\)', 'newItems.append(COPY srcItems[li])', content)

# assoc-set: COPY key/val in loop (reused across iterations)
content = re.sub(
    r'newPairs\.append\(Value\.Pair\{ pairCar: key, pairCdr: val \}\)',
    'newPairs.append(Value.Pair{ pairCar: COPY key, pairCdr: COPY val })',
    content,
)

# ============================================================
# K: Pipeline ops - COPY elements in loops
# ============================================================

content = content.replace("tmp = sorted[j - 1];", "tmp = COPY sorted[j - 1];")
content = content.replace("sorted[j - 1] = sorted[j];", "sorted[j - 1] = COPY sorted[j];")
content = re.sub(r'flat\.append\(innerItems\[ni\]\)', 'flat.append(COPY innerItems[ni])', content)

# All pipeline callArgs/kArgs/etc append patterns
content = re.sub(
    r'(callArgs|kArgs|pArgs|fArgs|eArgs|tArgs|aArgs|bArgs)\.append\((?!COPY|Value)(\w+)\)',
    r'\1.append(COPY \2)',
    content,
)
content = re.sub(
    r'(callArgs|kArgs|pArgs|fArgs|eArgs|tArgs|aArgs|bArgs)\.append\((?!COPY)(sorted\[)',
    r'\1.append(COPY \2',
    content,
)

# ============================================================
# L: Cleanup
# ============================================================

for _ in range(5):
    content = content.replace("COPY COPY ", "COPY ")
    content = content.replace("GIVE GIVE ", "GIVE ")
    content = content.replace("GIVE COPY GIVE COPY ", "GIVE COPY ")

with open("examples/minivm/interpreter.cht", "w") as f:
    f.write(content)

print(f"Applied all ownership fixes ({content.count(chr(10))} lines)")
