# Stdlib Intrinsic Contract Plan

Branch focus: `architectural-review`.

Status: implemented.

Baseline source size: `src/**/*.rb` has 98,071 lines.

Baseline metrics:

| Metric | Before |
| --- | ---: |
| Decomplex cross-detector convergence | 1765 |
| Decomplex root-cause clusters | 474 |
| Decomplex state heatmap | 569 |
| Decomplex state-based branch density | 1609 |
| Decomplex broken protocols | 389 |
| SlopCop dark arms | 2764 |
| SlopCop genuine gaps | 1132 |
| Boobytrap hotspots | 95 |
| Boobytrap state-based branch hotspots | 1609 |

## Goal

Keep `src/ast/std_lib.rb` as a compact authoring DSL. Do not make stdlib
function declarations verbose or constructor-heavy.

The architectural fix is the boundary conversion:

```text
stdlib DSL hash
  -> IntrinsicRegistry.convert_entry
  -> FunctionSignature + IntrinsicContract
  -> annotation / MIR lowering / MIR checking / emission
```

After conversion, correctness-significant consumers should ask typed contract
questions instead of probing optional emit fields. Stdlib calls should therefore
behave like ordinary function calls with a stronger attached callable contract,
not like special hash rows interpreted at every phase.

## Non-Goals

- Do not replace the readable stdlib DSL with a verbose typed literal syntax.
- Do not add a second intrinsic lowering path.
- Do not move Zig rendering before the emitter.
- Do not keep adding adapter fields without deleting downstream interpretation.

## Design

Add typed contract records built once by `IntrinsicRegistry`:

- `IntrinsicTemplateContract`
  - closed template lookup by kind (`:zig`, `:numeric_zig`, `:sharded_zig`,
    `:shard_direct_zig`);
  - BC flag and BC opcode;
  - primary pattern for AST marker compatibility.
- `IntrinsicAllocationContract`
  - allocation production;
  - receiver/node/key/value/shard alloc placeholders;
  - return allocation;
  - frame-allocation predicates.
- `IntrinsicOwnershipContract`
  - receiver mutation;
  - value-taking arguments;
  - borrow/container-borrow facts.
- `IntrinsicBehaviorContract`
  - method/static shape;
  - suspension;
  - collection narrowing;
  - rejection and error metadata.
- `IntrinsicContract`
  - one narrow surface exposed through `FunctionSignature`.

The raw `IntrinsicEmit` object can remain as the compact compatibility payload
for registry authoring and emitter templates while consumers migrate. The new
contract is the preferred internal API.

## Implementation Tasks

1. Add strict typed contract records and build them at the registry boundary.
2. Expose contract helpers on `FunctionSignature` so stdlib calls look like
   ordinary callable signatures with extra typed facts.
3. Migrate high-value consumers:
   - annotation marking in `expression_domains.rb`;
   - typed method resolution in `method_analysis.rb`;
   - intrinsic lowering in `MIRLoweringFunctions#lower_intrinsic`;
   - registry template lookup in `MIREmitter`;
   - runtime/escape/control-flow allocation probes.
4. Add focused tests proving:
   - every registry entry builds a contract;
   - contract facts match representative DSL entries;
   - template lookup rejects missing kinds;
   - method/static annotation reads contract facts;
   - lowering/emission still render representative registry calls.
5. Run Sorbet, targeted specs, diff coverage buckets, Decomplex, SlopCop, and
   Boobytrap.

## LOC Budget

Target production `src/` net increase: `<= 250` lines.

Ideal production `src/` net increase: `<= 150` lines.

If the final net increase is large, this was probably implemented as another
layer instead of a boundary cleanup.

Final production `src/` size: `98,309` lines, net `+238`.

## Final Metrics

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Decomplex cross-detector convergence | 1765 | 1762 | -3 |
| Decomplex root-cause clusters | 474 | 474 | 0 |
| Decomplex decision pressure | 275 | 278 | +3 |
| Decomplex state heatmap | 569 | 569 | 0 |
| Decomplex state-based branch density | 1609 | 1610 | +1 |
| Decomplex temporal ordering pressure | 14 | 14 | 0 |
| Decomplex missing abstractions | 190 | 188 | -2 |
| Decomplex neglected path conditions | 1414 | 1410 | -4 |
| Decomplex broken protocols | 389 | 389 | 0 |
| SlopCop dark arms | 2764 | 2965 | +201 |
| SlopCop genuine gaps | 1132 | 1307 | +175 |
| Boobytrap hotspots | 95 | 95 | 0 |
| Boobytrap state-based branch hotspots | 1609 | 1610 | +1 |

Assessment:

- The local architectural change is a net Decomplex win in convergence,
  missing abstractions, neglected path conditions, and the main
  stdlib-lowering hotspots.
- `MIRLoweringFunctions#lower_intrinsic` moved from 13 to 11 state-based
  branch decisions.
- `MethodAnalysis#resolve_typed_method` dropped out of the top state-branch
  list after consumers stopped probing loose emit fields directly.
- The whole-repo SlopCop/Boobytrap deltas are not a clean architectural
  before/after because the final coverage resultset was regenerated. The
  scoped SlopCop report for touched stdlib-contract files does not list
  `src/annotator/helpers/intrinsic_contract.rb` in the top true gaps.
- The new contract file has merged SimpleCov coverage of 88/88 lines and
  18/18 branch arms.
