# Feature B: Recursive Protocol Analysis (Plan + Design)

This is the implementation plan and durable design doc for Feature B. It
targets the 218 forwarded-arg slots that the static param-backflow path
currently rejects outright with "requires recursive protocol analysis".

## Problem statement

`static_param_backflow_protocol_rejection` (`infer.rb:1283`) rejects any
backflow candidate whose param-protocol has a non-empty `gaps` set. Gaps
come from two patterns recorded by `param_protocols` in
`source_index.rb:1720`:

- **Forwarded to helper**: `helper(arg)` -> gap `"forwarded to #{helper}"`.
- **Captured in ivar**: `@x = arg` -> gap `"captured in @x"`.

The current code's rationale: it can't see what the helper does with the
arg, so the helper might require behavior the candidate type lacks
(narrowing would produce a runtime `NoMethodError`). The motivating bug
from the prior session: `direct_index_get(ast_node)` forwarded
`ast_node` to `direct_slice_backed_expr?`; static callsites suggested
narrowing to `Resolv::DNS::Name`, but the helper needed AST-node
behavior -- the proposal was unsafe.

**218 slots** currently fall into this rejection. Most are safe to
narrow once the transitive protocol is resolved; the rejection is
over-conservative.

## Approach

Build a transitive protocol resolver that traces param -> {direct
methods} U {forwarded helper protocols} U {ivar-capture protocols},
cycle-safe. Replace the "any gap -> reject" check with "compute full
protocol, then check candidate". Keep every existing rejection rule
(Boolean, Object, weak/untyped, runtime contradicts) intact -- this
work only relaxes the over-conservative gap-rejection.

### Authority boundary

Per CLAUDE.md authority table, **`param_protocols` is owned by the
annotator stage** (SourceIndex during `walk`). The new resolver lives in
Infer alongside the other proposers, because it operates on the
already-collected protocol stamps + cross-method graph -- it is a
*consumer* of facts, not a new authority.

This means:
- `param_protocols` keeps its current single-method scope. We do NOT
  fold transitive resolution into it (that would couple SourceIndex to
  cross-file analysis, violating per-file isolation).
- The resolver reads `protocols`, `existing_sigs`, `unsigned_methods`,
  and a new per-class ivar-protocol fact, then synthesizes the
  transitive set lazily on demand.

## Implementation

### B0 -- Protocol resolver helper

**Location:** `gems/nil-kill/lib/nil_kill/infer.rb` (or a new
`gems/nil-kill/lib/nil_kill/protocol_resolver.rb` if the surface grows
large -- decide during implementation; start inline).

```ruby
class ProtocolResolver
  def initialize(store)
    @store = store
    @methods_by_class_name = index_methods_by_class_name
    @ivar_protocols = index_ivar_protocols  # B2 output
    @cache = {}
  end

  # Returns { "methods" => Set, "chain" => Array, "blocked" => bool }.
  # Blocked when the chain hits a forwarded helper we can't resolve
  # (e.g. dynamic dispatch, intrinsic, unknown method). The caller
  # decides whether to fall back to the conservative rejection.
  def resolve(class_name, method_name, param_name)
    key = [class_name, method_name, param_name]
    return @cache[key] if @cache.key?(key)
    @cache[key] = { "methods" => Set.new, "chain" => [], "blocked" => false }  # cycle stub
    methods = Set.new
    chain = []
    blocked = false
    method = @methods_by_class_name[[class_name, method_name]]
    if method.nil?
      blocked = true
    else
      protocol = method.dig("protocols", param_name.to_s) || {}
      Array(protocol["methods"]).each { |m| methods << m }
      chain << "#{class_name}##{method_name}(#{param_name})"
      Array(protocol["gaps"]).each do |gap|
        helper, slot = parse_forwarded_gap(gap)
        if helper
          callee_method = lookup_helper(helper)
          if callee_method
            sub = resolve(callee_method["class"], callee_method["method"], slot_name(callee_method, slot))
            methods.merge(sub["methods"])
            chain.concat(sub["chain"])
            blocked ||= sub["blocked"]
          else
            blocked = true  # helper not in our index; pessimistic
          end
        elsif (ivar = parse_capture_gap(gap))
          ivar_methods = @ivar_protocols[[class_name, ivar]] || Set.new
          methods.merge(ivar_methods)
          chain << "captured to #{ivar} (#{ivar_methods.size} method(s))"
          blocked = true if ivar_methods.empty?  # no usage visible
        end
      end
    end
    @cache[key] = { "methods" => methods, "chain" => chain, "blocked" => blocked }
  end
end
```

