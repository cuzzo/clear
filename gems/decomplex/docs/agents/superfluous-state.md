# Superfluous State (Tier 1) -- state that can be eliminated entirely

## Why this exists

StateMesh answers "where is state and how messy is it?" TemporalOrderingPressure
answers "does this owner expose an implicit state machine?" Superfluous State
answers the natural next question: **"could this field simply be removed?"**

Most codebases accumulate fields that are not really state at all. They are
transit data that happens to be stored in an ivar because the developer
needed to pass a value between two methods and an ivar was the path of least
resistance. The field looks like state -- it lives on the object, it persists
between calls -- but it's actually a local variable that escaped its method
body.

This detector finds those fields and ranks them by eliminability.

## What it detects

### Pattern 1: Intra-method pass-through (eliminable with near-certainty)

A field that is **written and read within the same method body**. The value
never escapes the stack frame. The ivar is purely a local variable that was
promoted for no reason.

```ruby
def checkout(user, cart)
  @total = cart.items.sum(&:price)  # <-- written
  charge(user, @total)              # <-- read
  @total                            # <-- read again
end
```

`@total` is written once, read twice, all inside `checkout`. No other method
ever touches it. It should be a local variable `total`. Detection requires
zero opinion -- the writer span and reader spans are all within the same
DEFN boundary.

### Pattern 2: Adjacent-call pass-through (eliminable with high confidence)

A field with **exactly one writer method and exactly one reader method**,
where every observed call site places the writer immediately before the
reader.

```ruby
class BillingService
  def set_user(user)
    @user = user          # <-- only writer
  end

  def validate
    return unless @user   # <-- only reader
  end
end

# Every observed call site:
# service.set_user(u)
# service.validate
```

`@user` is transit data: `set_user` produces it, `validate` consumes it. It
can be eliminated by converting `set_user` to return the value and `validate`
to accept it as a parameter: `user = acquire_user(...); validate(user)`.

False positives can occur when the writer genuinely mutates object state that
other methods depend on. This is guarded by the "exactly one reader" and
"adjacent calls" constraints. If `@user` is read in three other methods, or
if calls are not consistently adjacent, the score drops below the report
threshold.

### Pattern 3: Derived cache (eliminable with medium confidence, user-gated)

A field that is computed from other fields and never independently mutated.
Its value is always derivable from the source fields.

```ruby
def initialize(cart)
  @cart = cart
  @total = @cart.total        # <-- derived, never written elsewhere
end
```

`@total` is a cache of `@cart.total`. It can be eliminated by recomputing on
read. The tradeoff depends on recomputation cost: `@cart.total` with a
10,000-item collection is different from `@user.name`. This detector flags
derived caches and leaves the recomputation decision to the human.

## Score formula

For each field, compute:

```
eliminability_score =
  (1.0 / max(1, reader_method_count))   ×  # fewer reader methods = easier to eliminate
  (1.0 / max(1, writer_method_count))   ×  # fewer writer methods = fewer refactor sites
  intra_method_bonus                     ×  # × 10 if all reads and writes are in the same method
  adjacent_call_bonus                    ×  # × 5 if writer-reader is adjacent at every callsite
  (1.0 - rederivation_penalty)               # penalize if this field gates other re-derivations
```

### Terms

| Term | Range | Definition |
|---|---|---|
| `reader_method_count` | ≥ 1 | Number of distinct (file, defn) pairs that **read** this field |
| `writer_method_count` | ≥ 1 | Number of distinct (file, defn) pairs that **write** this field |
| `intra_method_bonus` | 1.0 or 10.0 | 10.0 if all reads AND writes are in the same method body; 1.0 otherwise |
| `adjacent_call_bonus` | 1.0 or 5.0 | 5.0 if writer_method_count == 1 AND reader_method_count == 1 AND every callsite sequence is writer-then-reader adjacent; 1.0 otherwise |
| `rederivation_penalty` | 0.0 -- 1.0 | Fraction of re-derivation sites that depend on this field. If this field is an input to N re-derivations out of total T tracked re-derivations, penalty = N / T (capped at 1.0). Gives a weight penalty for "this field's value is used to derive other computed state." |

