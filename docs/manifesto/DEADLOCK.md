# SHARED MUTABLE DEATH

## CLEAR - The Unfair Advantage

```CLEAR
STRUCT Account {
  balance: Float64,
}

STRUCT Cache {
  -- Capabilities are properties of the storage, not the type
  items: shared:locked HashMap<String, shared:locked Account>,
}

FN insert(cache: Cache, id: String, account: Account) ->
  -- Acquire shared:locked capability
  sharedAccount = SHARE:LOCKED(account);
  
  WITH cache.items {
    -- Inside here, the HashMap is unwrapped and locked
    _.insert(id, GIVE sharedAccount);
  }
END

FN transact(cache: Cache) ->
  -- CLEAR automatically handles lock ordering in WITH blocks to prevent deadlocks
  WITH cache.items.get("a") AS a, cache.items.get("b") AS b {
    a.balance += 10;
    b.balance -= 10;
  }
END
```

 * What can go wrong? Not deadlock, not memory corruption.
 * CLEAR makes illegal states impossible at the concurrency level **while** being easy and ergonomic.

CLEAR distinguishes between **Types** and **Capabilities**:
- `Account` is a Type.
- `shared:locked` is a Capability.

Functions take `Account`, not `shared:locked Account`. This means your business logic remains pure and decoupled from your synchronization strategy.

### Refactoring Blast Radius: Zero
If you need to change from a `Mutex` (`shared:locked`) to an `RwLock` (`shared:writeLocked`), you only change the definition in the Struct. Your functions don't change because they never knew about the capability in the first place.

## Rust - This is Safe?

```rust
// Rust infection: capabilities (Arc, RwLock) are part of the type system
struct Cache {
    sharedItems: Arc<RwLock<HashMap<String, Arc<RwLock<Account>>>>>,
}

// Function signatures are infected by the capabilities
fn transfer(from: &Arc<RwLock<Account>>, to: &Arc<RwLock<Account>>, amount: i32) {
    // Manual lock ordering required to avoid deadlock
    let (first, second, swap) = if Arc::as_ptr(from) < Arc::as_ptr(to) {
        (from, to, false)
    } else {
        (to, from, true)
    };
    // ...
}
```

### The Safety Gap

 * Rust guarantees you will not have a data race (memory corruption).
 * It does not guarantee you will avoid a deadlock (program halt).
 * CLEAR guarantees both by managing lock acquisition order and separating capabilities from types.

## Swift - This is Ergonomic?

Swift's Actors introduce **Reentrancy**. If you `await` inside an actor, the state can change underneath you, leading to logic races. CLEAR avoids this by using explicit `WITH` scopes that maintain invariants.

## Go - This is Simple?

In Go, Mutexes are just structs. If you accidentally pass an `Account` by value, you copy the Mutex, and you're now protecting nothing. CLEAR treats capabilities as compiler-enforced metadata, making this error impossible.

## C - YOLO

C is both memory-unsafe and liveness-unsafe. CLEAR is the simplest language that is both memory-safe and liveness-safe.

---

CLEAR rests its case. It is both:
1. The *simplest* language for concurrency.
2. The only *liveness-safe* language that prevents deadlocks by design.
