# Register VM Design

## Current Architecture (Stack VM)

The stack VM uses three stacks (Value, i64, f64) and slot arrays for locals.
The bytecode compiler tracks stack state via `@type_stack` and emits
push/pop sequences for every operation.

```
LOAD_ISLOT 0     -- push islots[0] to istack
LOAD_ISLOT 1     -- push islots[1] to istack
ADD_I64          -- pop 2, push sum
STORE_ISLOT 2   -- pop to islots[2]
```

4 dispatch cycles for `c = a + b`.

## Register VM Target

Every instruction names its operands directly. No stack manipulation.

```
IADD r2 r0 r1    -- iregs[2] = iregs[0] + iregs[1]
```

1 dispatch cycle for `c = a + b`.

## Compilation Pipeline

```
Source AST
    |
    v
Pass 1: bytecode_compiler.rb  (tree-walk -> virtual reg IR)
    |
    v
Pass 2: bytecode_optimizer.rb (fold, DCE, peephole)
    |
    v
Pass 3: register_allocator.rb (virtual -> physical regs)
    |
    v
Pass 4: serialize (emit Int64[] ops + Value[] consts)
    |
    v
exec!() register dispatch loop
```

All passes are Ruby. The VM (interpreter.cht) only sees physical register opcodes.

## Pass 1: Virtual Register Emission

The tree-walk compiler assigns a fresh virtual register to every expression result.
No allocation decisions, no stack state tracking.

```
v0 = ICONST 10
v1 = ICONST 20
v2 = IADD v0 v1          -- v2 = 30
v3 = ICONST 2
v4 = IMUL v2 v3          -- v4 = 60
```

The compiler becomes simpler than today - no `@type_stack`, no `ensure_value_stack`,
no `STORE_SLOT_I64` vs `STORE_ISLOT` decisions. Each value is a virtual register
with a type annotation (:i64, :f64, :str, :any).

### IR Node Format

```ruby
{ op: :IADD, dst: :v2, src1: :v0, src2: :v1, type: :i64 }
{ op: :ICONST, dst: :v0, imm: 10, type: :i64 }
{ op: :ILT, dst: :v5, src1: :v3, src2: :v4, type: :bool }
{ op: :JF, cond: :v5, target: :label_exit }
{ op: :CALL_NATIVE, dst: :v8, nid: 33, args: [:v7], type: :any }
```

## Pass 2: Optimization

### Constant Folding

```
v0 = ICONST 10
v1 = ICONST 20
v2 = IADD v0 v1
```
becomes:
```
v2 = ICONST 30
```

### Dead Code Elimination

Remove instructions whose dst register is never read.

### Copy Propagation

```
v3 = MOV v2
... use v3 ...
```
becomes:
```
... use v2 ...
```

### Peephole Patterns

```
v5 = IADD v3 CONST(1)    ->    IINC v3
v6 = ILT v3 CONST(N)     ->    (fuse with JF into IJLT_JF)
```

### Strength Reduction

```
v2 = IMUL v0 CONST(2)    ->    v2 = IADD v0 v0
v3 = IMOD v1 CONST(2)    ->    v3 = IAND v1 CONST(1)
```

## Pass 3: Register Allocation

Linear scan over 64 physical registers per type:
- `iregs[0..63]` for i64 values
- `fregs[0..63]` for f64 values
- `regs[0..63]` for Value-typed values (strings, lists, etc.)

Algorithm:
1. Walk instructions in order, compute live ranges (first def to last use)
2. Assign physical register when virtual reg first defined
3. Free physical register when virtual reg last used
4. Spill to overflow slots if 64 exhausted (rare for typical functions)

~100 lines. No function calls clobber registers (NATIVE_CALL uses a separate
Value argument list), so there are no save/restore complications.

## VM Dispatch Loop (exec!)

### Register File

```clear
MUTABLE iregs: Int64[] = [];      -- 64 i64 registers
MUTABLE fregs: Float64[] = [];    -- 64 f64 registers
MUTABLE regs: Value[]@list = List[];  -- 64 Value registers
FOR ri IN (0_i64 ..< 64) DO iregs.append(0_i64); END
FOR ri IN (0_i64 ..< 64) DO fregs.append(0.0); END
FOR ri IN (0_i64 ..< 64) DO regs.append(Value.Nil); END
```

### Instruction Encoding

Each instruction is 1-4 Int64 values in the ops array:

```
[opcode] [dst] [src1] [src2]     -- 3-address (IADD, IMUL, etc.)
[opcode] [dst] [imm]             -- immediate (ICONST, FCONST)
[opcode] [cond] [target]         -- branch (JF, JT)
[opcode] [target]                -- jump (JMP)
[opcode] [dst] [nid] [argc] ... -- native call
```

