# Tense Composition and Stream Types

CLEAR keeps three questions separate:

1. What data is this?
2. What state must be resolved before it can be used?
3. What ownership, synchronization, or layout capability governs it?

Tenses answer the second question. Capabilities answer the third. See
[Sharing Capabilities](sharing-capabilities.md) for the capability model.

## Tenses

| Tense | Meaning |
|---|---|
| `?T` | optional: either `NIL` or `T` |
| `!T` | fallible: either an error or `T` |
| `~T` | future: a `T` that must be resolved with `NEXT` |

Tenses are unary constructors and bind to the complete type immediately to
their right. Parentheses may be used for readability, but are not needed to
repair ambiguous precedence.

```text
?[]T       # optional list of definite T
[]?T       # definite list of optional T
!{Symbol}T # fallible map
{Symbol}!T # map whose values are fallible
~[]T       # future list
[]~T       # list of futures
```

The location of a tense is semantic. Moving `?`, `!`, or `~` across a
collection layer changes which operation is gated.

## Composition

Tenses may compose when each layer is meaningful:

```text
~?T        # future optional T
~!T        # future fallible T
!?T        # fallible optional T
~!?T       # future fallible optional T
```

Repeated identical layers such as `??T`, `!!T`, and `~~T` are errors.
`!?T` is not a structural union: it is the controlled optional/fallible tense
lattice over one payload type.

## Collections and Maps

Inline Pivot collection layers compose directly with tenses:

| Type | Meaning |
|---|---|
| `[10]T` | fixed contiguous array |
| `[]T` | dynamic list |
| `[]?T` | list of optional items |
| `?[]T` | optional list |
| `{Symbol}!T` | Symbol-keyed map of fallible values |
| `!{Symbol}T` | fallible Symbol-keyed map |
| `[]~T` | list of futures |
| `~[]T` | future list |

Mixed layouts still read in access order. `[List]{Symbol}?T` is accessed as
`value[index][symbol]` and returns `?T`.

## Stream Cardinality

Streams are collection nodes, not an overloaded combination of future and
optional syntax:

| Type | Meaning |
|---|---|
| `[~]T` | finite stream with no static item bound |
| `[~N]T` | finite stream of exactly `N` future results |
| `[~INF]T` | infinite stream |
| `[~]?T` | finite stream whose individual items may be `NIL` |
| `[~]!T` | finite stream whose individual items may fail |

Finite completion is distinct from the item type. `NEXT` on a finite stream
produces a completion-aware step; source control flow unwraps it with
`EXISTS`. Consequently, `[~]?T` can yield `NIL` as data without pretending the
stream is closed:

```clear
stream: [~]?Int64 = BG STREAM YIELDS ?Int64 {
    YIELD 10;
    YIELD NIL;
    CLOSE;
};

WHILE NEXT stream EXISTS AS item DO
    # item is ?Int64. NIL is a real item here.
    print(item);
END
```

`CLOSE` emits completion. Falling through a finite producer also closes it
exactly once. An infinite producer must prove that it cannot fall through.

## `YIELDS` Contracts

`BG STREAM YIELDS T` matches `FN ... RETURNS T`: it supplies the expected item
type to every `YIELD` in the body.

`YIELDS` is optional for a homogeneous `T`, `?T`, `!T`, or `!?T` producer. It
is required when the item contract is a future or a named union, and it may
always be written when an explicit API contract is clearer.

The inference rule is intentionally narrow:

- `YIELD 10` plus `YIELD NIL` infers `?Int64`.
- `!T` and `?T` yield sites may join to `!?T` because they share payload `T`.
- `T` plus unrelated `K` is rejected; CLEAR does not silently invent a union.
- `T` plus `~T`, or `!T` plus `~T`, is rejected.
- Named unions require the declared `YIELDS UnionName` contract and explicit
  union variant construction.

A heterogeneous unannotated producer receives a fixable error that identifies
the conflicting sites and offers two choices: declare the correct `YIELDS`
contract, or change the sites to yield one payload type.

## Capabilities on Tense and Collection Nodes

A capability follows the exact node it modifies:

```text
[~]@shared T        # one shared finite-stream handle
[]@shared:locked T  # one shared, locked list
[]T@boxed           # a list whose T payloads are boxed
~[]@local T         # a future list governed by a local capability
```

The compiler preserves this attachment through annotation, MIR, cleanup, and
backend lowering. It never flattens a nested capability into an unrelated
outer layer.

## Legacy Compatibility

Legacy stream spellings such as `~T[N]`, `~?T[]`, `~T[?]`, and `~T[INF]` are
accepted only during the compatibility window. They are not automatically
rewritten where the old spelling is overloaded and a local edit could change
`NEXT` behavior. New code should use `[~N]T`, `[~]T`, and `[~INF]T`.
