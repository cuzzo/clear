# Register VM: Error-Union Runtime (RAISE / OR RAISE / OR EXIT / CATCH)

Status: IN PROGRESS (started 2026-05-17, `register-machine` branch).
Owner cluster: roadmap P2 "CatchWrapper / RAISE / OR EXIT", ~13 tests.

## Why this is structured, not Zig-text

`MIR::CatchWrapper.code` is a Zig string (Zig-backend path) and MUST
NOT be parsed (CLAUDE.md no-Zig rule). But CatchWrapper also carries
fully structured fields, and RAISE / OR RAISE lower to ordinary
structured MIR — verified by MIR dump of `76_catch_blocks`:

| Surface | Structured MIR |
|---|---|
| `RAISE K, T, "m"` | `ExprStmt MethodCall rt.setError(.K, @intFromEnum(ErrorName.T), "m", line)` then `ReturnStmt Ident("error.CheatError")` |
| `call() OR RAISE` | `MIR::TryExpr(Call)` |
| `call() OR EXIT ...` | `MIR::TryExpr(Call)` + `CatchWrapper.error_reassigns` |
| CATCH/DEFAULT fn | `MIR::CatchWrapper{ clause_meta, clause_bodies, has_default }` |

`clause_meta` example (`76`):
`[{kinds:["Transient"],types:[],filter_types:[],filter_messages:[]},
  {kinds:["Input"],types:[],filter_types:["InvalidJson"],filter_messages:[]}]`
plus `has_default=true` and 3 `clause_bodies` (Transient, Input
WITH(InvalidJson), DEFAULT).

## Runtime-faithful (no shadow error model)

The VM runner (`vm.cht`) holds a real `rt: *Runtime`. It uses the
REAL error context, not a reimplementation:

- `Runtime.__error: ErrorContext { kind: ErrorKind(u8 enum), error_name: u32, message: []u8, clear_line: u32 }`
- `rt.setError(kind, error_name, message, clear_line)`
- `rt.__error.matchesKind(kind)` / `matchesName(u32)` / `matchesMessage([]u8)`
- `ErrorKind` fixed enum: Transient=0 Input=1 System=2 NotFound=3
  Permission=4 Canceled=5 Unknown=6.
- `error_name` u32 ids come from the per-program error registry
  (`src/ast/error_registry.rb`); the emitter resolves clause type
  names -> ids the same way the Zig backend does.

## VM mechanism

One VM-loop flag: `errored: Int64` (0 ok / 1 raised). The (kind,
name, message) payload lives in the real `rt.__error`. `errored` is
the cross-frame control signal.

New opcodes (each via README "Adding a New Opcode" 4-part recipe:
layout, emitter, decoder+arity, dispatch+trace):

| Opcode | Operands | Semantics |
|---|---|---|
| `ERAISE` | kindConst nameConst msgConst lineConst | call real `rt.setError(@enumFromInt(u8), name, msg, line)`; `errored = 1` |
| `EGUARD` | target | `IF errored == 1 THEN ip = target` (propagate: jump to fn error-epilogue, which RETs with errored still 1) |
| `ECLR` | (none) | `errored = 0; rt.__error.reset()` (a clause handled it) |
| `EMATCHK` | dst kindConst | `dst = (errored==1 and rt.__error.matchesKind(@enumFromInt(kind))) ? 1 : 0` |
| `EMATCHN` | dst nameConst | `dst = (errored==1 and rt.__error.matchesName(name)) ? 1 : 0` |
| `EMATCHM` | dst msgConst | `dst = (errored==1 and rt.__error.matchesMessage(msg)) ? 1 : 0` |

`RETURN error.CheatError` reuses the existing RET path (return value
unused); `errored=1` is what callers test.

### Lowerings

- `rt.setError(...)` MethodCall  -> `ERAISE` (replaces the current
  no-op at register_bc_emitter.rb:952 for setError specifically).
- `MIR::TryExpr(call)` / OR RAISE -> compile the call, then `EGUARD
  fn_error_epilogue`. The epilogue is a per-fn label that RETs
  (errored stays 1 -> propagates one frame up).
- `MIR::CatchWrapper` -> emit call to the inner `__*_body` FnDef
  (compiled as a normal fn). Then:
  - `IF errored == 0` -> return inner's value (success).
  - else, per clause in `clause_meta`, build predicate:
    OR over `kinds` (EMATCHK) and `types` (EMATCHN);
    if `filter_types` present, AND (OR over EMATCHN);
    if `filter_messages` present, AND (OR over EMATCHM).
    First true clause: `ECLR`, run its `clause_body` (ends in RETURN).
  - else if `has_default`: `ECLR`, run default body.
  - else: leave errored=1, RET (re-propagate).
- OR EXIT (`error_reassigns`): before propagating, call `rt.setError`
  with overridden (kind|name|message) fields, inheriting the current
  `rt.__error` value for any field not overridden (B clears type to
  0; A inherits kind+type, replaces msg only; etc. per `272`).

## Commit plan

1. **Foundation**: `errored` flag, `ERAISE`, `EGUARD`, `ECLR`,
   `EMATCHK`; TryExpr/OR RAISE propagation; CatchWrapper kind-only +
   DEFAULT dispatch. Target: kind-only / DEFAULT asserts of
   `76_catch_blocks`, `271_catch_unified` (`kindOnly`, `multiKind`,
   `directType` partial).
2. `EMATCHN` + `types` / `filter_types`: `CATCH Type`,
   `CATCH Kind WITH(T)`, `WITH(T1,T2)`, multi-type. Full `271`.
3. `EMATCHM` + `filter_messages`: `WITH("msg")`, `WITH(T,"msg")`.
   Completes `76`, `271`.
4. OR EXIT `error_reassigns` (inherit-vs-override matrix). `272`.
5. `MIR::TryCatch` / `MIR::TryExpr` at expression-stmt position
   (216, 217, 350, 360, 381, 519, 524).
6. Snapshot forms if reachable (`77`, `78`); else mark pending.

## Test corpus

CatchWrapper: 76, 77, 78, 271, 272, 352.
TryCatch: 216, 217, 350, 524.  TryExpr: 360, 381, 519.
Add crossed tests to `register-transpile-allowlist.txt`; bump
`run_tests.rb --min-pass` only after green + zero regressions.

## Invariants

- No Zig parsing; only `clause_meta`/`clause_bodies`/`error_reassigns`.
- Real `rt.__error` + real `rt.setError`/`matches*`; no shadow model.
- New `vm.cht` runtime control flow -> exercise via the register
  debugger integration spec (CLAUDE.md runtime-change rule); the VM
  is single-threaded so no Loom/Hammer needed for `errored` (no
  atomics/threads added).
