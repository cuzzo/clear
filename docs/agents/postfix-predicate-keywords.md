# Postfix Tense Predicates: State-of-the-Art Review and Recommendation

Status: Design review
Scope: `EXISTS`, `IS_OK`, `IS_READY`, conditional binding, and the `AND` / `OR` / `OR_ELSE` migration
Reviewed against: CLEAR, Rust, Swift, Kotlin, and Zig as of 2026-07-12

## Executive recommendation

The narrow idea is good: adopt postfix, non-consuming, `Bool`-valued tense predicates for state inspection.

```clear
maybe_user EXISTS
parse_user(input) IS_OK
```

This reads naturally, keeps predicate results independent of payload truthiness, and is close to proven Rust and Kotlin APIs. Bare `IF optional` and bare `IF fallible` should remain illegal.

The revised design decisions are:

1. Replace `&&` and `||` with `AND` and `OR`. The symbolic spellings become fixable errors.
2. Rename the current optional/fallible fallback operator from `OR` to `OR_ELSE`, including control forms such as `OR_ELSE RAISE`.
3. Allow `Bool`, and optionally `?T` where `T != Bool`, as Boolean-expression operands. An optional non-Boolean means presence (`EXISTS`). Reject implicit `?Bool` participation because presence and payload truth are both plausible.
4. Replace `IF optional AS value` with the more explicit `IF optional EXISTS AS value`. This is clearer at the call site, but it must be specified as a fused conditional refinement—not as ordinary `Bool AS value` composition.
5. Retain `IS_READY`, with a contract tied directly to `NEXT`: it means that `NEXT` can produce an outcome without waiting. It says nothing about success. `IS_READY AS` remains illegal.

Recommended surface:

```clear
# State inspection: ordinary Bool expressions.
present = maybe_user EXISTS;
succeeded = parse_user(input) IS_OK;
ready = work IS_READY;

# Optional capture: explicit conditional refinement.
IF maybe_user EXISTS AS user THEN print(user.name); END

# General variant capture: one pattern mechanism for all sum types.
IF parse_user(input) IS Ok(user) THEN print(user.name); END

# A future is settled independently of its output.
IF work IS_READY THEN
    outcome = NEXT work;                 # nonblocking now; consumes/observes once
    IF outcome IS Ok(user) THEN print(user.name); END
END

# Logical and fallback operators are now lexically distinct.
can_run = configured AND enabled;
name = maybe_name OR_ELSE "anonymous";
```

## 1. What CLEAR already establishes

CLEAR currently has three relevant rules that this proposal deliberately migrates:

- `IF optional AS payload` conditionally captures an optional payload; this becomes `IF optional EXISTS AS payload`.
- `OR` extracts an optional/fallible value with a fallback, while `OR_ELSE RAISE` propagates failure; these become `OR_ELSE` and `OR_ELSE RAISE`.
- `&&` and `||` perform Boolean conjunction/disjunction; these become `AND` and `OR`.
- `NEXT future` is the operation that obtains a future's output.

The postfix proposal should fill the missing **inspection-only** role. It should not create a second payload-extraction mechanism with subtly different ownership, evaluation, or tense-peeling rules.

This distinction supports CLEAR's goals:

- Local reasoning: the source says whether it inspects, extracts, waits, or falls back.
- Low global complexity: predicates do not need hidden payload-binding behavior.
- Maximum safety: a wrapped `false` is never confused with an absent or failed outcome.
- Near-C performance: each predicate is a tag test; it allocates nothing and does not copy a payload.

## 2. Comparison with state of the art

| Concern | Rust | Swift | Kotlin | Zig | Recommended CLEAR |
| --- | --- | --- | --- | --- | --- |
| Optional state test | `option.is_some()` | `x != nil` | `x != null` | `x != null` | `x EXISTS` |
| Optional test + bind | `if let Some(x) = value` / `let else` | `if let x` / `guard let x` | null check + smart cast, or `?.let` | `if (x) |value|` | `IF x EXISTS AS value` |
| Success state test | `result.is_ok()` | pattern-match `Result.success` | `result.isSuccess` | error-union `if` capture | `result IS_OK` |
| Success test + bind | `if let Ok(x) = result` / `match` | `switch` / `case .success(let x)` | `fold`, `getOrNull`, or explicit result APIs | `if (result) |value| ... else |err|` | `IS Ok(value)` pattern |
| Completion observation | Raw `Future` exposes `Poll`, normally use `.await`; no general safe `is_ready()` | task `result` is async and waits | `Deferred.isCompleted` | no comparable core tense predicate | optional `future IS_READY` |
| Obtain async output | `.await` | `await task.value` / `await task.result` | `await()` | runtime/library-specific | `NEXT future` |

