# decomplex — minimal examples per warning

The smallest Ruby that triggers each detector, what decomplex reports,
and a clean variant that does NOT trigger (so the boundary is explicit).
Every example is distilled from a verified test fixture in `test/`.
Sections are grouped by signal tier (see
[design.md](agents/design.md)); within a tier, lower false-positive
first. All findings are *POSSIBLE* candidates, never verdicts.

---

# Tier 1 — lowest false-positive

## Missing Abstractions

A decision (a `case/when` arm-set or an `&&` operand-set) recomputed
verbatim in >= 2 distinct `(file, method)` units. The decision was
never named.

`case/when` form:

```ruby
def a(n)
  case n
  when AST::FuncCall   then 1
  when AST::MethodCall then 2
  end
end
def b(n)
  case n
  when AST::FuncCall   then 3
  when AST::MethodCall then 4
  end
end
```

Conjunction form:

```ruby
def a(t); 1 if t.collection? && !t.heap? && !t.rodata?; end
def b(t); 2 if t.collection? && !t.heap? && !t.rodata?; end
```

Reports: `[case_dispatch] support=2 scatter=2 ... tuple: AST::FuncCall | AST::MethodCall`

Clean (a single use is not duplication):

```ruby
def only(n)
  case n
  when AST::FuncCall   then 1
  when AST::MethodCall then 2
  end
end
```

## Reification Misses

A one-line predicate exists, and its body is reinvented inline
elsewhere instead of calling it. Direct invariant-#16 violation.

```ruby
def frame?; @provenance == :frame; end

def somewhere(node)
  return 1 if node.provenance == :frame   # should be node.frame?
end
```

Reports: ``predicate `frame?` reinvented inline at `file:6` (somewhere)``

Clean:

```ruby
def frame?; @provenance == :frame; end
def somewhere(node)
  return 1 if node.frame?
end
```

## Semantic Predicate Aliases

Two predicate *names* whose bodies are equal after folding receiver
(`node.`, `self.`, `@`) and polarity — the same decision under aliases.

```ruby
def frame?;    @provenance == :frame; end
def is_frame?;  provenance == :frame; end
```

Reports: ``frame? = is_frame? == `provenance == :frame` ``

Clean (genuinely different decisions):

```ruby
def frame?; @provenance == :frame; end
def heap?;  @provenance == :heap;  end
```

## Exact Predicate Aliases

Stricter than the semantic form: byte-identical one-line body under
>= 2 names (no canonicalization). Lowest possible FP.

```ruby
def frame?;    @provenance == :frame; end
def is_frame?; @provenance == :frame; end
```

Reports: ``frame? = is_frame? == `@provenance == :frame` ``

Clean: any difference in the body text (then see Semantic Aliases).

---

# Tier 2 — POSSIBLE bug, moderate false-positive

## Inconsistent Rename Clones

A pasted block whose identifier mapping is inconsistent. This is the
specific missed-rename bug detector; Flay owns the broader Type-2/3
similarity signal.

```ruby
def original
  src = fetch(1)
  check(src)
  store(src)
  finalize(src)
end
def pasted
  dst = fetch(2)
  check(dst)
  store(src)      # missed rename: should be dst
  finalize(dst)
end
```

Reports: ``*POSSIBLE* file:7 (pasted) clone of file:1 (original): ref var `src` spelled ["dst", "src"] here``

Clean (consistent rename):

```ruby
def a
  src = fetch(1); check(src); store(src); finalize(src)
end
def b
  dst = fetch(2); check(dst); store(dst); finalize(dst)
end
```

## Flay Similarity (Type-2/3)

Flay-backed structural clone pressure. Decomplex consumes Flay's clone
clusters read-only and reports Type-2 renamed clones and Type-3 fuzzy
clones in its normal finding format so SlopCop can correlate them with
uncovered branch gaps.

```ruby
def a(node)
  return false unless node.respond_to?(:type)
  node.type == :heap || node.type == :frame
end
def b(entry)
  return false unless entry.respond_to?(:kind)
  entry.kind == :heap || entry.kind == :frame
end
```

Reports: ``*POSSIBLE* [type2] mass=... node=`defn` file:1 (a) ; file:5 (b)``

