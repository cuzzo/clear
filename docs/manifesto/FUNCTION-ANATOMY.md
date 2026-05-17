# THE ANATOMY OF A GOOD FUNCTION

The most desired behavior from any function is that it **works**.

A function should exist to serve the user, not the compiler. It should (in order of preference):

 1. Return (and do) what the user wants
 2. Return a suitable default (if possible/applicable)
 3. Return an explicit set of errors

It should return exactly *ONE* type. A user should never need to post-process a function's output to do what they want.

## ALL PUBLIC FUNCTIONS MUST BE GOOD

```CLEAR
PUBLIC FN getFullyFormedUser(id: Number) -> RETURNS User OR User::DEFAULT
  -- 1. Input Hygiene: Handle invalid inputs *uniformly* at the top.
  GUARD id > 0 OR RETURN DEFAULT; 

  -- 2. The Happy Path: A clear, easy-to-follow stream of data using 's>'
  RETURN id
   s> fetchUserFromCache
   s> OTHERWISE(fetchFromDb!!) OR EXIT -- If cache misses, try DB
   s> hydrateFromOtherDb;

-- 3. The Catch-All:
-- All error logic is tucked away at the bottom.
CATCH
  RETURN DEFAULT; -- Return suitable default on error
END
```

## INTERNAL FUNCTIONS CAN BE BAD

```CLEAR
-- This can return an error `!!`
-- Internal code can be "Chill-Correct" until you're ready to make it public.
FN reciprocalId(id) -> 
  RETURN functionThatCanError!!(id);
END
```

## Comparisons

*   **C:** High Danger. Manual memory management and error checking.
*   **Go:** Visual Noise. Repetitive `if err != nil` boilerplate kills flow.
*   **Rust:** High Cognitive Load. Mandatory unwrapping of every Enum/Result case.
*   **CLEAR:** Represents **Flow**. It projects the "View" of the data you want, handling the Union/Error logic implicitly based on your definitions.

```CLEAR
-- CLEAR projects the view of the data you want
-- 1. Handles the Error (defaults to empty/nil if it fails)
-- 2. Handles the Union (projects View)
PRINT(getUser().email);
```

## THE FINAL PATH

CLEAR is designed as a language that is native to **Property-Based Testing**.

Because *EVERY* public function follows a strict contract:
 1. Inputs and outputs have suitable defaults (or explicit explosions).
 2. We can programmatically generate permutations of every possible input for testing.
 3. CLEAR enforces a Strict Contract at the Public boundary (RETURNS Type OR Default). This solves the *Oracle Problem* for automated testing.

The easier you make code to understand and to test, the easier you make it to get **working** code.

And **working** code is all that really matters.

## VERDICT

* C/Elixir represent **Chaos**.
* Rust/Go represent **Bureaucracy**.
* CLEAR represents **Flow**.
