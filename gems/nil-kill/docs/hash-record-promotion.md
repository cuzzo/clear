# Hash Record Promotion Acceptance Criteria

Nil-kill should be able to turn high-pressure hashes that are acting as records into `T::Struct` definitions when the rewrite can be verified.

## Scope

The first complete milestone is hash records. Tuple-like arrays and generated interfaces for arbitrary metaprogramming are separate milestones.

## Acceptance Criteria

1. A high-pressure hash record candidate can produce a concrete rewrite action with:
   - struct name
   - required and optional fields
   - field types
   - producer rewrites
   - consumer read rewrites
   - signature rewrites
   - safety blockers

2. The rewriter handles straightforward producer flows:
   - local hash literals
   - method returns
   - arrays of hash literals
   - hash records flowing through params
   - hash records flowing through instance variables or struct fields when provenance is known

3. The rewriter handles straightforward consumer reads:
   - `record[:field]`
   - `record["field"]`
   - `record.fetch(:field)`
   - `record.fetch("field")`

4. Optional keysets are preserved. If one shape has `{name, id}` and another has `{name, id, email}`, `email` must become nilable or otherwise optional in the generated struct.

5. Unsafe cases are reported as blockers, not silently rewritten:
   - dynamic keys
   - missing keys
   - post-construction mutation
   - `merge!`, `update`, `delete`, or other shape-changing operations
   - incompatible observed field types that would force broad `T.untyped`

6. Signature rewrites are applied when the flow is known:
   - `T::Hash[Symbol, T.untyped]` return slots can become the generated struct
   - `T::Hash[Symbol, T.untyped]` param slots can become the generated struct
   - `T::Array[T::Hash[Symbol, T.untyped]]` slots can become `T::Array[GeneratedStruct]`

7. The verified auto-fix loop must either:
   - apply the candidate, run the configured verifier, and keep the rewrite when it passes; or
   - restore the original files and report why the candidate was rejected.

8. The report should improve after a successful rewrite:
   - pressure for the rewritten hash-record cluster drops
   - weak or untyped collection slots drop when signatures were rewritten
   - return hygiene improves when collection lookup returns become typed struct accessors

## Implementation Action Items

- CST-based rewriting: replace `Apply#apply_one` regex/string substitutions for hash-record promotion with Prism-location-based edits. Nil-kill already depends on Prism, so producer rewrites, consumer read rewrites, signature rewrites, and struct insertion should be computed from parsed node locations instead of ad hoc line matching.
- Node matching: current rewrites use Prism node locations plus source slices. This is substantially safer than regex rewriting, but identical expressions repeated on the same line remain a known fragile edge case. The verified loop is expected to catch these by rolling back failed candidates.
- T.let feedback loop: nil-kill records existing and candidate `T.let` sites and can narrow them, but runtime `T.let` observations are not yet fed back into method return inference, param inference, or hash-record pressure ranking. A future pass should compare injected `T.let` candidates against runtime observations and downgrade or correct inferred types before reporting.

### T.let Feedback Loop Gap

Current behavior:

- `T.let` hook observations feed existing `T.let` narrowing.
- They do not currently correct inferred method return types.
- They do not currently correct inferred param types.
- They do not currently affect hash-record pressure ranking.

Desired behavior:

1. Static inference proposes a candidate type, such as `String`.
2. The instrumented run injects or observes `T.let(value, String)`.
3. Runtime observation sees the actual flow, such as `NilClass`.
4. Nil-kill downgrades, nilabilizes, or blocks that candidate before reporting or autofix.

That validation loop is not implemented yet.

## Test Coverage

Current coverage:

- local hash literal promotion: covered
- return-to-consumer promotion: covered
- param promotion: covered
- array element promotion: covered
- optional keysets: covered
- `fetch` rewrites: covered for `fetch(:key)` and `fetch("key")`
- dynamic key blockers: covered
- mutation blockers: covered
- cross-file cluster promotion: covered
- failed verification rollback: covered

## Good Enough

This milestone is good enough when nil-kill can safely rewrite common high-pressure hash records into `T::Struct`s under verification, and can explain why the remaining candidates are blocked.

At that point the docs may claim that nil-kill can identify high-pressure hash records acting as structs and rewrite verified straightforward producer/consumer flows into `T::Struct`s.

The docs should not claim general metaprogramming interface synthesis until a later milestone implements and verifies that separately.
