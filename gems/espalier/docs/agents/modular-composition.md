# Modular bound composition

## The problem

A function's bound is composed by substituting each callee's bound into the
caller's. `SymbolicComplexity.substitute` maps the callee's *parameter* domains
onto the caller's arguments, which is correct and modular. Every other domain
the callee's bound names passes through untouched:

```ruby
replacements = Array(mapping[id])
replacements = [id] if replacements.empty?   # symbolic_complexity.rb:152
```

A callee's internal quantities are not parameters: a loop inside it, a call-input
size, a lambda's parameter, an opaque cost. None is something the caller can
vary, and none is mapped, so all of them accumulate into the caller verbatim -
and then into *its* caller, and so on up.

Measured on decomplex, from espalier's own variable records:

```
run_with_args
  N <- collapsed:size        "maximum of 391 size domains"
  C <- collapsed:callback    "maximum of 90 callback cost domains"
  R <- collapsed:reflection  "maximum of 56 reflective target cost domains"
```

`scan_files` in fact-mine is parameterised by `loop:.../parallel.rs:58:8` and
`param:parallel#<lambda@98:50>:value` - a loop and a closure parameter belonging
to a function three levels down.

`normalize` guards against the growth: past `RENDER_DOMAIN_LIMIT = 128` factor
entries it calls `collapse_expression`, which folds every size domain into one
symbol whose exponent is the sum per term. Seven independent quantities become
`N^7`, which is how `parse_files` - a function that parses a list of files -
reports `O(N^6*R^2*C log N)`.

The guard is not the defect. Removing it does not terminate: unbounded symbolic
composition explodes. The defect is that the expression reaches 391 domains.

### What it costs

| | functions | with a collapsed bound | of those, incomplete |
| --- | ---: | ---: | ---: |
| decomplex | 1145 | 16 (1.4%) | 12 |
| fact-mine | 7041 | 192 (2.7%) | 182 (95%) |

Collapse touches few functions and is near-fatal where it lands, because it
lands on the hubs. Of the 17 fact-mine symbols decomplex needs, 8 have collapsed
bounds and those 8 gate 36 of decomplex's 125 incomplete functions.

It also explains why fixing leaves yields so little. A leaf contributes one
domain out of 391; closing it changes nothing about the hub that depends on all
of them. Estimates of 262, 421 and 616 functions delivered 16, 8 and 100.

## The principle

**A function's bound names only quantities its caller can vary.** Its own
parameters, its own state, its own loops - and, for each call it makes, at most
one atom standing for what that call costs.

This is what makes composition modular: the cost of composing is bounded by the
number of call sites, not by the size of the transitive call graph.

## The rule

In `substitute`, a domain from the callee's expression is treated as one of:

1. **Mapped** - the callee's parameter, bound to the caller's argument domains at
   this call site. Unchanged from today.
2. **Caller-visible** - already a domain of the caller (the caller and callee
   share it, e.g. the same state field). Passes through, as today.
3. **Unmappable** - anything else: a loop inside the callee, a call-input size, a
   cost, a nested lambda's parameter. These fold into **one atom per call**,
   standing for that call's own internal cost.

Folding is per term: every unmappable factor in a term contributes the atom once,
so `A * B * C` with `A` mapped becomes `A_caller * X`. The atom denotes the
maximum over terms of what it replaced, which is the same upper-bound reading
`collapse_expression` already uses - applied to one call's private part rather
than to the caller's whole accumulated expression.

### Soundness

`X` denotes a determinate quantity: the callee's bound with its caller-visible
part factored out. Replacing several factors by one symbol whose value is their
product is an equality, not a relaxation; taking the maximum across terms is the
same upper bound the renderer already takes. Nothing becomes unknown, so
`complete` is untouched.

The atom's `source_kind` is `callee_internal_size`, deliberately not ending in
`_cost`: it is a size, not a callback or reflective boundary, so `opaque_cost?`
stays false and the bound does not become parametric.

## Where it goes

- `symbolic_complexity.rb` - `substitute` gains `unmappable_atom:`; when given,
  rule 3 applies. Without it, behaviour is exactly as today.
- `structural_big_o.rb` - `propagated_call_symbolic` supplies the atom for the
  call it is composing, identified by the callee.

No adapter changes. Nothing language-specific: a call boundary is a call
boundary in every language.

## What stays the same

Parameter mapping, callback substitution at the call site, the partition/product
choice for iteration multiplicity, recursion summaries, and `collapse_expression`
itself, which remains as the guard of last resort.

## Verification

A/B on all seven corpora - decomplex, zod, rich, unslop, gremlins, okio,
swift-argument-parser - before and after, plus the count of functions carrying a
collapsed domain and the largest collapse. No yield is predicted in advance;
the numbers are whatever they measure.
