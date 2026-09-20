# Self-host: stage 2b done, stage 3 first contact

Written 2026-09-20 on branch `self-host-i`, to hand the work to another
machine. Everything below is measured unless it says otherwise.

## Where the work stands

The goal is **100% byte compatibility at stage 3 for the annotator**: run the
Ruby annotator and the self-hosted CLEAR annotator over the same corpus,
canonically encode each one's annotated AST, and diff.

| gate | tool | result |
|---|---|---|
| 2b, `mir/mir_lowering.clear` | `selfhost_fn_probe --stage clear` | **1093/1093 functions clean** |
| 2b, rest of the annotator closure (123 files) | same | **8503 functions, 99.94%** |
| 2b, closure compile | `selfhost_check_unit.rb mir/mir_lowering.clear` | in progress, ~60 min/run |
| stage 3 | `annotator_compat.rb --corpus smoke` | harness generates and compiles; **no comparison number yet** |

`mir/mir_lowering.clear` was the last 2b blocker: it is inside the annotator's
124-file REQUIRE closure, so nothing downstream could build until it was
clean. It went 160 -> 0 failing functions.

**Stage 3 has produced no percentage yet.** Do not quote one until
`annotator_compat.rb` prints a comparison. The harness now gets as far as
compiling the generated CLEAR annotator, which it never did before.

## How to continue (the loop that works)

```bash
# 1. The fast gate: one file, every function, stubs for calls. ~2 min for 1000 fns.
CLEAR_PROBE_MULTI=1 bundle exec ruby tools/selfhost_fn_probe.rb \
  --file mir/mir_lowering.clear --stage clear --jobs 10 --out /tmp/x.json

# 2. The slow gate: the whole REQUIRE closure. ~60 min, reports ONE error.
RUBYOPT=-W0 bundle exec ruby tools/selfhost_check_unit.rb mir/mir_lowering.clear

# 3. Stage 3 itself.
bundle exec ruby tools/annotator_compat.rb --corpus smoke --out /tmp/ac
```

For a single function, the per-function probe with `--fn NAME` takes ~30s.
That is the inner loop: read the diagnostic, read the Ruby counterpart
(`compiler/ruby/...` mirrors `compiler/src/...`), fix, re-probe.

**Always gate on a parse check first and delete the result file**, or you will
read the *previous* run's errors and conclude your edit did nothing:

```bash
bundle exec ruby tools/selfhost_parse_check.rb mir/mir_lowering.clear   # 0.3s
rm -f /tmp/x.json    # then probe
```

That mistake cost several cycles before the gate script was fixed to do both.

## Strategy: why this one, and what it replaced

**Current strategy — fix the translation, one function at a time, against the
Ruby.** Every defect is `gems/ruby-to-clear` rendering a Ruby construct
wrongly. The fix is always to make the CLEAR say what the Ruby says. Open
`compiler/ruby/<same path>.rb`, find the method, mirror it.

This works because the failures are not random: they cluster into families,
and a family can be found statically and fixed in one pass.

**Build a checked detector for every family you see twice.** The rule that
matters: *a sweep is safe only when its property is verified per site, never
inferred from a name.* Detectors written this way, and what they found:

| family | sites | detector |
|---|---|---|
| `a \|\| b` -> `a` (fallback dropped) | 3 real of 29 candidates | scope to the Ruby method, compare per site |
| `a && b` -> `TRUE AND b` (nil guard dropped) | 5 real of 154 | check if the dropped operand is optional in CLEAR |
| `next <value>` -> `CONTINUE` (drops the element) | 1 of 537 `CONTINUE`s | match the Ruby method's `next` |
| `x = f(x) if x` -> shadowed local (value discarded) | 3 | purely syntactic |
| `(map[x] OR_ELSE x)` consumes its own key | 7 | purely syntactic |
| same-name casts, different return types | 5 names, 29 failures | compare declared return types |

Note the ratios. 154 candidates, 5 real. A name-based sweep would have
"fixed" 149 correct sites. **That is the failure mode to avoid.**

## What did not work

**A blind sweep by name.** Typing 42 `mIRLowering__with_*` result bindings as
`?Emittable` because the name looked right broke 6 green functions, and the
blanket revert also undid 2 good hand fixes. Net: hours lost, ground lost.

**A detector that models the language wrongly.** A "cross-file cast call with
no declaration in scope" detector counted only DIRECT requires. It reported
24 errors; **CLEAR visibility is transitive**, so all 24 were fine. Copying
the declarations in produced 14 shadowing copies, and the closure check
rejected the first as `DUPLICATE_FUNCTION_DECLARATION`. Reverted wholesale --
and the revert swept away one genuine fix committed alongside, costing another
hour-long round.

