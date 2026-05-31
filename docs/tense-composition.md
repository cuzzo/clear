?T[] = Array of Optional Ts.
?(T[]) = Optional Array of Ts.

I think I just need to do that.

~T[] = Stream of Ts.
~(T[]) = A future Array of Ts.

Combinations:

T[] = A stream of optional Ts (somewhat common)
~(?T[]) = A future to an Optional Array of Ts (uncommon)
? (~T[]) = An optional stream of Ts (uncommon)
(T[]) = A future to an Optional Array of Ts (VERY uncommon).

Order of symbols:

If something is *FOR SURE* a future -> it starts with `~` no space for other tenses:
A future to an optional `~?T`
A future to a fallible `~!T`
A future to a fallible optional (bad design) `~!?T`
If something is *FOR SURE* fallible -> it starts with `!` and a space & parens if other tenses:
A fallible `!T`
A fallible future `! (~T)`
If something is *FOR SURE* optional -> it starts with `?` and a space & parens if other tenses:
An optional `?T`
An optional future `? (~T)`
Fallible optionals (typically bad design) are combined before a space:
A fallible optional future `!? (T)`
When combined with arrays:
A for sure finite unbounded stream that could fail: `~!?T[]`
An optional stream where each item can fail: `? (~!T[])`
A fallible stream where each item is optional: `! (~?T[])`

The leftmost character lets you know what you can do with it right away.
Therefore if something is fallible, the `!` must come first.
If it’s optional, the `?` must come next.
If it’s temporal / a future, the `~` must come next.

Complex 2d arrays are NOT representable by design (as they do not make sense in terms of memory layout):

`T[]?[]` # illegal
`? (T[])[]` # illegal
`T[]![]` # illegal
`! (T[])[]` # illegal




| Syntax | Semantic Meaning | Commonality |
| --- | --- | --- |
| `T[]` | Standard Array of T | Ultra-Common (100x) |
| `?T[]` | Array of Optional Ts | Common |
| `~T[]` | Stream of Ts<br>(finite [N] or infinite []) | Common (5x more than Future Lists) |
| `T[]` | Stream of Optional Ts<br>(unbounded, finite) | Common |
| `? (T[])` | Optional Array of Ts | Less Common |
| `~(T[])` | Future Array of Ts | Less Common |
| `~(?T[])` | Future Array of Optional Ts | Rare |
| `(T[])` | Future to an Optional Array | Rare |
| `? (~T[])` | Optional Stream of Ts | Ultra-Rare |




`?(~T[])` you *THEORETICALLY* might want to distinguish between something that could block `NEXT v` and something that can't block if it doesn't even exist `NEXT v?` -> but I can just eliminate that. `?(~T[])` this is essentially an unbounded finite list, yes? One of them says -> this list *MAY* exist, if it does, it's infinite. The other says, this list exists, it is NOT infinite, and it may close on your first call (be optional entirely). These are not entirely the same, but can they be substituted?

Further, we have T{} as HashMap<T> (default symbol keyed) and T{K} as HashMap<T, K>


| Syntax | Semantic Meaning | Real-World Use Case |
| --- | --- | --- |
| `T{}` | Standard Map of T | Storing a local cache of Users by their username. |
| `?T{}` | Map of Optional Ts | A sparse matrix or a cache where keys can explicitly hold blank values. |
| `~T{}` | Stream of Ts from a Map | A live, reactive database view pushing updated values as they change. |
| `T{}` | Stream of Optional Ts | A live feed pushing updates, where some updates delete the value. |
| `? (T{})` | Optional Map | A configuration block that is completely omitted in the settings file. |
| `~(T{})` | Future Map | GET /api/v1/config (Awaits and returns the full JSON map). |
| `(T{})` | Future Optional Map | Fetching an optional block of data that might return 404/None. |



m: ~T{} = getInfMap(); // infinite
m2: ~?T{} = getUnboundFiniteMap(); // unbound, finite


// Loop through mutations as they hit the map
while NEXT m AS (key, value) {
    print("Key {key} changed to {value}");
}

// Loop through mutations as they hit the map
while NEXT m2 AS (key, value) {
  IF value AS v {
    print("Key {key} changed to {v}");
  }
  ELSE {
    print("Key {key} was deleted");
  }
}
print(“stream closed.”);









| Syntax | Semantic Meaning | Commonality |
| --- | --- | --- |
| `T[]` | Standard Array | Ultra-Common |
| `!T[]` | Array of Fallible Elements<br>(you build an array / map of individual funcs that fail) | Common |
| `~!T[]` | Stream of Fallible Elements (Your BG STREAM type)<br>(you BG STREAM a func that fails) | Common |
| `! (~T[])` | Fallible Stream (Stream closes if it errors)<br>You return a stream in a function that can fail | Rare<br>(BAD DESIGN) |
| `! (T[])` | Fallible Array Container (Synchronous error)<br>(You return an array in a function that can fail) | Common |
| `~(T[])` | Future Array | Less Common |
| `! ~(T[])` | Fallible Future Array (Standard Async API Fetch) | Common |




For RARE edge cases, you would almost never define them in an API, it would be because you did: 
BG STREAM { x |> SELECT { ... } } 

You can end up with a weird type...


However, people need to know how they can interact with this thing.


I think I can get away with `! ` with a space preceding anything that can error. And `? ` preceding anything that is optional (both of those require special handling before you can use them.

`!? (~T[])` -> A function that COULD fail, if it succeeds it COULD return a stream OR nothing. (this is terrible design and should never exist).

`!? (~!?T[])` -> as before, but each individual item COULD also be a failure or nothing at all (also terrible design and should never exist). 