### Opcode Table

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| 0 | ICONST dst imm | iregs[dst] = consts[imm] as i64 |
| 1 | FCONST dst imm | fregs[dst] = consts[imm] as f64 |
| 2 | VCONST dst imm | regs[dst] = consts[imm] |
| 3 | IADD dst a b | iregs[dst] = iregs[a] + iregs[b] |
| 4 | ISUB dst a b | iregs[dst] = iregs[a] - iregs[b] |
| 5 | IMUL dst a b | iregs[dst] = iregs[a] * iregs[b] |
| 6 | IDIV dst a b | iregs[dst] = iregs[a] / iregs[b] |
| 7 | IMOD dst a b | iregs[dst] = iregs[a] MOD iregs[b] |
| 8 | ILT dst a b | iregs[dst] = iregs[a] < iregs[b] ? 1 : 0 |
| 9 | IGT dst a b | iregs[dst] = iregs[a] > iregs[b] ? 1 : 0 |
| 10 | IEQ dst a b | iregs[dst] = iregs[a] == iregs[b] ? 1 : 0 |
| 11 | FADD dst a b | fregs[dst] = fregs[a] + fregs[b] |
| 12 | FSUB dst a b | fregs[dst] = fregs[a] - fregs[b] |
| 13 | FMUL dst a b | fregs[dst] = fregs[a] * fregs[b] |
| 14 | FDIV dst a b | fregs[dst] = fregs[a] / fregs[b] |
| 15 | FLT dst a b | iregs[dst] = fregs[a] < fregs[b] ? 1 : 0 |
| 16 | JMP target | ip = target |
| 17 | JF cond target | if iregs[cond] == 0 then ip = target |
| 18 | JT cond target | if iregs[cond] != 0 then ip = target |
| 19 | CALL_NATIVE dst nid argc r0.. | regs[dst] = applyNative(nid, args) |
| 20 | HALT | stop |
| 21 | I2V dst src | regs[dst] = Value{ Int64Val: iregs[src] } |
| 22 | F2V dst src | regs[dst] = Value{ Number: fregs[src] } |
| 23 | V2I dst src | iregs[dst] = getInt(regs[src]) |
| 24 | V2F dst src | fregs[dst] = getNum(regs[src]) |
| 25 | MOV dst src | regs[dst] = regs[src] |
| 26 | IMOV dst src | iregs[dst] = iregs[src] |
| 27 | FMOV dst src | fregs[dst] = fregs[src] |
| 28 | CONCAT dst a b | regs[dst] = Value{ Str: getStr(regs[a]) + getStr(regs[b]) } |
| 29 | DISPLAY src | print(prStr(regs[src], FALSE)) |
| 30 | VADD dst a b | regs[dst] = polymorphic add(regs[a], regs[b]) |
| 31 | VSUB dst a b | regs[dst] = polymorphic sub(regs[a], regs[b]) |

### Example: Inner Loop

Source:
```clear
WHILE i < 1000000 DO
    s = s + i;
    i = i + 1_i64;
END
```

Stack VM (11 dispatches):
```
LOAD_ISLOT 2       -- push i
LOAD_CONST_I64 4   -- push 1M
LT_I64             -- compare
JUMP_IF_FALSE_I    -- branch
LOAD_ISLOT 1       -- push s
LOAD_ISLOT 2       -- push i
ADD_I64            -- add
STORE_ISLOT 1      -- store s
LOAD_ISLOT 2       -- push i
LOAD_CONST_I64 5   -- push 1
ADD_I64            -- add
STORE_ISLOT 2      -- store i
JUMP               -- loop back
```

Register VM (5 dispatches):
```
ILT  r3 r2 r4     -- r3 = (i < 1M)
JF   r3 exit       -- branch if false
IADD r1 r1 r2     -- s += i
IADD r2 r2 r5     -- i += 1  (r5 holds const 1)
JMP  loop          -- loop back
```

With peephole (4 dispatches):
```
IJLT_JF r2 r4 exit  -- fused compare + branch
IADD r1 r1 r2       -- s += i
IINC r2 1            -- i++ (immediate increment)
JMP loop
```

## What Gets Reused From Stack VM

| Component | Status |
|-----------|--------|
| applyNative() - 61 native functions | Unchanged |
| Value union, Env struct, type accessors | Unchanged |
| Env pool, setupEnv!, environment chain | Unchanged |
| parseConstLine!, loaders | Unchanged |
| prStr, eval!, tree-walker | Unchanged |
| scheme_transpiler.rb AST walker | Unchanged |
| Debugger commands | Adapt to show registers |
| exec! dispatch loop | Rewrite (~370 lines) |
| bytecode_compiler.rb | Rewrite to emit virtual reg IR |

## Effort Estimate

| Task | Lines | Time |
|------|-------|------|
| IR format + Pass 1 (virtual reg emission) | ~300 | 1 day |
| Pass 2 (optimizer) | ~200 | 1 day |
| Pass 3 (register allocator) | ~100 | 0.5 day |
| exec! rewrite | ~370 | 0.5 day |
| Testing + debug | - | 1 day |
| **Total** | **~970** | **~4 days** |

## Performance Expectations

| Benchmark | Stack VM (opt) | Register VM (est) | Python |
|-----------|---------------|-------------------|--------|
| 10x1M tight sum | 685ms | ~280ms | 617ms |
| 100x10K filter | 94ms | ~40ms | 67ms |

The register VM should be ~2x faster than the stack VM and ~1.5-2x faster
than Python on integer workloads, due to halving the dispatch count.