The tell, in hindsight: after reverting, *every one* of the 14 names had a
`PUB` declaration elsewhere. If your detector's findings all have an existing
public definition, your visibility model is wrong.

**Reporting progress from a backlog instead of the file.** A 157-function
backlog reached zero while 40 whole-file failures had never been probed.
Always probe `--file` with no `--fn` for the real number. Backlogs order work;
they do not measure it.

**Polling a long build turn by turn.** A 60-minute compile checked every 2
minutes burns 30 turns for nothing. Background it, do other work, and let the
notification arrive.

## Two error classes only the closure check can see

The per-function probe **stubs every name it cannot resolve**, so it is
structurally blind to:

1. **Cross-file references that no REQUIRE brings in.** Fixed three of these;
   each cost one 60-minute round because the check reports one error and stops.
2. **Duplicate declarations** across a package.

Both are findable statically in seconds. When writing such a detector, it must:
- read BOTH `REQUIRE` forms -- `"pkg:rtoc_<hex>"` AND a path relative to the
  requiring file (`"../ast/type.clear"`)
- count `PRIVATE FN`, not just `FN` / `PUB FN`
- treat same-package siblings as visible (`ParserCompat.package_groups`)
- **follow requires transitively**

Get any of those wrong and it lies. All four were learned by getting them wrong.

## Probe failures that are NOT real

The probe compiles one file alone, so two reported failure sets are artifacts:

- `DUPLICATE_DECLARATION 'Scanner'` in `ast/lexer.clear` (33 functions) -- the
  probe's generated types package declares `Scanner`, and so does lexer.clear.
- `Undefined variable 'STMT_RULE_INDEX'` and friends in the parser files (4) --
  those CONSTs live in `ast/parser.clear`, a sibling in the same 7-file package.

Check package membership before believing an undefined-name failure. This
turned a reported 66 failures into a real 33.

## Unmasking a probe crash

The probe's error regex keeps ONE line, so a Ruby `raise` hides the
`CompilerError` behind it. To see the real diagnostic:

```bash
CLEAR_PROBE_KEEP=<dir> ... --jobs 1          # keeps probe.clear
FLAGS=$(ruby -e "require './tools/parser_compat'; \
  puts ParserCompat.package_flags(File.join(Dir.pwd,'compiler','src')).join(' ')")
CLEAR_TRANSPILE_ONLY=1 CLEAR_DISABLE_BUILD_ZIG=1 ./clear build <probe.clear> \
  --no-stack-check --main-tier service $FLAGS \
  --pkg fnprobe_types=tmp/fnprobe/types.clear
```

`tmp/fnprobe/types.clear` persists between runs, which is what makes this work.
One "annotator crash" found this way was an ordinary aliasing error.

## Open items

**A language limitation, needing a decision.** A retained `@multiowned` handle
cannot cross a call *in either direction*: a parameter may not carry a
capability (`FN_PARAM_NO_CAPABILITY`), and passing the handle to a plain
parameter is `COPY_RETAINED_NEEDS_UNIQUE`. `KEEP` does not help. The only way
out is changing the signature to carry what the callee reads -- a divergence
from the Ruby this migration mirrors. Done once, deliberately and flagged, for
`mIRLowering__var_decl_alloc_mark`. **Suggested language fix:** allow a borrow
of a capability-wrapped value across a parameter; every callee hit so far only
READS the handle.

**A compiler bug, minimised, not fixed.** 7 lines:

```clear
PUB STRUCT Cfg { name: String }
FN build(input: Cfg = Cfg{ name: "x" }) RETURNS String ->
  RETURN COPY input.name;
END
FN main() RETURNS Void -> print("${build()}\n"); END
```

Prints `x`, then aborts: *"frame free of memory this arena never allocated --
a frame cleanup was emitted for a value the frame does not own."* All of these
are CLEAN, so the combination is the trigger: explicit argument instead of a
default; default present but parameter unused; `COPY` into a local first; a
`Bool` field instead of `String`.

**The self-hosted `emit_lambda` was a stub.** It rendered the function and
wrapped it, dropping the entire closure environment prologue. Restored this
session, along with `MIR::CaptureEnv` and three `LambdaExpr` fields that did
not exist in the CLEAR MIR. Worth re-reading if closures misbehave at stage 3.

## Rules learned the hard way

- Never `git checkout -- compiler/src`. It has destroyed unmeasured work three
  times. Snapshot with `cp`.
- Never `git stash` in this repo.
- Verify "new" failures are not regressions before fixing them: `git worktree
  add` at the pre-change commit and probe the same list there. 39 of 40
  suspected regressions turned out to be pre-existing.
- A function-extent scan must stop at an **unindented** `END`; stopping at the
  first `END` strands the tail of the function, and it parses.