Clean: extract the shared predicate or collapse the duplicated node
shape. Exact Type-1 clones are intentionally left to raw Flay output;
this Decomplex section focuses on Type-2/3 similarity.

## Neglected Updates

Two attributes co-written in >= 3 methods; another method writes one
without the other (redundant-state desync — the documented
`storage`/`provenance` pairing).

```ruby
def a(n); n.storage = :heap; n.provenance = :heap; end
def b(n); n.storage = :heap; n.provenance = :heap; end
def c(n); n.storage = :heap; n.provenance = :heap; end
def bug(n); n.storage = :heap; end              # .provenance not set
```

Reports: ``*POSSIBLE* (support=3) file:4 (bug) writes `.storage` but NOT `.provenance` (recv `n`)``

Clean: `bug` also sets `n.provenance`.

False-positive note: legitimate when the documented exception applies
(e.g. a shared struct Type) — triage, do not auto-fix.

## Derived-State Staleness

`b` is derived from `a`; `a` is later reassigned in the same method
but `b` is not recomputed, so later uses of `b` are stale.

```ruby
def f(a)
  b = a + 1
  a = recompute(a)
  use(b)            # b still reflects the OLD a
end
```

Reports: ``*POSSIBLE* file:1 (f): `b` derived from `a` (line 2); `a` reassigned line 3, `b` not recomputed``

Clean (recomputed, or source never reassigned):

```ruby
def f(a)
  b = a + 1
  a = recompute(a)
  b = a + 1
  use(b)
end
```

## Neglected Conditions

A `case`/conjunction site that is a high-support pattern (>= 3
occurrences) minus exactly one element.

```ruby
def a(x); f(x) if x.p? && x.q? && x.r?; end
def b(x); f(x) if x.p? && x.q? && x.r?; end
def c(x); f(x) if x.p? && x.q? && x.r?; end
def bug(x); f(x) if x.p? && x.q?; end          # x.r? missing
```

Reports: ``*POSSIBLE* (support=3) file:4 (bug) -- MISSING `x.r?` from `x.p? | x.q? | x.r?` ``

False-positive note: this is the textbook FP class. A tokenizer that
scans `( ) ; [ ] { }` in most places but omits `;` inside `[...]` is
*intentionally* "missing" an element. Always triage.

---

# Tier 3 — POSSIBLE bug, high recall / noisy

## Neglected Path Conditions

Same as Neglected Conditions but over the *path condition* (the
conjunction of guards reaching a statement), so nested `if`s and flat
`&&` are unified, and `else` branches are polarity-negated.

Unification (these two produce the same guard set `{x.a?, y.b?}`):

```ruby
def nested(x, y)
  if x.a?
    if y.b?
      do_it
    end
  end
end
def flat(x, y)
  do_it if x.a? && y.b?
end
```

Neglected form:

```ruby
def a(x,y,z); go if x.p? && y.q? && z.r?; end
def b(x,y,z); go if x.p? && y.q? && z.r?; end
def c(x,y,z); go if x.p? && y.q? && z.r?; end
def bug(x,y,z); go if x.p? && y.q?; end        # z.r? missing
```

Reports: ``*POSSIBLE* (support=3) file:4 (bug) -- MISSING `z.r?` from `x.p? | y.q? | z.r?` ``

Clean: a single guarded action, or every site carrying the full set.

## Broken Protocols

Two call message-names co-occur in >= 4 methods (an implied protocol);
one method calls one without the other. Ranked by directed confidence
(`support(pair) / support(has)`); pervasive glue is suppressed because
it appears in unrelated contexts, lowering its confidence.

```ruby
def a; alloc_mark(x); cleanup(x); end
def b; alloc_mark(y); cleanup(y); end
def c; alloc_mark(z); cleanup(z); end
def d; alloc_mark(w); cleanup(w); end
def leak; alloc_mark(q); use(q); end           # cleanup not called
```

Reports: ``*POSSIBLE* conf=0.8 support=4 file:5 (leak) does `alloc_mark` without `cleanup` ``

Clean: `leak` also calls `cleanup(q)`.

False-positive note: co-call is not causation; high confidence + a
single deviant is the strong signal, low confidence is incidental.
