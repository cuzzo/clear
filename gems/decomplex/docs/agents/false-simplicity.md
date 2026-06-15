# decomplex -- false simplicity

## Why this exists

Some code looks simple but is dangerous because its behaviour is not
local. A one-line method that calls `obj.send(name, *args)`, mutates
through a reference, reads `ENV`, does file IO, inverts control into a
`transaction { ... }` block, or is reopened from another file is
*syntactically* trivial and *operationally* unknowable at the call
site. Coverage cannot see this -- the falsely-simple line is often
100% covered. Complexity counters (Flog/McCabe) cannot see it -- the
line scores ~1. It is the same plague decomplex already targets
(code that looks local but is not), one rung lower than re-derived
decisions: non-local *behaviour* hiding behind local-looking *syntax*.

This started as the big Ruby-specific bucket, but now runs over
decomplex's normalized Tree-sitter AST. Ruby still has the richest
profile because open classes, `method_missing`, `define_method`,
`instance_eval`, and blocks-as-control create many local-looking
forms with non-local behavior. Other languages use smaller language
profiles instead of inheriting Ruby's trigger words.

## Goal

Surface, as a ranked **candidate list** (Engler's discipline -- FP is
the accepted cost of recall, verdicts are not), every site whose local
syntax understates its non-local behaviour, ranked by the same
blast-radius thesis as the rest of decomplex: a trigger scattered
across N methods is one missing abstraction (introduce one typed
dispatch, the 14 `send`s collapse), ranked `support x scatter`.

Non-goals: it does not decide a `send` is wrong (dynamic dispatch is
sometimes correct); it does not do interprocedural points-to (alias-
aware mutation defers to the existing `semantic_alias` /
`predicate_alias` machinery -- see Scope); its output is triaged by a
human, never auto-applied.

## Detector catalogue

One category, seven sub-detectors. **#8 (protocol-looking name pairs:
`open`/`close`, `lock`/`unlock`, `begin`/`commit`/`rollback`) is NOT
here -- it already ships as Broken Protocols (`SequenceMine`,
Engler/PR-Miner co-call mining).** Reimplementing it here would
duplicate an existing owner; a falsely-simple half-protocol is a
Broken-Protocols finding by construction.

Every rule is pure node matching on decomplex's normalized
Tree-sitter AST -- no dataflow, no CFG, no points-to. Each is a
closed, enumerable trigger set, which is exactly what makes it
exhaustively testable.

| # | sub-detector | AST reduction (what fires) | excluded (no-FP) |
|---|---|---|---|
| 1 | **hidden dynamic dispatch** | language profile dynamic-dispatch calls such as Ruby `send`/`public_send` or Python `getattr`/`setattr`; `method(...).call`; proc/lambda invoke (`CALL :call` on a local/ivar recv); Ruby `YIELD` | a normal `.call` on a method-chain receiver; named method calls |
| 2 | **hidden mutation** | bang call (`CALL`/`FCALL`/`VCALL` mid ends `!`); `OPCALL :<<`; `ATTRASGN` (`recv.x=` and `recv[i]=`); `OP_ASGN1`/`OP_ASGN2` (`h[k]+=`, `o.a||=`) | unary `!` / `!=` (OPCALL, not bang); local `x+=1` (`LASGN`), `y||=2` (`OP_ASGN_OR`), `@n+=1` (`IASGN`) -- all node types we never match |
| 3 | **hidden global/context** | language profile ambient context calls such as Ruby `ENV`, `Time.now`, `Thread.current`, Python `time.time`, or JavaScript `Date.now`; Ruby globals (`$x`) | arithmetic on a passed value; non-context constant receivers |
| 4 | **hidden IO / effects** | language profile IO/effect calls such as Ruby `File.read`, Python `open`, JavaScript `fs`/`fetch`, process/system calls, sleeps; Ruby backticks / `%x` | pure string/array methods; unrelated local methods with the same name |
| 5 | **callback / control inversion** | `ITER`/`LAMBDA` (or `&block` arg) whose callee mid is in {`transaction`,`synchronize`,`lock`,`with_lock`,`mutex`,`atomic`,`subscribe`,`callback`,`hook`} or matches `/^(with_|around_|on_|before_|after_)/` or `/_hook$/` | iteration blocks (`each`/`map`/`select`/`reduce`/`times`/`loop`/...) -- local, well-understood, never matched |
| 6 | **runtime reflection** | language profile reflection calls such as Ruby `define_method`/`instance_eval`/`const_set`, Python `eval`/`exec`/`setattr`, or JavaScript `eval`/`Function`/`defineProperty`; Ruby `method_missing`/`respond_to_missing?`; Ruby singleton-class reopen on a non-self receiver | low-signal declaration helpers such as Ruby `attr_*`, `include`/`extend` |
| 7 | **reopen / monkeypatch** | profile-defined core type reopen with method definitions; cross-file: same fully-qualified owner defined-with-methods in >=2 distinct files | a first/single project-class definition; a namespacing/module wrapper with no direct method definitions |

