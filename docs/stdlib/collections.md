<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# Collections And Pipelines

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


Status: `planned`, `self-host required`.

Collections should feel like Ruby and Elixir at the call site while still
giving the compiler enough information to track allocation, mutation,
ownership, effects, and capability use.

## Planned Types

| Type | Status | Notes |
| --- | --- | --- |
| Slice | `prototype` | Borrowed view over contiguous values. |
| List/vector | `intrinsic today` | Growable contiguous collection. |
| Map/hash | `intrinsic today` | Hash map; deterministic views required for compiler output. |
| Set | `intrinsic today` | Hash set; deterministic views required for compiler output. |
| Range | `prototype` | Numeric iteration and slicing. |
| Pool/slab | `intrinsic today` | Stable handles for compiler/runtime structures. |
| Queue/deque | `planned` | Add when compiler or scheduler code needs it. |

## Planned Transforms

| API | Status | Behavior |
| --- | --- | --- |
| `each` | `self-host required` | Side-effect iteration, returns `Void`. |
| `map` | `self-host required` | New list from final block expression. |
| `select` / `filter` | `self-host required` | Keeps values where predicate is true. |
| `reject` | `self-host required` | Inverse filter. |
| `filterMap` | `self-host required` | Maps to `?T`, keeps non-nil values. |
| `flatMap` | `self-host required` | Maps to collections and flattens. |
| `reduce` / `fold` | `self-host required` | Explicit accumulator. |
| `any?`, `all?` | `self-host required` | Short-circuit predicates. |
| `find` | `self-host required` | Returns `?T`. |
| `sum`, `count` | `self-host required` | Numeric and predicate aggregation. |
| `ORDER_BY` | `self-host required` | Explicit sort by key expression. |
| `keys`, `values`, `pairs` | `self-host required` | Map traversal; explicit ordered variants where output order matters. |
| `indexed` | `self-host required` | Replacement for Ruby `each_with_index`. |
| `withObject` / `foldInto` | `self-host required` | Replacement for Ruby `each_with_object`. |

## Pipeline Result Defaults

Pipelines may stream internally, but collection is determined by explicit
terminal or destination type. A `[~]T` destination keeps a stream; an `[]T`
destination collects to a list; a `{K}V`
destination collects to a map if the pipeline shape supplies keys.

```ruby clear illustrative
names: []String = users
    |> SELECT { _.active?() }
    |> MAP { _.name };

names_stream: [~]String = users
    |> SELECT { _.name };
```

Other result shapes are explicit:

```ruby clear illustrative
users_by_id = users
    |> COLLECT_MAP { _.id => _ };

unique_names = users
    |> MAP { _.name }
    |> COLLECT_SET;
```

## Decisions

- Exact syntax for `AS_STREAM`, `COLLECT_LIST`, `COLLECT_MAP`, and
  `COLLECT_SET`.
- How `SORT` differs from `ORDER_BY` after ordering traits/interfaces are
  designed.
- Generic specialization without importing a class/trait/interface model.
- Mutating operation names for `map!`, `<<`, `[]=`, and update forms.