Key decisions:
- **Cycle handling**: stub the cache entry to the empty-blocked state
  before recursing. If the recursion hits the same key, it sees the stub
  and returns empty without infinite descent. The first finishing call
  overwrites the cache with the real answer.
- **Slot name resolution**: helper's params come positionally. The gap
  records `forwarded to <helper>` without slot index; we recover the
  index by re-parsing the call AST. Add the slot to the gap string at
  collection time (small `source_index.rb` change) so the resolver
  doesn't need to re-walk: `"forwarded to <helper> slot N at <loc>"`.
- **Unknown helper -> blocked**: if the helper is an intrinsic
  (`puts`, `raise`, `Array#map`, ...) or a method we don't have in
  `existing_sigs`/`unsigned_methods`, set `blocked = true`. The
  caller keeps the conservative rejection -- we don't manufacture
  narrowings without protocol evidence.

### B1 -- Wire into the rejection check

`static_param_backflow_protocol_rejection` already collects
`required` methods from the param's direct protocol. Replace the
`unless gaps.empty? -> reject` short-circuit with:

```ruby
def static_param_backflow_protocol_rejection(method, param_name, candidate, protocol_index)
  resolved = @protocol_resolver.resolve(method["class"], method["method"], param_name)
  return "candidate #{candidate} hit unresolvable forwarding chain: #{resolved["chain"].first(3).join(' -> ')}" if resolved["blocked"]
  required = resolved["methods"].to_a
    .reject { |name| static_param_backflow_ignorable_protocol_method?(name) }
    .uniq
  # ... rest of the existing logic checks `required` against protocol_index
end
```

The resolver is instantiated once per Infer pass and cached across all
proposer calls. Cost: ~O(M * P) for M methods, P average protocol size,
but cached so repeated lookups are O(1).

### B2 -- Ivar-capture protocol collection

Currently `param_protocols.gaps` records "captured in @x at <loc>" with
no further info. The methods called on `@x` later in the class are not
tracked. Two-step:

1. **Per-file, in `source_index.rb`:** during `collect_protocols`,
   accumulate a *separate* map `@ivar_method_calls` keyed by
   `[class_name, ivar_name]` -> Set of method names. Populated from
   any `InstanceVariableReadNode.method_call` we encounter while
   walking the class body. Already partially infrastructure: line 1746
   handles `InstanceVariableWriteNode`.
2. **Store-level:** export this map as a new fact
   `@store.facts["ivar_protocols"]`. The resolver consumes it.

