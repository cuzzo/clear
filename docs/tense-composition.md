# Tense Compositions

CLEAR separates Tenses (Temporal, Optional, Failable) from pure memory layout (Types) from capabilities.

See [Sharing Capabilities](sharing-capabilities.md) for more details.

## Tenses:

 * `~T`: Future Tense: A `T` that is not guaranteed to be available now, but at some point in the future will be, certainly.
 * `!T`: Failable Tense: A `T` that could be an error or a `T`.
 * `?T`: Optional Tense: A `T` that could be Nil or a `T`.

## Combinations:

 * `~?T[]` = A stream of optional `T`s (common - this is an unbound finite stream)
 * `? (~T[])` = An optional stream of `T`s (uncommon)
 * `~(T[])` = A future to an Optional Array of `T`s (uncommon)
 * `~(?T[])` = A future to an Optional Array of `T`s (VERY uncommon)

To some, this may be considered far less readable than Rust/C style:

 * `Stream<Optional<T>>`
 * `Future<Optional<T>>`
 * `Optional<Stream<T>>`
 * `Future<T[]>`

However, the further these compose with CLEAR's capabilities and failables, the harder Rust types are to read.

Compare simple cases:

| CLEAR | Rust | What |
| ----- | ---- | ---- |
| `~T[]@shared:locked` | `Arc<RwLock<Pin<Box<dyn Stream<Item = T>>>>>` | The entire stream is thread-shared and locked. |
| `~T[]` |	`impl Stream<Item = T>` | A basic asynchronous stream yielding Ts. |
| `~(T[])@shared:locked` | `Arc<RwLock<Future<Output = Vec<T>>>>`  | A shared, locked future that resolves to an array. |

Compare complex cases:

| CLEAR | Rust | What |
| ----- | ---- | ---- |
| `~(!?T[])` | `impl Future<Output = Result<Option<Vec<T>>, Error>>` |	A Future that eventually yields a <br /> single, fallible, optional vector. |

CLEAR reads better left to right:

 * You immediately know what it is and what you must do to access it.
 * It is clearly separated what you are allowed to do with it (how it can be shared, and the cost of that).

CLEAR's tense system can look like Sigil Soup, but for the vast majority of cases it is more readable if you take a minute to learn the 3 sigils / tenses.

In the cases where you have tons of nested capabilities and tenses, CLEAR believes its system is much easier to parse to separate the concerns of what is important.

In short, CLEAR separates:

 1. What you need to do before you can use data (tenses),
 2. From the memory layout (types),
 3. From what you're allowed to do with it / how it can be shared, and optimizations on it (capabilities) 

## Order of symbols:

Tense symbols are read left-to-right. 

Following the ordered list above, the come first (left most) because they dictate what must be done first to use the underlying data (the actual type):

If something is *FOR SURE* a future -> it starts with `~` no space for other tenses:

 * A future to an optional `~?T`
 * A future to a failible `~!T`
 * A future to a failible optional (bad design) `~!?T`

If something is *FOR SURE* fallible -> it starts with `!` and a space & parens if other tenses:

 * A failible `!T`
 * A failible future `! (~T)`

If something is *FOR SURE* optional -> it starts with `?` and a space & parens if other tenses:

 * An optional `?T`
 * An optional future `? (~T)`

Fallible optionals (typically bad design) are combined before a space:

  * A fallible optional future `!? (T)`

When combined with arrays:

 * A for sure finite unbounded stream that could fail: `~!?T[]`
 * An optional stream where each item can fail: `? (~!T[])`
 * A fallible stream where each item is optional: `! (~?T[])`

The leftmost character lets you know what you can do with it right away.

Therefore if something is fallible, the `!` must come first:

 * If it’s optional, the `?` must come next.
 * If it’s temporal / a future, the `~` must come next.

Complex 2d arrays are NOT representable by design (as they do not make sense in terms of memory layout):

 * `T[]?[]` # illegal
 * `? (T[])[]` # illegal
 * `T[]![]` # illegal
 * `! (T[])[]` # illegal

> This is not unique to CLEAR.  This is not allowed in Rust, C, or Go either.

## Styling

Note that there is a space between optionals and errors, when combine with any non-trivial tense:

* `!T`
* `?T`
* `!?T`
* `? (~T)`
* `! (~T[])`
* `! (~?T)`
* `!? (~T)`

If you don't include the spaces and parentheses, the compiler will typically auto-correct it for you.

In practice, complex types like these are often created inline, via streaming pipelines, and you never need to know the correct formatting.

## Streaming Arrays:

| Syntax | Semantic Meaning | Commonality |
| --- | --- | --- |
| `T[]` | Standard Array of T | Ultra-Common (100x) |
| `?T[]` | Array of Optional Ts | Common |
| `~T[]` | Stream of Ts<br>(finite [N] or infinite []) | Common (5x more than Future Lists) |
| `~?T[]` | Stream of Optional Ts<br>(unbounded, finite) | Common |
| `? (T[])` | Optional Array of Ts | Less Common |
| `~(T[])` | Future Array of Ts | Less Common |
| `~(?T[])` | Future Array of Optional Ts | Rare |
| `~(T[])` | Future to an Optional Array | Rare |
| `? (~T[])` | Optional Stream of Ts | Ultra-Rare |

## Streaming HashMaps:

| Syntax | Semantic Meaning | Real-World Use Case |
| --- | --- | --- |
| `T{}` | Standard Map of T | Storing a local cache of Users by their username. |
| `?T{}` | Map of Optional Ts | A sparse matrix or a cache where keys can explicitly hold blank values. |
| `~T{}` | Stream of Ts from a Map | A live, reactive database view pushing updated values as they change. |
| `~?T{}` | Stream of Optional Ts | A live feed pushing updates, where some updates delete the value. |
| `? (T{})` | Optional Map | A configuration block that is completely omitted in the settings file. |
| `~(T{})` | Future Map | GET /api/v1/config (Awaits and returns the full JSON map). |
| `~?(T{})` | Future Optional Map | Fetching an optional block of data that might return 404/None. |

```ruby clear illustrative
m: ~T{} = getInfMap(); // infinite
m2: ~?T{} = getUnboundFiniteMap(); // unbound, finite

# Loop through mutations as they hit the map
WHILE NEXT m AS (key, value) {
    print("Key {key} changed to {value}");
}

# Loop through mutations as they hit the map
WHILE NEXT m2 AS (key, value) {
  IF value AS v {
    print("Key {key} changed to {v}");
  }
  ELSE {
    print("Key {key} was deleted");
  }
}
print("stream closed.");
```

## Combine with failibility:

| Syntax | Semantic Meaning | Commonality |
| --- | --- | --- |
| `T[]` | Standard Array | Ultra-Common |
| `!T[]` | Array of Fallible Elements<br>(you build an array / map of individual funcs that fail) | Common |
| `~!T[]` | Stream of Fallible Elements (Your BG STREAM type)<br>(you BG STREAM a func that fails) | Common |
| `! (~T[])` | Fallible Stream (Stream closes if it errors)<br>You return a stream in a function that can fail | Rare<br>(BAD DESIGN) |
| `! (T[])` | Fallible Array Container (Synchronous error)<br>(You return an array in a function that can fail) | Common |
| `~(T[])` | Future Array | Less Common |
| `! ~(T[])` | Fallible Future Array (Standard Async API Fetch) | Common |
