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
| `sort`, `sortBy` | `self-host required` | Stable sort for compiler/tool output. |
| `keys`, `values`, `pairs` | `self-host required` | Map traversal; sorted variants needed. |
| `indexed` | `self-host required` | Replacement for Ruby `each_with_index`. |
| `withObject` / `foldInto` | `self-host required` | Replacement for Ruby `each_with_object`. |

## Pipeline Result Defaults

Pipelines may stream internally, but collect to lists by default.

```ruby clear illustrative
names = users
    |> SELECT { _.active?() }
    |> MAP { _.name };
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
- Whether map/set traversal sorts by default or exposes sorted variants.
- Generic specialization without importing a class/trait/interface model.
- Mutating operation names for `map!`, `<<`, `[]=`, and update forms.
