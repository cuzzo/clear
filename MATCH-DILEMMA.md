# The Union Type Dilemma

## The Problem: "Strict-Correctness" vs. "Business-Correctness"

In a Strictly-Correct language (like Rust or Elm), the compiler treats a Union Type (e.g., `User = Guest | Admin | ...`) as a "Mystery Box." You cannot touch the data inside until you prove to the compiler exactly which state the box is in.

While strictly correct, this creates Match Exhaustion:

```
-- The Strict Way (The Bane of Beginners)
VAR user = getUser(); 

-- You want to send an email. You KNOW the user is an Admin.
-- You just created a database, and there is only one user - you.

doEmailThing(user.email); -- Compiler: "Error: Guest does not have 'email'."

-- You try to check logic:
IF user.isSignedIn() THEN 
  -- Compiler: "I still don't trust you. 'user' is still a Union."
  doEmailThing(user.email); 
END

-- You try to do a cast:
VAR admin = CAST(getUser() AS Admin); -- compiler error, Guest cannot cast to Admin

-- You try to do a match:
MATCH user THEN
  WHEN SignedIn(u) -> doEmailThing(u.email) -- compiler error, what about all the other types!?
END

-- You submit to the boilerplate:
MATCH user THEN
  CASE SignedIn(u) -> doEmailThing(u.email),
  CASE Guest       -> PASS, -- Wasted code
  CASE Banned      -> PASS, -- Wasted code
  CASE Robot       -> PASS  -- Wasted code
END
```

Technically, `User` is one type. 

Practically, it stil behaves like 4 types. 

It solves compiler issues, sure, but it only makes them end-user issues.

What if we could do better? What if we could solve the compiler problem AND the end-user problem?

## The Solution: CHEAT (Fortress Architecture)

CHEAT is a Fortress Language. 
 1. *The Fortress (Public API):* The boundaries of your library must be Strictly Correct. The business logic of a dependency *IS* being Strictly-Correct. 
 2. *The Interior (Private Logic):* Once inside the application, the language becomes *Chill*-Correct.

In a Fortress Language, every `PUBLIC` function must return EXACTLY one type:

  1. What the user expects / wants
  2. A suitable default
  3. An explicit list of errors (and in CHEAT come with a function suffix `!!` to mark the danger)

### 1. The Projected View (Implicit Products)

In CHEAT, any Public Union *must* be able to behave as a Product.

The default behavior when assigning to a Union Type to a `VAR` is an implicit projection to a view.

```
-- User is a Union (Guest | SignedIn)
VAR user = getUser(); 

-- CHEAT allows this!
-- Under the hood, it checks: Is this a SignedIn user?
-- YES: Returns email.
-- NO:  Returns the Default (e.g., "") or Explodes `!!` based on the schema.
print(user.email);
```

The compiler automatically "projects" the fields of the union states onto the variable.

### 2. Solving Match Exhaustion

In CHEAT, you match only what you care about.

```
VAR user = getUser();

-- No need to handle Guest/Banned/Robot if you don't want to.
MATCH user THEN
  SignedIn -> email(user)
END
-- If 'user' is Guest, the code simply continues.
```

### 3. Flow-Sensitive Typing

```
PUBLIC FN User::notify %() -> RETURNS VOID
  
  -- The Guard
  GUARD IS_TYPE(self, SignedIn) OR RETURN VOID;

  -- The Reward
  -- The compiler knows 'user' is SignedIn here. 
  -- No '!!' or error handling needed.
  sendEmail(user.email); 
END

VAR myUser = getUser(...); -- Implicit PROJECTION to a view, not a cast

-- Since all users are signed in, the business logic is correct.
-- The compiler allows it.
myUser.doSignedInThing();

notify(myUser); -- since notify does not end with `!!` it cannot explode.


myUser.doSignedInThing!!() OR VOID; -- `!!` signals possible error
 -- obvious that you need an INLINE OR condition, compiler allows.

VAR myUser : SignedInUser = getUser(); -- compiler error, advanced, fine
  -- Here, you are EXPLICITLY attempt to Type-Cast a variable

VAR myUser : User = getUser(); -- This is default behavior, fine

MATCH getUser() THEN
  SignedInUser -> doSignedInUserThing(); -- OKAY, CHEAT doesn't force you to explicitly match every case
END

PUBLIC FN mySignedInThing %(user : User) -> RETURNS VOID
  GUARD IS_TYPE(myUser, SignedInUser) OR RETURN VOID;
  myUser.doSignedInUserThing(); -- OKAY
END

PUBLIC FN doSignedInStuff %(user : User) -> RETURNS VOID
  myUser.doSignedInUserThing(); 
CATCH
  RETURN VOID; -- OKAY
END

FN doSignedInStuff %(user : User) ->
  myUser.doSignedInUserThing(); -- OKAY, package private 
  -- functions can error without explicit `!!`
 -- it’s your prototype, you can run-time fail if you want to
 -- or you can compile with --enforce-correct=package-private
 -- to make sure even your package-private code is run-time correct
END

PUBLIC FN doSignedInStuff %(user : User) -> RETURNS VOID
  myUser.doSignedInUserThing(); -- compiler error, fine, not begginer
   -- You want PUBLIC API to be Strictly Correct!
END
```

## The Practical Problem

In many cases, users don’t care about Strict Correctness. A user quickly prototyping something, trying out your library, etc, wants to get something running.

IFF they reach that point, they can iteratively make the code more Strictly Correct and efficient if necessary AFTER reaching a working state -- with tests in place to make sure the 99% case is not broken by the 1% case.

Remember, Strictly-Correct has nothing to do with Business-Correct. You can break your business logic by making your code Strictly Correct.

The compiler is happy, and you are not. Such is the status quo.

Not only does it add time - at all stages - and even to those who don't need or care for it. But it adds code. And more code = more surface area for bugs = more chances something slips through code review.

Just as a language making testing more difficult than necessary, leads to sub-par tests...

A compiler making it overly difficult to reach business logic correctness leads to more problems, not less!

Dependencies *should* be Strictly Correct, because that *IS* their business logic!

Application Code wants to be business-logic correct even if it is not Strictly Correct. 