### Thresholds

| Score range | Classification | Action |
|---|---|---|
| > 0.5 | Almost certainly eliminable | Remove the field; convert to local variable or parameter |
| 0.1 -- 0.5 | Probably eliminable with moderate refactor | Adjust call signatures, inline the write |
| < 0.1 | Genuinely stateful or gating complex re-derivations | Do not report (below noise floor) |

**Only scores > 0.1 are reported.** This avoids surfacing fields that are
legitimate persistent state.

## Relationship to other metrics

| Metric | Question | Superfluous State adds |
|---|---|---|
| StateMesh | "Where is state and how messy?" | "Which fields don't need to exist at all?" |
| TemporalOrderingPressure | "Does this owner expose an implicit state machine?" | "Can we eliminate the fields that create the machine?" |
| DecisionPressure | "Which contracts drive defensive code?" | "Can removing a field reduce contracts that need defending?" |

StateMesh and TemporalOrderingPressure show the *problem*. Superfluous State
shows the *fix*.

## Implementation

### Input facts

All required facts already exist in Decomplex. Superfluous State is a
**post-analyzer** -- it reads StateMesh and ImplicitControlFlow output,
scores each field, and emits a ranked list. No new AST walks.

| Fact | Source | Needed for |
|---|---|---|
| Field read sites (per file, defn, line) | `StateMesh#reads` | `reader_method_count` |
| Field write sites (per file, defn, line) | `StateMesh#writes` | `writer_method_count` |
| Method boundaries (DEFN/DEFS spans) | `StateMesh` AST root | `intra_method_bonus` |
| Re-derivation chains | `StateMesh#re_derivations` | `rederivation_penalty` |
| Call adjacency per field pair | `ImplicitControlFlow` sequences | `adjacent_call_bonus` |
| Field names (normalized) | `StateMesh` known fields | Identity |

### Phases

**Phase 1: Group reads and writes by field.**

For each normalized field name in StateMesh:
- Collect all `Write` sites into `writers = Map<(file, defn) → [Write]>`
- Collect all `Read` sites into `readers = Map<(file, defn) → [Read]>`
- Compute `writer_method_count = writers.keys.uniq.size`
- Compute `reader_method_count = readers.keys.uniq.size`

**Phase 2: Detect intra-method pass-through.**

A field is intra-method if `writer_method_count == 1` AND
`reader_method_count == 1` AND the single writer and single reader
(file, defn, line) spans are both within the same DEFN/DEFS body.

Implementation: StateMesh already tracks file and defn per site.
Compare the `defn` field of the writer and reader. If they match and
the total read count within that defn >= 1, the field is intra-method
pass-through.

**Phase 3: Detect adjacent-call pass-through.**

A field is adjacent-call pass-through if:
- `writer_method_count == 1` AND `reader_method_count == 1`
- NOT intra-method (distinct methods)
- For every `ImplicitControlFlow::MethodSequence` that contains the
  writer method: the reader method immediately follows it in the
  observed call order.

Adjacency is directional: `set_user → validate` is adjacent; `validate
→ set_user` is not. If at least one callsite reverses the order
(reader before writer), the field does NOT qualify for the
adjacent-call bonus.

If no callsites are found for the pair (the writer is tested alone or
called from unknown sites), the bonus is NOT applied -- adjacency
cannot be proven. This is the conservative default.

**Phase 4: Compute re-derivation penalty.**

A field gates re-derivations if it appears as an input in StateMesh
re-derivation chains. For each re-derivation:
- If `re_derivation.field == this_field`, count it.
- `rederivation_penalty = this_field_rederivations / max(1, total_rederivations)`

This prevents flagging a field like `@storage` that feeds 12 other
derived fields as "eliminable."

**Phase 5: Score and rank.**

Apply the formula above for each known field. Sort descending by score.
Emit only fields with score > 0.1.

### Output schema