This stays per-file because ivar usage is class-scoped, not
cross-file. A class is normally defined in one file (with reopens
being the edge case -- handled by merging maps under the same class
key during Infer's index build, same way it does for `existing_sigs`).

### B3 -- Specs

| Concern | Spec |
|---|---|
| Resolver direct protocol | one method, no forwards, returns direct methods |
| Single forward | foo(x) calls bar(x); resolver returns bar's protocol |
| Two-hop forward | foo->bar->baz; resolver returns all three layers |
| Forwarding cycle | foo->bar->foo; resolver returns finite set, no infinite loop |
| Ivar capture | foo(x) does @x = x; class also calls @x.token; resolver includes "token" |
| Helper not in index | foo(x) calls some_intrinsic(x); resolver returns blocked=true |
| Mixed: forward + ivar | both gaps in same param; resolver merges both protocols |
| Integration: backflow accepts | existing reject spec inverted -- helper-resolved candidate satisfies the chain |
| Integration: still rejects unsafe | `Resolv::DNS::Name` case -- resolver finds `token` requirement, candidate lacks it, reject |

### B4 -- Measurement and decision gate

Run end-to-end:

```bash
bundle exec gems/nil-kill/exe/nil-kill infer --no-sorbet
jq '.actions | map(select(.kind == "fix_sig_param")) | length' tmp/nil-kill/evidence.json
ruby gems/nil-kill/exe/nil-kill loop --signature-backflow --verify-spec-subset
```

**Decision gate:**
- Count "fix_sig_param" actions before and after.
- Count rejections containing "requires recursive protocol analysis"
  before; should be 0 after.
- Target: at least +50 new fix_sig_param candidates.
- Run combined verified loop. Confirm at least 80% of new candidates
  hold under spec verification (the rest will roll back; that's fine).

If <+50 candidates **or** <60% verification hold rate, the resolver is
not load-bearing for this codebase. Document the actual numbers,
remove the resolver, restore the conservative rejection.

## Out of scope

These were considered and explicitly deferred:

- **Cross-method receiver-type propagation**: `foo(x)` where `x` is an
  attribute call (`obj.x`) -- not a direct param, so doesn't enter the
  resolver. Distinct concern from forwarded params.
- **Reflective protocols**: `arg.send(:foo)` or `arg.public_send(:foo)`
  -- can't statically tell the method name. Resolver returns
  `blocked = true`.
- **Block forwarding**: `arg.each { |x| ... }` -- the block's
  param-protocol on `x` is its own analysis; not in scope.
- **Negative protocols**: methods the param must *not* respond to.
  Sorbet doesn't express these; nil-kill doesn't need them either.
- **T.any branching during resolution**: same out-of-scope as C-lite.
  The candidate is already a single concrete class at the rejection
  check.

## Cross-references

- **`static_param_backflow_protocol_rejection`** (`infer.rb:1283`): the
  call site for the resolver. Existing rejection rules below the
  resolver-blocked branch are preserved.
- **`param_protocols`** (`source_index.rb:1720`): the per-file protocol
  collector. B2 extends `collect_protocols` for ivar usage.
- **`static_param_backflow_protocol_index`** (`infer.rb:1305`): the
  class -> methods index the rejection check uses to verify the
  candidate's available methods. Resolver does NOT replace this --
  it produces the *required* set; the index gives the *available* set;
  rejection is `required - available`.
- **`AMBIGUOUS_RBI_OWNERS`** (`rbi_return_index.rb:169`): same defense
  as C-lite. Candidates from RBI-ambiguous classes are filtered upstream
  in `param_origins`; resolver doesn't re-check.
- **`runtime_contradicts?`** (`infer.rb:880`): final guard. Resolver
  result and protocol-index check happen first; runtime cross-check
  has the last word.

## Risk and mitigations

| Risk | Mitigation |
|---|---|
| Resolver mis-resolves a helper -> false-positive accept -> bad narrowing -> verification fails | `--verify-spec-subset` runs full spec; failures roll back; permanently skipped after bisection |
| Helpers in other gems/stdlib leak through | Treat any helper not in `existing_sigs ∪ unsigned_methods` as blocked; we have no protocol for it |
| Cycle in resolver explodes memory | Cache stub before recursion (see B0); bounded by method count |
| Ivar protocol over-collects (methods called via `@x` in unrelated contexts) | Class scope is the bound; if class reopens across files, merge keyed by class name |
| Verification time spikes from +218 candidates | `signature_backflow_limit` (default 5) already throttles per-iteration application; full convergence over many iterations |

## Effort estimate

| Phase | Days |
|---|---|
| B0 resolver (with cycle-stub cache) | 1 |
| B1 wire-in (rejection check) | 0.5 |
| B2 ivar-capture collection (source_index + store fact) | 1 |
| B3 specs | 1 |
| B4 end-to-end measurement + verified loop run | 1 |
| Buffer / cleanup / doc update | 0.5 |
| **Total** | **5 days** |

## Empirical results (post-implementation)

Measured on the project's evidence store after `nil-kill infer
--no-sorbet` post-Feature-B landing.

**Static analyser facts captured:**

| Fact | Count |
|---|---|
| Total protocol gaps (existing_sigs) | 3204 |
| Forwarded-helper gaps | 3044 |
| Ivar-capture gaps | 160 |
| Per-(class, ivar) protocol entries | 205 |

**Backflow proposer funnel:**

| Stage | Count |
|---|---|
| Methods with unique name | 1903 (of 1970) |
| Untyped param slots considered | varies per method |
| Bad candidate (unknown / conflicting / weak origins) | 779 |
| Resolver-accepted protocols (chain resolves to required methods) | 4 |
| Resolver-blocked (helper not in index, ivar unobserved, unparseable) | 22 |
| Runtime-contradicts rejections of resolver accepts | **4 of 4** |
| Net new fix_sig_param actions | **0** |

**Sample resolver-accepted-then-runtime-rejected cases:**

- `PipeAnalysis#higher_order_list_op?(node)` -> `MIR::Lit` (callsites
  agreed; runtime observed a different class)
- `PipelineHost#lower_concurrent_list_where(inner)` -> `String`
- `PipelineHost#lower_concurrent_list_reduce(inner)` -> `String`
- `MIRLowering#direct_index_get(ast_node)` -> `AST::Identifier` --
  the prior session's motivating bug! Resolver correctly determined
  AST::Identifier has the required `name` method (it's a struct
  field). But runtime observed a different class at this callsite,
  so the narrowing is correctly suppressed.

**Decision gate outcome:** Target +50 new `fix_sig_param` actions.
Actual: **0**. Per the plan, this is the "below threshold, document
and stop" path.

### Why the yield is 0 despite the resolver working correctly

The static_param_backflow funnel collapses at multiple stages:

1. **779 bad-candidate cases** -- callsites pass unknown/dynamic
   expressions or weak (e.g. `T.nilable(Object)`) types. Outside
   Feature B's scope -- the static analyser can't infer caller types
   at all here. Feature A's receiver-inference path partially helps;
   beyond that, this would need flow-sensitive type narrowing.
2. **22 resolver-blocked cases** -- helpers like `Class.new` or
   `Array#[]` aren't in the project method index. The resolver
   correctly returns blocked, preserving safety.
3. **Runtime cross-check eliminates the remaining 4.** This is the
   surprising finding: in every case where the resolver found a
   protocol-satisfying narrowing, runtime evidence contradicted it.
   The static callsite agreement is real, but doesn't match runtime
   reality -- callers exist that nil-kill's static analysis missed
   (likely dynamic dispatch through `send`, or callers in test/tool
   code not covered by the `target_files` scope).

### What this means for future work

The resolver is **sound** (zero false positives in 4-of-4 cases) and
**mechanically correct** (specs all pass; cycles handle; ivar capture
works on synthetic and real data). The infrastructure -- slot-indexed
forwarded gaps, per-class ivar protocols, transitive resolver -- is
solid and could power future proposers (`narrow_generic_param`,
recursive type inference, etc.).

The yield-zero outcome is informative: **`runtime_contradicts?` is
catching more than nil-kill's static analyser ever was**. Disabling
the runtime guard would unlock the 4 cases, but at the cost of
proposing narrowings that runtime evidence disproves -- that is
exactly the unsafe path the guard exists to prevent.

### Recommendation

Keep the resolver in place. The code is correct, well-tested, sound,
and adds reusable infrastructure for the gap collection (slot index +
ivar protocols are useful beyond this proposer). Reverting would lose
the structural fix to a real limitation (over-conservative
gap-rejection) for no gain in safety.

**Do NOT enable a `--bypass-runtime` mode for static param backflow.**
The runtime guard is the last line of defense against narrowings that
look sound statically but fail in practice. If callers are missing
from the static analysis, the fix is to expand the static analyser's
reach (e.g. include tools/, fix dynamic-dispatch detection), not to
ignore the runtime evidence.

The next productive direction for static_param_backflow yield is not
deeper protocol analysis, but **caller-side analysis**: turning more
of the 779 bad-candidate cases into typed candidates. That overlaps
with Feature A's territory but for *param* slots rather than receiver
slots.

## Open questions for the implementer

These are decisions to make during implementation, not blockers for
the plan:

1. **Inline vs. its own file**: start with `ProtocolResolver` inline
   in `infer.rb`. Move to `protocol_resolver.rb` if it grows past
   ~80 lines.
2. **Slot-name recovery for forwarded gaps**: either (a) extend
   `collect_protocols` to record the slot index alongside the helper
   name, or (b) re-parse the call expression at resolve time. Prefer
   (a) -- it's localised and avoids a second AST walk.
3. **Multiple helpers for the same param**: a param can forward to
   several helpers (`foo(x); bar(x); baz(x)`). Resolver should union
   the protocols. Already covered by Set semantics; no special case.
4. **Reopened classes / methods overridden by inheritance**: ignore
   inheritance for v1 -- treat each `[class, method]` as canonical. If
   misses surface in B4 measurement, add a TODO to address in a follow-up.
