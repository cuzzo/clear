# THE MATCH DILEMMA

In standard Tagged-Union / Enum languages (Rust, Swift, Kotlin), the compiler forces you to `MATCH` every single case of a Union type.

```Rust
match user {
    User::SignedIn(u) => println!("{}", u.email),
    User::Guest => println!("Welcome guest"),
    User::Banned => println!("You are banned"),
}
```

*The Friction:* If you only care about the email of signed-in users, you still have to write code to handle the Guest and Banned cases. If you add a `User::Moderator` later, your code breaks everywhere until you handle that new case.

This is **Bureaucracy**. It prioritizes the compiler's needs over the developer's intent.

## The Solution: CLEAR (Fortress Architecture)

CLEAR is a **Fortress Language**. It handles the "Safety Gap" at the public boundary, allowing your internal logic to flow smoothly.

In CLEAR, any Public Union *must* be able to behave as a Product (a struct with fields) by projecting a **View**.

```CLEAR
-- CLEAR allows this
-- If the user is NOT SignedIn, .email returns a suitable default (empty string)
-- or handles the Nil case implicitly if defined in the Fortress boundary.
PRINT(getUser().email);
```

### Selective Matching

In CLEAR, you match only what you care about.

```CLEAR
CASE getUser() OF
  SignedInUser AS u => doSignedInUserThing(u);
  -- No need to match Guest or Banned if you don't care
  -- They flow through to the default or are ignored.
END
```

*The Benefit:* **Refactoring Blast Radius: Zero.** Adding a new case to a Union doesn't break existing code that doesn't care about that new case.

### Why this is Safe

CLEAR projects a **View** of the data. If you access a field that only exists in one variant of a Union:
1.  **If the variant matches:** You get the data.
2.  **If it doesn't:** You get a suitable default (defined at the boundary) or an explosion (`!!`) if you've marked it as mandatory.

This preserves **understandability** and **velocity** without sacrificing safety.

## Summary

| Language | Approach | Result |
| :--- | :--- | :--- |
| **Rust** | Exhaustive Match | Bureaucracy & Fragility |
| **Go** | Type Assertion | Error-Prone & Verbose |
| **CLEAR** | Projected View | **Flow & Flexibility** |

**CLEAR optimizes for the developer's intent, not the compiler's pedantry.**