```ruby
{
  field: "@total",                  # ivar name
  normalized: "total",              # without @ prefix
  score: 0.92,                      # eliminability score
  classification: "intra_method",   # "intra_method" | "adjacent_call" | "derived_cache"
  writer_method_count: 1,
  reader_method_count: 1,
  write_sites: [                    # all write locations
    { file: "app/services/billing.rb", defn: "checkout", line: 4 }
  ],
  read_sites: [                     # all read locations
    { file: "app/services/billing.rb", defn: "checkout", line: 5 },
    { file: "app/services/billing.rb", defn: "checkout", line: 6 }
  ],
  rederivations_gated: 0,           # how many re-derivations depend on this field
  adjacent_callsites: nil,          # for adjacent_call patterns: [caller, callee, file, line]
  recommendation: "Replace @total with a local variable in checkout."
}
```

### Test fixtures

**Fixture A: Intra-method pass-through**

```ruby
class Example
  def checkout(cart)
    @total = cart.total            # write
    format(@total)                 # read
  end
end
```

Expected: `@total` score > 0.5, classification `intra_method`.

**Fixture B: Adjacent-call pass-through**

```ruby
class Billing
  def set_user(user)
    @user = user
  end

  def validate
    return unless @user
    charge(@user)
  end

  def process
    set_user(find_user)
    validate
  end
end
```

Expected: `@user` score > 0.5, classification `adjacent_call`,
`adjacent_callsites` includes `process` line.

**Fixture C: Adjacent-call with reversed order (NOT eliminable)**

```ruby
class Billing
  def set_user(user)
    @user = user
  end

  def validate
    return unless @user
  end

  def process
    validate           # reader BEFORE writer -- order is reversed
    set_user(find_user)
  end
end
```

Expected: `@user` score < 0.1 (no adjacent-call bonus, reader not
adjacent after writer), **NOT reported**.

**Fixture D: Derived cache**

```ruby
class Cart
  def initialize(items)
    @items = items
    @total = items.sum(&:price)   # derived from @items
  end
end
```

Expected: `@total` score 0.1--0.5, classification `derived_cache`.

**Fixture E: Genuine state (NOT reported)**

```ruby
class Cart
  def initialize
    @items = []
  end

  def add(item)
    @items << item                 # multiple writers
    @total = @items.sum(&:price)
  end

  def remove(item)
    @items.delete(item)            # multiple writers
    @total = @items.sum(&:price)
  end

  def empty?
    @items.empty?                  # multiple readers
  end

  def total
    @total                         # multiple readers
  end
end
```

Expected: `@items` and `@total` both score < 0.1 (`writer_method_count` and
`reader_method_count` are both > 1), **NOT reported**.

## Language portability

This metric is fully language-agnostic. Every language has fields/properties/
members/ivars with write sites and read sites. The facts are:

- **Field identity**: name within owner
- **Writer locations**: (file, function, line)
- **Reader locations**: (file, function, line)
- **Call adjacency**: (caller, callee, file, line)
- **Re-derivation dependency**: field X is an input to derived field Y

None of these are Ruby-specific. The TreeSitter fact extraction layer
(`syntax/<lang>.rs`) needs to emit `StateWrite`, `StateRead`, and
`CallSite` facts per language. Superfluous State, like StateMesh and
TemporalOrderingPressure, consumes those language-agnostic facts.

## Non-goals

- **Do not** recommend refactoring actions. The detector says "this field
  is probably eliminable." The human decides whether to inline it, convert
  it to a return value, or keep it.
- **Do not** compute recomputation cost for derived caches. Flag them,
  let the user decide.
- **Do not** attempt cross-file call adjacency. Adjacent-call detection
  is intra-file only (same as ImplicitControlFlow's current scope).
- **Do not** analyze initialization-only fields differently. A field
  written in `initialize` and read once can be pass-through if the read
  is in a single-adjacent-call method. But `initialize` → caller is
  implicit; the adjacent-call bonus does not apply across an
  initialization boundary unless the caller method directly follows
  construction in observed sequences.