### Rust

Rust strongly validates the separation between state inspection and destructuring. `Option::is_some` and `Result::is_ok` return Boolean state, while `if let` and `match` bind payloads. The standard library also offers payload-aware predicates such as `is_some_and`, but those still return only `bool`. [Rust `Option` documentation](https://doc.rust-lang.org/std/option/) and [Rust `Result` documentation](https://doc.rust-lang.org/std/result/enum.Result.html).

Rust does **not** give every future a convenient synchronous readiness property. `Future::poll` requires a pinned mutable receiver and a task context, returns `Poll::Pending` or `Poll::Ready(output)`, and must not be blindly polled again after completion. Normal user code awaits instead. [Rust `Future` documentation](https://doc.rust-lang.org/std/future/trait.Future.html).

Lesson for CLEAR: postfix predicates are sound, but payload capture should remain pattern/binding syntax, and future completion cannot be modeled as just another optional predicate unless CLEAR's runtime handle explicitly caches terminal state.

### Swift

Swift uses optional binding (`if let` and `guard let`) to test and extract in one structured operation; a plain `!= nil` performs inspection only. Its `Result` is an enum with `.success` and `.failure` cases and is handled using normal enum operations and pattern matching rather than a dedicated success-binding keyword. [Swift optional binding](https://docs.swift.org/swift-book/LanguageGuide/TheBasics.html) and [Swift `Result`](https://developer.apple.com/documentation/Swift/Result?changes=_2).

Swift's `Task.result` is asynchronous: accessing it waits for completion and then produces a `Result`. It is not a synchronous readiness probe. [Swift `Task.result`](https://developer.apple.com/documentation/swift/task/result).

Lesson for CLEAR: inspection and binding may both be ergonomic without pretending they are the same operator. Waiting for a task and inspecting a task must also remain distinct.

### Kotlin

Kotlin is the closest precedent for the proposed expression shape. Null checks yield `Boolean` and can enable a smart cast when the compiler proves the value stable. `Result.isSuccess` is a Boolean property. [Kotlin null safety](https://kotlinlang.org/docs/null-safety.html) and [Kotlin `Result.isSuccess`](https://kotlinlang.org/api/core/kotlin-stdlib/kotlin/-result/is-success.html).

`Deferred.isCompleted` returns true for every terminal outcome, including failure and cancellation; obtaining the value still requires `await`. [Kotlin `Job.isCompleted`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-job/is-completed.html) and [Kotlin `Deferred`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-deferred/).

Lesson for CLEAR: a readiness predicate is useful, but it must be documented as outcome availability—not success or payload truth.

### Zig

Zig makes conditional capture part of `if` syntax. An optional condition captures its payload; an error-union condition captures success and requires an `else` that can capture the error. Nested error-union/optional values peel one layer at a time. [Zig language reference: `if`](https://ziglang.org/documentation/master/#if).

Lesson for CLEAR: outside-in tense peeling is correct, and a single structured capture mechanism scales better than adding a binding form to every predicate.

## 3. Postfix placement

The postfix placement itself is defensible and recommended:

```clear
x EXISTS
x IS_OK
x IS_READY
```

The strongest rationale is not that the words are grammatically verbs or adjectives—`exists` is grammatically a verb—but that they form **subject-predicate clauses** and are pure observations. That rule is clearer:

> Operations that consume, copy, clone, acquire, or change how a value is accessed are prefix. Pure state observations are postfix.

This classifies future additions without arguing about English parts of speech:

```clear
COPY x                 # changes value production/ownership
CLONE x                # performs work
RESOLVE link           # obtains a strong reference
x EXISTS               # observes optional tag
x IS_OK                # observes fallible tag
future IS_READY        # observes whether NEXT can proceed without waiting
```

The compiler should reject predicates applied to the wrong tense. EASY mode must not weaken this rule.

## 4. Predicate semantics

All postfix predicates should have these invariants:

1. Evaluate the operand exactly once.
2. Return plain `Bool`.
3. Inspect only the outermost matching tense/tag.
4. Never inspect payload truthiness.
5. Never consume, copy, clone, retain, release, wait for, or mutate the payload merely to answer the predicate.
6. Preserve normal temporary cleanup after the predicate result is computed.
7. Cost one tag/state load and comparison, except where synchronization requires an acquire load for a shared future.

Therefore:

```clear
Some(false) EXISTS       # true
Ok(false) IS_OK          # true
None EXISTS              # false
Err(reason) IS_OK        # false
```

Negation and precedence must be explicit in the grammar. The recommended reading is:

```clear
NOT (x EXISTS)
NOT (result IS_OK)
```

If `NOT x EXISTS` is accepted, it must parse identically to `NOT (x EXISTS)`, never `(NOT x) EXISTS`. The formatter should insert parentheses until this is visually unquestionable.

## 5. `EXISTS AS` as conditional refinement

The surface form is clearer than today's implicit optional guard:

```clear
IF user EXISTS AS present_user THEN print(present_user.name); END
```

It tells a beginner all three relevant facts locally: `user` is optional, the branch is selected by presence, and the payload receives a scoped name. It also avoids Rust-style `Some(value)` vocabulary for the overwhelmingly common built-in optional case.

There is nevertheless a semantic issue the implementation must handle explicitly. The design states both:

- `x EXISTS` is an ordinary expression of type `Bool`; and
- `AS` aliases the expression immediately to its left, while `x EXISTS AS y` binds `y: T`.

These cannot all be true under ordinary expression composition. The expression immediately left of `AS` is `x EXISTS`, whose value and type are `Bool`. Ordinary `AS` would bind `y: Bool`.

### Required resolution

Define `EXISTS AS` as a conditional-only fused refinement form:

```clear
IF x EXISTS THEN log("present"); END
IF x EXISTS AS value THEN use(value); END
IF result IS Ok(value) THEN use(value); END
```

The AST should represent this directly:

```text
TenseGuard {
    operand,
    predicate: exists | is_ok,
    capture,
}
```

The guard evaluates `operand` exactly once. It tests the tag, and only on the matching path binds the original payload. The binding follows the source's ownership provenance: it aliases an lvalue/borrowed source and may own a payload moved from an owned temporary. It does not bind the predicate's Boolean result.

`EXISTS AS` must lower through the same pattern/refinement machinery as generalized matching. It must not create a second ownership, cleanup, or MIR path. Generalized patterns remain available for user-defined unions, without requiring `Some(value)` in ordinary optional code.

The language-wide rule should therefore be restated accurately:

> `AS` names the value selected by the immediately preceding binding or refinement construct. In `EXISTS AS`, the selected value is the optional payload—not the Boolean predicate result.

### Composition and scope

Refinement bindings compose safely through `AND`, which short-circuits left to right:

```clear
IF user EXISTS AS u AND u.enabled THEN use(u); END

# fal_res: !?Result
IF fal_res IS_OK AS maybe_res AND maybe_res EXISTS AS res -> use(res);
```

The binding is available to the right side of that `AND` and within the taken branch. It is unavailable in `ELSE` and after the conditional. Each guard peels exactly one outer tense:

```text
fal_res                          : !?Result
fal_res IS_OK AS maybe_res       : guard; maybe_res is ?Result on success
maybe_res EXISTS AS res          : guard; res is Result on success
combined guard                   : Bool; res is available in the branch
```

This is not a special nested-tense feature. `AND` already establishes left-to-right control-flow dominance; refinement facts produced by its left operand must enter the annotation scope of its right operand. Lowering is the ordinary short-circuit shape:

```text
if fallible is Ok(capture maybe_res):
    if maybe_res is Some(capture res):
        branch
```

The source expressions are each evaluated exactly once, no intermediate payload is copied or reference-counted merely for the guard, and cleanup follows the same ownership/provenance contract as the equivalent nested `IF` form.

Bindings under `OR` or `NOT` are not definitely established and must initially be rejected:

```clear
IF left EXISTS AS x OR right EXISTS AS y THEN use(x); END   # error: x is not definite
NOT (value EXISTS AS x)                                    # error: capture under negation
```

Do not add implicit phi-binding of names across `OR` until real programs justify the extra control-flow and ownership complexity.

## 6. `AND`, `OR`, and `OR_ELSE`

### Operator migration

| Old spelling | New spelling | Meaning |
| --- | --- | --- |
| `a && b` | `a AND b` | short-circuit Boolean conjunction |
| `a \|\| b` | `a OR b` | short-circuit Boolean disjunction |
| `optional OR_ELSE fallback` | `optional OR_ELSE fallback` | lazy optional fallback/extraction |
| `fallible OR_ELSE fallback` | `fallible OR_ELSE fallback` | lazy fallible recovery |
| `fallible OR_ELSE RAISE` | `fallible OR_ELSE RAISE` | error propagation |

The old spellings should produce fixable errors for one migration window, then become syntax errors. `OR_ELSE` must remain lazy: its right operand is evaluated only for `NIL`/error.

One value fallback collapses all immediately resolved failure/absence layers. In particular:

```clear
value: T = fallible_optional() OR_ELSE fallback;   # !?T -> T
```

The same fallback is used if the call fails or if it succeeds with `NIL`, and it is evaluated at most once. Requiring `... OR_ELSE fallback OR_ELSE fallback` would expose tense plumbing without adding intent. `OR_ELSE` never crosses a future (`~`) boundary; use `NEXT` first.

When failure and absence require different behavior, peel them explicitly:

```clear
IF fallible_optional() IS_OK AS maybe_value AND maybe_value EXISTS AS value ->
    use(value);
ELSE
    # Use CATCH or nested guards when the two non-value outcomes need
    # distinct behavior.
END
```

`?!T` is not a legal spelling. Fallible optional is canonically `!?T`.

### Boolean-compatible operands

The requested Boolean operator domain is:

| Operand type | Boolean interpretation |
| --- | --- |
| `Bool` | payload value |
| `?T`, where `T != Bool` | presence, exactly as `operand EXISTS` |
| `?Bool` | rejected as ambiguous |
| all other types | rejected |

This permits approachable presence combinations:

```clear
cached_user OR fetched_user       # true if either optional contains a user
enabled AND cached_user           # true if enabled and a cached user exists
```

It does introduce one deliberate asymmetry: bare `IF optional` remains illegal even though an optional can participate in `AND`/`OR`. The rationale is that an infix Boolean expression supplies a visible Boolean operation, while bare `IF optional` supplies no clue whether presence or payload truth was intended. The compiler and formatter should nevertheless recommend explicit `EXISTS` whenever it materially improves readability.

`AND` must use the same operand rules as `OR`. Giving only `OR` optional-presence coercion would be an arbitrary grammar/type-system inconsistency.

### The `?Bool` ambiguity

For `flag: ?Bool`, two meanings are reasonable:

```clear
flag EXISTS             # Is any Boolean present? Some(false) => true
flag OR_ELSE FALSE      # What Boolean value should NIL mean? Some(false) => false
```

Therefore this is a compile error:

```clear
flag OR_ELSE fallback
```

The diagnostic must offer intent-preserving alternatives:

```clear
flag EXISTS OR_ELSE fallback                 # presence semantics
(flag OR_ELSE FALSE) OR_ELSE fallback         # payload semantics, NIL defaults false
(flag OR_ELSE TRUE) OR_ELSE fallback          # payload semantics, NIL defaults true
```

`flag? OR_ELSE fallback` is **not** the default fix. In current CLEAR, postfix `?` is a forced optional unwrap and lowers to a checked unwrap; it can fail when the value is `NIL`. It is appropriate only when control-flow facts already prove presence, in which case the compiler may eliminate the check:

```clear
IF flag EXISTS THEN
    result = flag? OR_ELSE fallback;           # safe because presence is proven
END
```

Do not silently treat both `NIL` and `FALSE` as false. That discards a real state, makes `Some(false)` indistinguishable from absence, and conflicts with the invariant that `EXISTS` never examines payload truthiness.

### Generic composability

The `?Bool` rejection applies only to **implicit Boolean coercion**, not to fallback. Generic fallback remains closed over every `T`, including `Bool`:

```clear
FN fallback<T>(x: ?T, default: T) RETURNS T -> RETURN x OR_ELSE default; END
```

This resolves the earlier composability objection: `OR_ELSE` has one meaning for every wrapped payload type; only the convenience conversion from optional to Boolean needs disambiguation.

### Precedence

Recommended precedence, tightest to loosest:

1. postfix predicates and unwrap/navigation;
2. comparisons;
3. `AND`;
4. `OR`;
5. `OR_ELSE`;

Because `OR_ELSE` is looser than Boolean `OR`, the formatter should require parentheses when an extracted optional Boolean participates in Boolean logic:

```clear
(flag OR_ELSE FALSE) OR_ELSE fallback
```

This avoids the materially different parse `flag OR_ELSE (FALSE OR_ELSE fallback)`.

## 7. Future readiness

### Name

Retain `IS_READY`. For a beginner, it forms the clearest relationship with CLEAR's consuming operation:

> `future IS_READY` means “calling `NEXT future` now can produce an outcome without waiting.”

`IS_SETTLED` is more precise async-runtime terminology for a terminal promise, but it makes the programmer learn a second word and mentally connect it to `NEXT`. `IS_READY` is preferable if its operational contract is stated narrowly and consistently.

### Required semantics

```clear
future IS_READY          # Bool; nonblocking; no payload capture
```

It must be:

- monotonic for a single-result future (`false` may become `true`, never the reverse);
- nonblocking;
- non-consuming;
- non-driving (it must not poll or execute the future merely to answer);
- thread-safe for shared futures;
- independent of success, failure, and cancellation;
- unavailable unless the runtime future representation has an explicit cached terminal bit/state.

Success, failure, and cancellation are all “ready” because `NEXT` can produce the corresponding outcome without waiting. `IS_READY` must never mean `IS_OK`.

For `@shared` futures this likely requires an atomic state read with acquire semantics so that observing readiness and then consuming the result sees initialized output. That cost and memory ordering must be part of the runtime contract, not hidden in parser sugar.

Initially restrict `IS_READY` to single-result futures/promises. Streams need a different contract: “a next item or terminal event is currently available,” which is non-monotonic and can race with another consumer. A future design should prefer an atomic `TRY_NEXT`/selection operation over check-then-`NEXT` for shared streams.

### No binding

`future IS_READY AS value` must be a compile error. A ready future may contain success, failure, cancellation, or a nested optional. Readiness alone does not select a payload type.

The correct order is:

```clear
IF future IS_READY THEN
    outcome = NEXT future;
    IF outcome IS_OK THEN ... END
END
```

If `NEXT future` returns plain `T`, `IS_OK` is not applicable. If it returns `!T`, `IS_OK` applies to that returned outcome. It must never implicitly await when applied to `~T`.

Most code should use `NEXT` or structured selection directly. `IS_READY` is appropriate for telemetry, opportunistic work, UI state, tests, and nonblocking integration—not spin loops. The compiler should warn on a tight loop whose body repeatedly tests `IS_READY` without suspension, blocking, backoff, or other progress.

## 8. Stacked tenses

Outside-in peeling is correct, but a Boolean predicate does not peel a value for later use. It only reports the outer state.

For `!?T`:

```clear
outcome IS_OK                          # Bool only; outcome remains !?T

IF outcome IS Ok(maybe_value) THEN    # maybe_value: ?T
    IF maybe_value AS value THEN       # value: T
        use(value);
    END
END
```

For `~!?T`:

```clear
outcome = NEXT future;                 # outcome: !?T
IF outcome IS Ok(maybe_value) THEN
    IF maybe_value AS value THEN use(value); END
END
```

No predicate should silently flatten multiple tenses. A convenience that combines layers would need a distinct name, a compelling frequency argument, and ownership/evaluation rules equal in rigor to pattern matching.

## 9. Generalized patterns

The draft is right that user-defined enums must not require a new keyword per variant. Generalized patterns should be the semantic primitive:

```clear
IF message IS Message.Ping(id) THEN handle_ping(id); END
IF result IS Ok(value) THEN use(value); END
IF maybe IS Some(value) THEN use(value); END
```

However, this should not be documented as existing sugar until the parser, exhaustiveness rules, ownership behavior, and MIR representation actually share the same pattern implementation as `MATCH`. The implementation acceptance criterion is one pattern AST/MIR path, not two similar-looking destructurers.

Pattern captures must follow CLEAR's existing ownership contract:

- borrow when matching a borrowed/still-live source;
- move only when the source is owned and consumed;
- never implicitly copy a managed payload;
- reject mutation that overlaps an inferred alias;
- evaluate calls and indexed expressions once.

## 10. API completeness

Do not automatically add an inverse keyword for every state. Start with the positive predicates and ordinary `NOT`:

```clear
NOT (x EXISTS)
NOT (result IS_OK)
NOT (future IS_READY)
```

Add `IS_ERR`, `IS_NIL`, or `IS_PENDING` only if real code shows that negation harms readability or if the inverse carries distinct narrowing information. A small orthogonal vocabulary better serves CLEAR than mirroring every enum variant with a keyword.

Payload predicates such as Rust's `is_some_and` should use ordinary binding/pipelines rather than another tense keyword:

```clear
IF maybe AS value THEN RETURN predicate(value); END
RETURN FALSE;
```

The optimizer can lower this to the same tag test and conditional payload read.

## 11. Diagnostics and autofixes

Required diagnostics:

| Invalid source | Diagnostic | Fixes |
| --- | --- | --- |
| `IF optional` | Optional is not a Boolean | `IF optional EXISTS`; `IF optional AS value`; pattern match |
| `IF fallible` | Fallible value is not a Boolean | `IF result IS_OK`; `IF result IS Ok(value)`; `OR_ELSE RAISE`; `CATCH` |
| `5 EXISTS` | `EXISTS` requires `?T` | remove predicate or correct type |
| `plain IS_OK` | `IS_OK` requires `!T` | remove predicate or correct return type |
| `future IS_OK` | `IS_OK` does not await futures | `outcome = NEXT future`, then inspect outcome |
| `future IS_READY AS x` | Readiness does not select a payload | `NEXT`, then pattern-match the result |
| `WHILE NOT future IS_READY` | Possible busy wait | use `NEXT`, selection, suspension, or explicit tested backoff |

Autofixes must preserve evaluation count. For example, they must not turn one `foo()` call into separate state-test and extraction calls.

## 12. Implementation constraints

The implementation should have one typed predicate node with a closed predicate kind:

```text
TensePredicate {
    operand,
    kind: exists | is_ok | is_ready,
    operand_type,
    result_type: Bool
}
```

Pattern capture remains a pattern node. If fused conditional sugar is accepted, it lowers immediately to the same pattern node and must not introduce a second ownership/lowering path.

Validation should cover:

- every payload class: primitive, managed, destructor-bearing, `@node`, RC/Arc, collection, generic, and nested tense;
- lvalue, borrowed parameter, owned local, call temporary, indexed optional, and safe-navigation operands;
- exactly-once evaluation;
- no retain/release/copy/clone for inspection;
- correct cleanup of temporaries on both predicate results;
- outside-in nested-tense behavior;
- `Some(false)` and `Ok(false)` truth tables;
- wrong-tense diagnostics in EASY, DEFAULT, and STRICT;
- shared-future memory ordering and TSan/hammer coverage if `IS_READY` is implemented;
- formatter precedence around `NOT`, `AND`, `OR`, pipeline operations, and interpolation.

## 13. Final decision table

| Proposal | Recommendation | Strength |
| --- | --- | --- |
| Postfix pure state predicates | Adopt | Strong |
| `EXISTS` returns Bool based only on optional tag | Adopt | Strong |
| `IS_OK` returns Bool based only on result tag | Adopt | Strong |
| Bare `IF ?T` / `IF !T` illegal | Adopt | Strong |
| Predicates usable as general Bool expressions | Adopt | Strong |
| Wrong-tense predicate is always an error | Adopt | Strong |
| Outside-in tense handling | Adopt | Strong |
| General pattern matching is the binding primitive | Adopt | Strong |
| `x EXISTS AS y` as ordinary expression + universal `AS` | Reject as specified | Strong |
| `EXISTS AS` fused optional guard | Adopt through the shared refinement/pattern path | Strong |
| `IS_OK AS` fused guard sugar | Optional; pattern form is cleaner globally | Moderate |
| `IS_READY AS z` | Reject | Very strong |
| Name `IS_READY` for “NEXT will not wait” | Adopt with the narrow operational definition | Strong |
| `IS_READY` on streams | Defer; prefer atomic `TRY_NEXT`/selection | Strong |
| `IS_READY` synchronous observation | Add only with cached state and demonstrated use cases | Moderate |
| Model every resolved future as `Fallible<Optional<T>>` | Reject | Very strong |
| Apply `IS_OK` directly to a future after readiness test | Reject | Very strong |
| Rename tense fallback to `OR_ELSE` globally | Adopt | Very strong |
| Replace `&&` / `||` with `AND` / `OR` | Adopt with fixable migration | Strong |
| Implicit optional-non-Bool presence under `AND` / `OR` | Adopt as requested; explicit `EXISTS` remains clearer | Moderate |
| Implicit `?Bool` under `AND` / `OR` | Reject as ambiguous | Very strong |
| Collapse `NIL` and `FALSE` | Reject | Very strong |

## 14. Required `?Bool` diagnostic

The ambiguous Boolean diagnostic is part of the language contract, not incidental compiler wording:

```text
error: Optional Bool is ambiguous in a Boolean expression

`maybe_flag` has type `?Bool`. CLEAR cannot infer whether you want to test
whether a value exists or use the contained Boolean value.

Choose one:
  presence: `(maybe_flag EXISTS) OR y`
  payload:  `(maybe_flag OR_ELSE FALSE) OR y`

`NIL` and `FALSE` are not implicitly treated as the same state.
```

The fix system should expose both edits as alternatives. It must not silently select one. For `AND`, substitute `AND y` in both alternatives. If the right operand is more complex than an identifier, preserve it byte-for-byte and parenthesize the rewritten left operand.

Postfix force unwrap is a secondary manual option only when presence is already proven; it should not appear as the primary autofix.

## 15. Deletion-first implementation and commit sequence

Each item below is one independently reviewable commit. Every commit must leave all required unit, integration, transpile, formatter, example, benchmark, fuzz, and Zig gates green. No commit may retain two executable semantic paths for the same operator.

### Commit 1 — Migrate fallback syntax to `OR_ELSE`

- Add `OR_ELSE` as the sole optional/fallible fallback and control-flow spelling.
- Convert `OR_ELSE RAISE`, `OR_ELSE EXIT`, `OR_ELSE PASS`, `OR_ELSE BREAK`, and any other existing rescue/control variants to `OR_ELSE ...`.
- Make legacy fallback `OR` a fatal fixable diagnostic whose edit is `OR_ELSE` while `OR` still unambiguously means the old fallback syntax.
- Run max-fix over `compiler/`, `zig/`, `docs/`, `examples/`, `benchmarks/`, `transpile-tests/`, fuzz seeds, fixtures, and generated/checked-in sources.
- Delete the old fallback token/parser/lowering naming (`OR_RESCUE` should be renamed rather than retained as misleading internal terminology).
- Assert with repository searches and tests that no semantic fallback `OR` remains.

This commit must happen before `OR` is assigned Boolean meaning. After reassignment, `optional OR_ELSE something` could be either old fallback source or new presence logic, and no autofix can recover the author's intent reliably.

### Commit 2 — Replace `&&` / `||` with `AND` / `OR`

- Add keyword tokens `AND` and `OR` with short-circuit semantics and the existing logical precedence.
- Delete `&&` and `||` from executable grammar.
- Recognize the old symbols only far enough to emit fatal fixable diagnostics (`&&` → `AND`, `||` → `OR`); do not lower them.
- Run max-fix over the entire repository.
- Update formatter, syntax highlighting/grammar assets, MiniVM/register compiler inputs, diagnostics, and documentation.
- Add evaluation-count tests proving short-circuit behavior is unchanged.

### Commit 3 — Replace implicit optional binding with `EXISTS AS`

- Add `EXISTS AS` first as conditional-only syntax; it does not yet need to be a general postfix expression.
- Add the fused `TenseGuard`/pattern-refinement representation from §5.
- Delete `IF optional AS value` and corresponding `WHILE` forms from executable grammar/annotation paths.
- Emit fatal fixable diagnostics from old binding syntax to `EXISTS AS` and max-fix the repository.
- Share ownership, cleanup, and lowering with the generalized pattern machinery; do not build a parallel optional-binding implementation.
- Allow refinement flow through left-to-right `AND`; reject captures under `OR` and `NOT` initially.
- Cover mutation aliases for list/map/pool/`@node` slots as well as owned call temporaries.

This order makes optionality explicit at every binding site before `EXISTS` gains its second, expression-valued role.

### Commit 4 — Generalize postfix `EXISTS` to an ordinary `Bool` expression

- Parse/type/lower `optional EXISTS` as an ordinary `Bool` expression while retaining the fused `EXISTS AS` guard.
- Reject wrong-tense operands in every language mode.
- Guarantee exactly-once evaluation and tag-only inspection.
- Add precedence, formatter, interpolation, pipeline, temporary-cleanup, and managed-payload tests.
- Keep one `EXISTS` predicate representation; the guard adds capture metadata rather than introducing another parsing/lowering path.

### Commit 5 — Add optional-presence operands and the `?Bool` diagnostic

- Accept `?T` where `T != Bool` under `AND`/`OR` as presence, equivalent to an exactly-once `EXISTS` tag test.
- Apply the same operand rules to both `AND` and `OR`.
- Preserve left-to-right short circuiting and never unwrap/copy/retain the payload.
- Reject non-Boolean, non-optional operands.
- Reject implicit `?Bool` operands under both `AND` and `OR`.
- Emit exactly the two primary alternatives from §14: explicit presence and explicit payload-with-default.
- Support multiple alternative fixes in editor/CLI diagnostic output; `--fix` must refuse to choose between semantically different alternatives, while an interactive or explicitly selected fix may apply either.
- Prove `Some(false)`, `Some(true)`, and `NIL` stay distinguishable.
- Prove `?Bool OR_ELSE Bool` remains valid generic fallback.
- Cover managed, generic, destructor-bearing, indexed, call-temporary, and nested-tense optional operands.

The ambiguity diagnostic belongs here rather than in Commit 2 because both fixes it offers—`EXISTS` and `OR_ELSE`—now compile.

### Commit 6 — Add `IS_OK` and fallible refinement

- Add ordinary `fallible IS_OK -> Bool` with the same predicate invariants as `EXISTS`.
- If `IS_OK AS value` is retained, implement it through the same fused guard/pattern node as `EXISTS AS`.
- Ensure errors are neither discarded nor cleaned prematurely by inspection.
- Add `!Bool`, managed success/error payloads, nested `!?T`, generic, and destructor-count matrices.
- Make chained refinement a required acceptance test: `IF fal_res IS_OK AS maybe_res AND maybe_res EXISTS AS res -> ...` must type-check, evaluate each operand once, expose `res: T` only in the taken branch, and generate the same control flow and cleanup as two nested guards.

### Commit 7 — Add single-future `IS_READY` and block `IS_READY AS`

- Restrict the first implementation to single-result futures/promises.
- Define readiness as “`NEXT` can produce success/failure/cancellation without waiting.”
- Reject `IS_READY AS` explicitly because readiness does not select a success payload. Also reject streams with a diagnostic pointing to `NEXT`/selection and future `TRY_NEXT` work.
- If runtime state is added or changed, add deterministic interleaving, allocator-failure, TSan, hammer, and VOPR tests; tag any wait/spin loops for the hazard detector.
- Verify acquire/release publication for shared promise results.

### Commit 8 — Complete language-wide documentation and conformance

- Update `WALKTHROUGH.md`, tense composition, error handling, collections, concurrency, examples, and migration notes.
- Add parser/fixer idempotence tests: applying max-fix twice produces no second diff.
- Add fuzz families for operator precedence, alternative fixes, conditional refinement, nested tenses, and exactly-once evaluation.
- Run every GitHub CI command locally through `prspec` with all cores.
- Add a final repository check forbidding legacy `&&`, `||`, fallback `OR`, and implicit `IF optional AS` outside explicit negative-test fixtures.

## Conclusion

The proposal's core instinct is aligned with CLEAR: make state inspection readable, safe, allocation-free, and independent of payload truthiness. `x EXISTS` and `result IS_OK` are good additions.

`EXISTS AS` is clearer than implicit optional binding as long as the compiler represents it honestly as conditional refinement rather than `Bool AS payload`. Likewise, `IS_READY` is the beginner-friendly name when it is defined through `NEXT`, while success remains a separate `IS_OK` question. Finally, separating logical `OR` from fallback `OR_ELSE` removes the largest source-reading ambiguity; the remaining `?Bool` choice must be explicit rather than collapsing `NIL` and `FALSE`.
