# TAIL_CALL vs hand-written loop

A `clear-only` benchmark for Thunk Phase 5b. Both variants
compute the same polynomial-hash accumulator
(`acc = acc * 31 + i`, with `i` from N down to 0). The hash
form has no closed form so LLVM has to actually run the loop.

| File | Form | Expected lowering |
|---|---|---|
| `bench_tail_call.clear` | self-recursive with `EFFECTS REENTRANT:TIGHT:TAIL_CALL` | `@call(.always_tail, ...)` -> LLVM `musttail` -> self-`jmp` (TCO), no recursion yield probe |
| `bench_loop.clear` | hand-written `WHILE` | direct loop |

`N` is sampled from `timestampMs() MOD 1000 + 999_999_000` so
LLVM can't constant-fold the result.

## Run

```bash
RUNS=5 bash compare.sh
```

## Results (~1B iterations, optimized build)

```
=== TAIL_CALL (5 runs) ===
elapsed=0.18 rss_kb=2560
  avg_rss_kb=2560  avg_elapsed=.180
=== LOOP (5 runs) ===
elapsed=0.14 rss_kb=2560
  avg_rss_kb=2560  avg_elapsed=.140
```

TCO closes the gap to hand-written loop within ~28% on a polynomial-
hash accumulator. The remaining gap (~40 ms over a 1B-iteration run,
~40 ps per iteration) reflects function-call register-passing
conventions that the loop avoids by holding `i` and `acc` in fixed
registers across iterations.

## What this validates (and what it doesn't)

- **Validates**: `:TIGHT:TAIL_CALL` lowers to a self-jump loop -- the
  recursion runs at depth 1 on the fiber stack. A non-TCO'd
  variant would overflow long before reaching 1B.
- **Validates**: `:TIGHT:TAIL_CALL` no longer forces `@service`
  (Phase 4g). Both variants run on the default fiber tier.
- **Doesn't validate**: bit-for-bit parity with the loop. The
  ~28% gap is a real cost; tight inner loops should still
  prefer the hand-written form. `:TAIL_CALL` is a correctness
  guarantee (no stack growth + no manual mutable state) more
  than a performance equivalence.

## Caveats

- The default `./clear build` (safety mode) does NOT TCO this
  body. The optimized build does. Verify TCO on safety mode is
  out of scope -- by design, safety frames trade speed for the
  bounds/overflow checks.
- Non-tight `:TAIL_CALL` intentionally emits `rt.checkYield()` on
  recursive entry. That cost is measured by
  `benchmarks/inter-clear/01_sequential_recursion_yield_overhead`;
  this benchmark isolates TCO parity against a hand-written loop.
- objdump of `bench_tail_call` should show `jmp` (no `call`)
  for the recursive site. The post-build stack verifier
  (`stack_verifier.rb#verify_tail_calls`) checks this.
