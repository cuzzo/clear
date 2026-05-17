# WHO IS CLEAR *NOT* FOR

CLEAR is opinionated. The specific optimizations that make it fast and safe for 99% of Business Logic make it extremely hostile to 1% of Architectural patterns.

1. You are building a Pointer-Heavy Engine (like a Graph Database).
  * CLEAR prevents Memory Leaks by forbidding reference cycles in `shared` objects (Shared A -> B, B -> A).
  * If your architecture relies on a "Soup of Mutable Objects" where everything references everything else, CLEAR will fight you.
  * *The Alternative:* Architect your data using IDs and centralized lookups (like a relational database), or use Rust/C++ for manual pointer management.

2. You need to model Inherently Unsafe / Cyclic Relationships
  * If your architecture relies on Rust-style "Weak Pointers" to manage reference cycles (A -> B -> A)
     * OR if you need recursive fine-grained locking, and you are strictly managing memory and deadlock risks manually.
  * CLEAR guarantees safety by forbidding these patterns entirely! They're rare!
  * *The Alternative:* If you absolutely need a doubly-linked list or a cyclic graph with individual node locking, that is "Engine Code," not "Business Logic." Write that specific component in Zig (where you can manage the unsafe pointers yourself) and import it into CLEAR as a safe handle.


