# THE ANATOMY OF A GOOD FUNCTION

The most desired behavior from any function is that it **works**.

This is easier said than done.

A function should exist to serve the user, not the compiler. It should (in order of preference):

 1. Return (and do) what the user wants
 2. Return a suitable default (if possible/applicable)
 3. Return an explicit set of errors

It should return exactly *ONE* type. A user should never need to post-process a function's output to do what they want.

## ALL PUBLIC FUNCTIONS MUST BE GOOD

```
PUBLIC FN getFullyFormedUser %(id: Number) -> RETURNS User OR User::DEFAULT
  -- 1. Input Hygiene: Handle invalid inputs *uniformly* at the top.
  GUARD id > 0 OR RETURN DEFAULT; 

  -- 2. The Happy Path: A clear, easy-to-follow stream of data.
  RETURN id
   s> fetchUserFromCache
   s> OTHERWISE(fetchFromDb!!) OR EXIT -- If cache misses, try DB (which might explode)
   s> hydrateFromOtherDb;

-- 3. The Catch-All:
-- All error logic is tucked away at the bottom.
-- It is out of the way for people reading the logic,
-- but easy to find for people debugging the failure.
CATCH -- since there is a `!!`
  RETURN DEFAULT; -- We can return a user because there is a suitable default
END
```

## INTERNAL FUNCTIONS CAN BE BAD

```
-- This can return an error `!!`
-- In practice, you may know that it never will.
-- The compiler doesn't fight you. It's your internal code.
PUBLIC FN reciprocalId %(id) -> 
  RETURN functionThatCanError!!(id);
END
```


## C started it - the foot-gun approach

C does not have Tagged Unions or standard error types. 

You usually return an integer error code and pass a pointer to be filled.

```C
User* user;
int err = get_user(&user);

// IF YOU FORGET THIS CHECK, THE PROGRAM SEGFAULTS
if (err != 0) { return; } 

// AND IF IT'S A UNION, YOU MUST CHECK THE TAG MANUALLY
if (user->type == SIGNED_IN) {
    printf("%s", user->data.signed_in.email);
}
```

*Friction:* High Danger. You are manually driving the memory management and type checking.

You are much more likely to write broken code than working code.

## Go improved it (barely)

Go uses "Multiple Return Values." Every function at least returns what you want.

But it practice, the code is hardly more ergonomic.

```Go

user, err := getUser()

// THE "IF ERR != NIL" WALL
if err != nil {
    return err
}

// INTERFACE TYPE ASSERTION (The Union workaround)
if u, ok := user.(SignedInUser); ok {
    fmt.Println(u.Email)
}
```

*The Problem:* Visual Noise. You cannot chain operations. Every single function call requires 3 lines of error checking.

This code is not easy to read or understand, though it's much more likely to **work** - which is a big step!

## Rust: The "Computer Says No" (Strictness)

Rust uses Result<T, E> and Enums (Tag Unions). It is strictly correct.

*The Problem:* Mandatory Unwrapping. The compiler forbids you from touching `.email` until you prove you have handled the Error case AND the Guest case.

```Rust
let user = match get_user() {
    Ok(u) => u,
    Err(e) => return Err(e), // Or unwrap() and crash
};

// MATCH EXHAUSTION
match user {
    User::SignedIn(u) => println!("{}", u.email),
    User::Guest => {}, // Must handle this explicitly
    User::Banned => {}, // Must handle this explicitly
}
```

*Friction:* High Cognitive Load. You have traded corectness for understandability. Sure, many people will gladly make this trade. 

```

## Elixir: "Let There Be Crashes"

```Elixir
# If this returns {:error, ...}, the process CRASHES here immediately.
{:ok, user} = get_user() 

# Accessing the field
IO.puts(user.email)
```

## Swift: Trying hard, but still not there

Swift tries to make the matching easier with `if case let`, but it is still fundamentally a "Guard" or "Match" syntax, not a "Dot Access" syntax.

```Swift
if case let .signedIn(email) = u { print(email) }
```

*The problem:* This makes sense to EXACTLY no-one who doesn't know swift.

## CHEAT

CHEAT projects the "View" of the data you want, handling the Union/Error logic implicitly based on your definitions.

```
-- CHEAT
-- 1. Handles the Error (defaults to empty/nil if fails)
-- 2. Handles the Union (projects View)
print(getUser().email);

-- IFF there was no suitable default, you would see
print(getUser().signedInOnlyId!!); -- compiler error, `!!` should be obvious signal
```

## THE FINAL PATH

CHEAT is designed as a language that is native to Property-Based Testing.

Because *EVERY* public function *MUST* have these properties:

 1. We know that every PUBLIC input and output *MUST* have suitable defaults (or Explosions)
 2. Therefore, we can programatically generate permutations of every possible suitable default (or Explosion) your function can get
 3. Therefore, you can write working code!

CHEAT enforces a Strict Contract at the Public boundary (RETURNS Type OR Default). This solves the hardest part of automated testing: *The Oracle Problem*.

The easier you make code to understand and to test, the easier you make it to get **working** code.

And **working** code is all that really matters.

## VERDICT

* C/Elixir represent Chaos.
* Rust/Go represent Bureaucracy.
* CHEAT represents Flow.