## Ranking

Identical to Missing Abstractions, because it is the same idea. The
group key is `[kind, detail]` (e.g. `[:dynamic_dispatch, "send"]`).
`scatter` = distinct `(file, method)` units exhibiting it; `support`
= total occurrences. Sort `[-scatter, -support, kind]`. The thesis:
`send` reinvented across 14 methods is one missing typed dispatch
(`scatter = 14`, top of list) -- "fix once, kill 14", exactly the
decomplex blast-radius discipline. A singleton-but-severe hit (a core
monkeypatch in one file) still appears; the section's *tier* (3),
not its rank, encodes that the category is high-recall/noisy.

`detail` is the concrete trigger string so triage is a one-line read
(`file:line (method)` + the offending token), the shape LLMs consume
well.

## Prior art (honest)

The shallow half of these are commodity -- as **scattered, binary,
single-file lints under unrelated framings**, none unified, none
blast-radius ranked, none cross-file:

- RuboCop: `Style/Send` (off by default), `Style/GlobalVars`,
  `Rails/Output`, `Security/Open`/`Security/Eval`,
  `Style/MethodMissingSuper`, `Lint/Debugger`,
  `Rails/TransactionExitStatement`, rubocop-thread_safety,
  rubocop-sorbet `T.unsafe`. Each is a *style/security/Rails/thread*
  verdict, binary, per-file, several disabled by default.
- Reek: `Attribute` grazes #2's attr-writer sliver only.
- Sorbet/flog/flay/debride: orthogonal axes (types/complexity/dup/dead).

What no mainstream Ruby tool does, and decomplex does: **one category,
blast-radius ranked, cross-file/cross-method aggregated**, plus the
research-grade pieces -- #5 control inversion, #2 alias-aware mutation
(deferred, see Scope), and #8 protocol-pair mining (already shipped as
Broken Protocols; Engler "Bugs as Deviant Behavior" SOSP'01).

Lexicons (the effectful/global/dispatch name tables) are provider
data. Ruby's profile was **mined from RuboCop/Reek/stdlib as
reference data, copied once at authoring time, not a runtime
dependency**. Other languages use smaller profiles for their own
standard/runtime surfaces, and unsupported languages fall back to a
generic profile rather than Ruby keywords like `send` or `File`.

## Scope and caveats (v0)

- **Alias-aware mutation (#2 hard tier) is deferred, not faked.**
  `a = config; b = a; b[:enabled] = false` needs local alias tracking;
  RuboCop/Reek do not do it either. decomplex already owns alias
  machinery (`semantic_alias`, `predicate_alias`); the alias tier will
  reuse it rather than grow a second points-to path. v0 reports the
  direct-mutation tier (bang/`<<`/`[]=`/attr=/op-asgn/ivar-set) -- an
  honest scope limit, reported as such (principle 4: exact before
  semantic).
- **`logger.info`-style effects** are not matched: the receiver
  (`logger`) is a local whose type is unknown without dataflow.
  `Logger`/`$stdout`/`$stderr`/`Rails.logger` route through the
  constant/global rules; the bare-local logger case is intentionally
  out (accept the recall loss over the FP, principle 2).
- **Dynamic dispatch is not always wrong.** A pervasive, deliberate
  dispatch pattern (a registry) will rank high by scatter; that is
  correct -- it is exactly the place a named abstraction pays off.
  The report says *POSSIBLE*, never "bug".

## Design principles (inherited)

1. **Parser facade.** Use decomplex's normalized Tree-sitter AST and
   language profiles; no detector reaches into a Ruby-only parser.
2. **Ranked candidates, never verdicts.** `support`/`scatter` sorted,
   `file:line` printed, *POSSIBLE*, tier 3 (high-recall/noisy).
3. **Additive.** Broken Protocols (#8) is reused, not duplicated.
4. **Exact before semantic.** Direct-mutation tier ships; alias tier
   deferred to existing alias machinery rather than reimplemented.
5. **Self-tested.** `test/false_simplicity_test.rb` carries, per
   sub-detector, a positive, a negative, and a no-false-positive case
   (every exclusion column above is a test). A bug detector with bugs
   is worse than none.

## Relationship to the other gems

decomplex owns this metric end to end (detection + the ranked report;
its `report.md` is complete standalone). `slopcop` may *optionally*
consume the per-site verdict to up-rank a coverage gap that is also a
falsely-simple site -- the same consumer pattern it already uses for
nil-kill's `type_norm`. That is a downstream enrichment on the
coverage axis, never a second home: false simplicity is orthogonal to
coverage (a falsely-simple line is usually fully covered). `boobytrap`
(churn) and `nil-kill` (nilability) are unrelated axes and not
involved.
