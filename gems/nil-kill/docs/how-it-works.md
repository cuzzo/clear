# How Does Nil-kill Work?

Type Inference in dynamic languages today is predominately done with static analysis.

## The Easy Part

This is trivial in certain situations:

- Literals
- Typed Structs / Classes
- Typed Arrays
- Branchless Non-fallible Returns

## The Medium Part

Static analysis includes whole program analysis. You can build control flow graphs to determine types for branching returns and fallible functions.

In typical dynamically typed code bases, this may be ~50% of the code. Being able to infer types for 50% of code is good, but what if you wanted to get closer to ~90%?

## The Hard Part (that doesn’t seem hard)

In programming languages like Ruby, Python, Lua (especially), and JavaScript - it is pervasive to use primitives like HashMaps to act as Typed Structs/Classes and to use Arrays as impromptu Tuples.

If a HashMap is really just a struct in disguise, then why are typed structs easy to detect types, but disguised HashMaps hard?

When static analysis sees `x = my_map[:my_field]` it typically cannot distinguish `my_map` from all the other untyped HashMaps in your program.

Concrete HashMap example:

```ruby
my_map = { name: "foo", id: 1 }
return my_map[:id]
```

HashMaps are not structs. The type of `my_map` is technically:

```ruby
T::Hash[Symbol, T.any(String, Integer)]
```

Without treating this hash as a record shape, `my_map[:name]` and `my_map[:id]` both collapse to the same value type: `T.nilable(T.any(String, Integer))`, even though `:name` is always a `String` and `:id` is always an `Integer`.

Concrete Tuple example:

```ruby
my_tup = ["foo", 1]
return my_tup[1]
```

Tuples are not structs, either!  The type of `my_tup` is technically:

```ruby
T::Array[T.any(String, Integer)]
```

Without tuple-shape evidence, the index-specific meaning is lost: index `0` and index `1` both look like `T.nilable(T.any(String, Integer))`, even though the first slot is intended to be a `String` and the second an `Integer`.

## The Even Harder Part

The example above may seem pedantic, and like something static analysis with even a modest amount of runtime analysis should be able to solve, but the problem here is harder: metaprogramming.

```python
class ApiResponse:
    def __init__(self, data_dict):
        for key, value in data_dict.items():
            setattr(self, key, value)

# Runtime behavior:
response = ApiResponse({"user_id": 42, "is_active": True})
return response.user_id
```

This is essentially the problem above, just slightly harder.  But metaprogramming has many forms:

```javascript
// Somewhere deep in a third-party library
String.prototype.toUrl = function() { return "http://" + this; };

// Back in your code
let myString = "google.com";
return myString.toUrl();
```

Depending on the runtime `.toUrl()` may have different meanings.  Sometimes, it may return strings, other times it may be an error that it doesn’t exist, other times it may return nilable Strings, and in bad designs it may return Arrays and who knows what else!

## The Frustrating Part

Most of dynamic typing is a double edged sword. It provides little benefit, at the expense of countless bugs.

One aspect of Dynamic Typing that is quite nice is having an Array / Collection of objects of many different types.  In Typed languages, you need dreaded interfaces (or some equivalent) to solve this problem.

Building Structs to represent your data is relatively trivial and extremely useful.  Interfaces are, too, but they aren’t quite as trivial to implement.  They’re also far less common, so can be a pain to learn if you barely ever need them.

Let’s say you have a collection of different Enemy types:

```ruby
my_enemies = getEnemies();
hps = my_enemies.map { |e| e.hp };
```

This is again a problem that seems like the same problem as the HashMap masquerading as an array.

The problem is less about figuring out what `.hp` gets you in a reasonably designed system.  It’s about figuring out what exactly can go into `myEnemies`.  And you need to know that to be able to figure out what `.hp` returns.

## The Saving Grace

With minimal runtime analysis - you can solve most of the problem with primitives acting as Structs, and properly resolve their types.
Most programs are nowhere near as bad as they technically could be. People rarely have a function like `toString()` that sometimes returns strings, and other times returns floats.

Combined with runtime analysis and minimal intervention - most metaprogramming ambiguity can usually be resolved by the user easily:

A report generates:

```text
Metaprogramming ambiguity: `MyClass::toString` -> please specify type
```

You say… hmm… toString() -> that’s probably a string, try it.

```text
Collection ambiguity: `my_enemies.hp` -> please specify type
```

You say… hmm… `.hp` -> that’s obviously an Integer, it generates the minimal interface for you.

## How does Nil-kill Help?

Nil-kill builds a runtime-aware flow graph.

It looks at both static analysis and runtime analysis to determine **WHICH** exact problems **CAUSE** the most static-analysis failures, and **HOW** and **WHERE** to fix them.

This is known as *nil pressure*. Which `nil`s are causing the most `T.nilable()` effects throughout the code base.

## Current Limitations

Nil-kill records `T.let` sites and can propose narrowing existing `T.let` annotations, but it does not yet use runtime `T.let` observations as a self-correction loop for broader inference.

The intended next step is:

```text
static inference proposes String
instrumented run observes NilClass at the injected T.let site
nil-kill downgrades or corrects that candidate before reporting/autofix
```

That feedback is not wired into return inference, param inference, or hash-record pressure ranking yet. Today, `T.let` runtime data is useful for narrowing existing `T.let` sites, not for correcting nil-kill's broader inferred candidates.

Nil-kill was born as a tool to detect pervasive nil check guards, and allowed [CLEAR](../../README.md) to remove the majority of `&.` safe navigation checks and `T.nilable()` returns and parameters in a few easy commits, mostly with autofixes.

Then the idea came up: why not do the same to detect the source of `T.untyped()` for the number of hard reasons listed above, where static analysis / Sorbet / existing Ruby tooling fail?

See the [README](../README.md) to get started.
