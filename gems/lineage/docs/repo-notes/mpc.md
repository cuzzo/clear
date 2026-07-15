# mpc — C

**Revision:** `1049534fc56b` · **Scope:** `mpc.c`, `mpc.h` · **Result:** parser
composition and AST copying are real difficult surfaces; 93.1% unknown Big-O
is a clear capability gap, not a library-performance verdict.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 2 files, 276 methods, 93 fields; Type Next does not apply to declared C signatures. |
| Espalier | 257/276 bounds unknown (93.1%). `mpc_input_t` and `mpc_parse_run` are highest pressure. |
| Decomplex | 97 convergences: `mpc_optimise_unretained`, `mpc_copy`, `mpc_ast_add_root`, `mpcf_re_range`, and grammar definition. |

## Independent source audit

- `mpc_copy` is an explicit recursive copy over parser combinator variants;
  its cost tracks parser graph size and may duplicate nested structure. The
  report correctly flags its deep branching and ownership transitions.
- `mpc_optimise_unretained` walks/transforms parser structures; the large
  switch is a true maintainability hotspot, though variant-specific behavior
  prevents assuming each branch is a bug.
- `mpc_parse_run` is a parser-state machine driven by user grammar callbacks.
  Callback and grammar recursion make a simple source-only bound invalid.

## Assessment and follow-up

- This is the clearest C corpus example where Espalier needs algebra over
  recursive combinators: it should expose an input/grammar-dependent symbolic
  bound or deliberately opaque call boundary, not collapse 257 functions to
  unknown.
- No likely product bug was found from reading source. Potential copy/optimize
  blow-ups require a deliberately shared/deep grammar benchmark before any
  claim is made.

## Second-pass time/space audit

- **Partial evidence:** 257/257 unknown time and space results retain
  components. Allocation-only input constructors are appropriate unknowns;
  `mpc_copy` and `mpc_optimise_unretained` are under-specified recursive parser
  graph walks. The sample is two under-specified, one appropriate.
- **Actual dominant work:** parser execution depends on input, grammar graph,
  backtracking, and callback behavior; copying/optimizing parser and AST graphs
  costs graph size and allocation space. Callback cost is legitimately opaque,
  but graph traversal is not.
- **Coverage verdict:** Espalier should emit separate grammar/input/opaque
  callback components and recognize recursive copy/transform patterns. This is
  general parser-combinator support, not an mpc-specific rule.
