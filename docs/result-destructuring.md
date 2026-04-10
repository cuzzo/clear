# Result Destructuring

CLEAR provides a human-readable syntax for "unpacking" complex data structures into individual variables. While `SWAP(a, b)` is the preferred first-class verb for swapping values, structural assignment is used to simplify the handling of multiple return values.

## Syntax Overview

Destructuring uses a parenthesized list on the left side of an assignment to map the "contents" of a structure to new or existing variables.

```ruby
(name, age) = fetchUser(id)
```

## Supported Types

## Structural Mirroring

CLEAR follows the "Mirroring Principle": **The syntax to destructure a value should look exactly like the syntax used to create it.** This ensures that "normal humans" only have to learn one way to describe a data structure.

### 1. Struct Destructuring
This mirrors the `Struct{}` literal. It allows you to extract specific fields into local variables.

```ruby
STRUCT User { name: String, id: Int64, age: Int64 }

-- Destructure mirroring the literal
User{ name, id, age } = fetchUser()

-- Partial Destructuring (using ellipsis)
User{ name, ... } = fetchUser()  -- Extract only 'name', ignore 'id' and 'age'
```

### 2. Union Destructuring
This mirrors the `Union.Variant{}` literal. It is used when you are certain of the active variant (otherwise, use a `MATCH` statement).

```ruby
UNION Result { Ok: String, Err: Int64 }

-- Extract the payload from a known variant
Result.Ok{ message } = getResult()
```

## The "MATCH" Connection

Destructuring assignment is simply a **non-conditional version of a `MATCH` arm**. The same pattern-matching engine used in `MATCH` statements drives these assignments:

| Context | Intent | Behavior |
| :--- | :--- | :--- |
| **`MATCH`** | "If it looks like this..." | Branch to block if shape matches. |
| **`Assignment`** | "It looks like this..." | Bind variables immediately (Panic if shape mismatch). |

### Example: The Mirror in Action
```ruby
-- In a MATCH statement:
MATCH res START
    Result.Ok{ msg } -> print(msg)
END

-- In a Destructuring Assignment:
Result.Ok{ msg } = res
print(msg)
```

## Parsing & Technical Rationale

By requiring the Type prefix (`User{...}` or `Result.Ok{...}`), the parser avoids the ambiguity of bare curly braces. This makes the code **locally readable**: the reader immediately knows the type being unpacked without needing to trace the variable's origin.

1. **Mirror Literals:** `User{...}` creates it; `User{...} =` unpacks it.
2. **Partial Matches:** The `...` (ellipsis) allows for future-proof code where adding a field to a struct doesn't break every destructuring site.
3. **Safety:** Unlike Ruby/JS, CLEAR destructuring is **Type-Checked**. The compiler verifies that the fields being unpacked actually exist on the struct definition.

## Special Cases

### The SWAP Verb
While `(a, b) = (b, a)` is syntactically valid, CLEAR encourages the use of the `SWAP` intrinsic for readability:
```ruby
SWAP(x, y)  -- Explicit intent: "Exchange these two values"
```

### Wildcards
Use `_` to ignore a single field or `*` to ignore the remainder of a list:
```ruby
(user, _) = fetchUserWithToken(id)  -- Ignore the second return value
(first, *) = data                   -- Ignore everything after the first element
```

## Comparisons

| Language | Syntax | Philosophy |
| :--- | :--- | :--- |
| **Swift** | `(x, y) = result` | **Tuple Packing:** Treats the left and right as matching sets. Very readable for "normal humans." |
| **Elixir** | `{x, y} = result` | **Pattern Matching:** The `=` is an assertion. If the shapes don't match exactly, it crashes. Powerful but "strict." |
| **CLEAR** | **`(x, y) = result`** | **Structural Assignment:** A convenience for the `PromotionPlan`. It maps intent to layout without requiring the user to prove "correctness" manually. |

## Implementation Note
The `ZigTranspiler` lowers these assignments into sequential Zig `const` or `var` declarations. If the source is an expression (e.g., a function call), the compiler creates a hidden temporary to ensure the expression is only evaluated once.
