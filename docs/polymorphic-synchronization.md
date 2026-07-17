# Polymorphic Synchronization

CLEAR's synchronization model separates the shape of the data from the strategy used to protect it.

A function can say:

* I need to mutate a `Counter`.
* The caller may provide any compatible synchronization strategy.
* The compiler should pick the correct acquire / retry / direct-access path.

That is Polymorphic Synchronization.

Instead of baking `Mutex<T>`, `RwLock<T>`, `Versioned<T>`, or `AtomicPtr<T>`
into every API boundary, CLEAR keeps the function parameter data-shaped and
puts synchronization strategy at the declaration site.

> See [Sharing Capabilities](sharing-capabilities.md) for the ownership and
capability model this builds on.

> See [Tense Compositions](tense-composition.md)
for how capabilities compose with failable and temporal types.

## The Core Idea

The same function body can work across multiple storage strategies:

```ruby clear illustrative
STRUCT Counter { value: Int64 }

FN tick(MUTABLE c: SHARED Counter) RETURNS !Void ->
  WITH POLYMORPHIC c AS x {
    x.value = x.value + 1;
  }
  RETURN;
END
```

The binding passed to `tick` chooses the implementation:

```ruby clear illustrative
MUTABLE local_c     = Counter{ value: 0 } @local;
MUTABLE locked_c    = Counter{ value: 0 } @shared:locked;
MUTABLE wlocked_c   = Counter{ value: 0 } @shared:writeLocked;
MUTABLE versioned_c = Counter{ value: 0 } @shared:versioned;
MUTABLE atomic_c    = Counter{ value: 0 } @boxed:atomic;

tick(&local_c)     OR_ELSE RAISE;
tick(&locked_c)    OR_ELSE RAISE;
tick(&wlocked_c)   OR_ELSE RAISE;
tick(&versioned_c) OR_ELSE RAISE;
tick(&atomic_c)    OR_ELSE RAISE;
```

The compiler lowers each call to the strategy that matches the actual binding:

| Binding strategy | Lowering shape | Cost model |
|---|---|---|
| Plain `T`, `@local`, `@multiowned`, `@shared`, `@boxed` | Direct pointer access | No synchronization |
| `@locked`, `@shared:locked` | Mutex acquire / release | Blocking |
| `@writeLocked`, `@shared:writeLocked` | Write-lock acquire / release | Blocking |
| `@versioned`, `@shared:versioned` | Snapshot update with bounded retry | Contention / retry |
| `@boxed:atomic` | Atomic pointer update with bounded retry | Contention / retry |

The source stays data-shaped. The compiled code is strategy-shaped.

## Why It Matters

In Rust, changing `Arc<RwLock<T>>` to an MVCC cell or actor usually changes
the API shape and the function signatures above it. In Go, changing from a
mutex to a channel or shared-nothing layout tends to move synchronization
policy through the program by convention.

In CLEAR, the common refactor is declaration-site:

```ruby clear illustrative
MUTABLE sessions = SessionMap{ ... } @shared:locked;

# Later, after profiling:
MUTABLE sessions = SessionMap{ ... } @shared:versioned;
```

The functions that only pass the value through do not change. The functions
that actually cross a synchronization gate use `WITH`, so the blocking,
retrying, and failure points remain visible.

The practical benefits are:

* **Low blast radius:** strategy changes are usually localized to declarations
  and the small set of functions that directly synchronize.
* **Profile-guided tuning:** `clear profile` / `clear doctor` can point at a
  hot strategy and the code can often move to a different one without an API
  rewrite.
* **Honest cost visibility:** synchronization is visible at `WITH` blocks,
  not smeared across every type signature in a call chain.
* **No silent upgrades:** a function that requires a lock family cannot quietly
  accept a versioned cell, and a snapshot-only function cannot quietly acquire
  a mutex.

## REQUIRES Families

For public contracts, a function can constrain which synchronization families
it accepts with `REQUIRES`.

```ruby clear illustrative
FN bump(MUTABLE c: Counter)
  RETURNS !Void
  REQUIRES c: SNAPSHOTTED
->
  WITH SNAPSHOT c AS MUTABLE x {
    x.value = x.value + 1;
  }
  RETURN;
END
```

Current families:

| Family | Admits | Use when |
|---|---|---|
| `LOCKED` | `@locked`, `@writeLocked`, shared locked forms | The body can block while holding a lock |
| `SNAPSHOTTED` | `@versioned`, `@boxed:atomic` | The body can run as a retryable snapshot transaction |
| `VERSIONED` | `@versioned` only | MVCC behavior is required |
| `ATOMIC` | `@boxed:atomic` for structs | Atomic pointer behavior is required |
| `LOCAL` | Plain `T`, `@local`, `@multiowned` | The body should lower to direct local access |

`LOCKED` and `SNAPSHOTTED` are polymorphic families because each admits more
than one storage axis. `VERSIONED` and `ATOMIC` are narrow families used when
the exact strategy matters.

`ACTOR`, `BUFFERED`, and distributed actor-style capabilities are design
targets, but they are not part of the current public synchronization
polymorphism surface.

## WITH POLYMORPHIC

Use `WITH POLYMORPHIC` when the body must work for more than one possible
storage strategy.

```ruby clear illustrative
FN addFee(MUTABLE acct: SHARED Account)
  RETURNS !Void
  REQUIRES acct: LOCKED
->
  WITH POLYMORPHIC acct AS a {
    a.balance = a.balance - 1.0;
  }
  RETURN;
END
```

The compiler enforces the shape:

* Plain `WITH` on a polymorphic parameter is rejected.
* `WITH POLYMORPHIC` on a concrete local binding is rejected.
* `WITH POLYMORPHIC` on a narrow one-axis family, like `VERSIONED` or
  `ATOMIC`, is rejected; use the concrete access form instead.

This rule makes polymorphism visible at the synchronization boundary. If a
function can dispatch across strategies, the `WITH` block says so.

## Snapshot-Style Non-Polymorphic Synchronization

Snapshot-style strategies use `WITH SNAPSHOT`.

```ruby clear illustrative
FN updateConfig(MUTABLE cfg: Config@shared:versioned) RETURNS !Void ->
  WITH SNAPSHOT cfg AS MUTABLE c {
    c.port = c.port + 1;
  }
  RETURN;
END
```

The above accepts only MVCC. 

But `SNAPSHOTTED` polymorphic syncronization can accept both MVCC and atomic-pointer cells:

```ruby clear illustrative
FN updateConfig(MUTABLE cfg: SHARED Config)
  RETURNS !Void
  REQUIRES cfg: SNAPSHOTTED
->
  WITH POLYMORPHIC cfg AS MUTABLE c {
    c.port = c.port + 1;
  }
  RETURN;
END
```

```ruby clear illustrative
MUTABLE mvcc_cfg   = Config{ port: 8080 } @versioned;
MUTABLE atomic_cfg = Config{ port: 8080 } @boxed:atomic;

updateConfig(&mvcc_cfg) OR_ELSE RAISE;    # may surface MvccConflict
updateConfig(&atomic_cfg) OR_ELSE RAISE;  # may surface AtomicConflict
```

The body must be safe to retry. Fallible work inside a retryable body is
rejected because retrying the transaction would re-run the fallible operation.
Move parsing, I/O, and other fallible work outside the `WITH SNAPSHOT` or
universal `WITH POLYMORPHIC` body.

## Error Projection

Polymorphic synchronization does not mean every caller sees every possible
error.

The compiler projects the error set at each call site:

| Actual binding | Possible synchronization error |
|---|---|
| `@locked`, `@writeLocked` | `LockTimeout` |
| `@versioned` | `MvccConflict` |
| `@boxed:atomic` | `AtomicConflict` |

Example:

```ruby clear illustrative
FN tick(MUTABLE c: Counter)
  RETURNS !Void
  REQUIRES c: SNAPSHOTTED
->
  WITH SNAPSHOT c AS MUTABLE x {
    x.value = x.value + 1;
  }
  RETURN;
END

MUTABLE mvcc_c = Counter{ value: 0 } @versioned;
MUTABLE atomic_c = Counter{ value: 0 } @boxed:atomic;

tick(&mvcc_c);    # caller sees MvccConflict
tick(&atomic_c);  # caller sees AtomicConflict
```

Forwarding preserves the same narrowing. If a wrapper function accepts only
`VERSIONED` and forwards to a broader `SNAPSHOTTED` function, the inner call
still projects to `MvccConflict`, not the full snapshotted union.

## SYNC POLICY

Most retryable synchronization failures can be handled by a program-level
policy:

```ruby clear illustrative
SYNC POLICY START
  ON LockTimeout RETRY(3) THEN RAISE
  ON MvccConflict RAISE
  ON AtomicConflict RAISE
END
```

Precedence is:

1. Per-`WITH` `ON ...` handler.
2. Program `SYNC POLICY START ... END`.
3. Baked-in system default.

A per-`WITH` handler is the most local override:

```ruby clear illustrative
WITH
  SNAPSHOT cfg AS MUTABLE c {
    c.port = c.port + 1;
  }
  ON MvccConflict RETRY(2) THEN RAISE
```

`SYNC POLICY` is intentionally limited:

* Only one policy is allowed per program.
* It must live in the file that contains `FN main`.
* It must cover `LockTimeout`, `MvccConflict`, and `AtomicConflict`.
* It cannot handle `Deadlock` or `LockCycle`.

`Deadlock` and `LockCycle` are inline-only. If the compiler cannot prove the
lock graph is safe, the `WITH` site must make the risk explicit:

```ruby clear illustrative
WITH
  POLYMORPHIC POSSIBLE_DEADLOCK a AS x {
    someLockingFunc(x, b);
  }
  ON Deadlock RAISE
```

The opt-out belongs beside the code that can produce the cycle.

CLEAR automatically sorts locks, so you can only encounter possible deadlock when calling a locking function inside the critical section.

```ruby clear illustrative
WITH
  EXCLUSIVE a AS x,
  EXCLUSIVE b AS y {
    someFunc(x, y);
  }
```

This can never deadlock.

> [!NOTE]
> In `STRICT` mode, all possible synchronization failures must be handled inline.

## Multi-Object Transactions

Multiple locked or versioned cells can be synchronized together when the
family supports that consistency model:

```ruby clear illustrative
FN transfer(MUTABLE a: SHARED Account, MUTABLE b: SHARED Account, amount: Float64)
  RETURNS !Void
  REQUIRES a, b: LOCKED | VERSIONED
->
  IF amount <= 0 -> RAISE Input, TransactionFailure, "Invalid Amount, must be positive";

  WITH
    POLYMORPHIC a AS acctA,
    POLYMORPHIC b AS acctB {
      IF acctA.balance < amount -> RAISE Input, TransactionFailure, "Balance too low";

      acctA.balance -= amount;
      acctB.balance += amount;
    }
  RETURN;
END
```

Atomic-pointer cells do not support multi-object consistency. A multi-binding
`WITH` that admits `ATOMIC` is rejected. Narrow the contract to `LOCKED` /
`VERSIONED`, or split the operation into single-cell updates if that is the
correct behavior.

## Relationship to WITH MATCH

`WITH MATCH` is the older explicit per-family dispatch form:

```ruby clear illustrative
WITH c AS x MATCH
  WHEN VERSIONED -> { result = x.value; }
  WHEN LOCKED    -> { result = x.value; }
END
```

Use `WITH POLYMORPHIC` when the body is genuinely the same across compatible
families. Use `WITH MATCH` when the implementation must differ by family.

## Current Coverage

The current implementation is covered by:

* Parser and annotator specs for `SYNC POLICY START`, `WITH POLYMORPHIC`,
  `REQUIRES`, family admission, and the polymorphic-iff rule.
* Error projection specs that verify concrete call sites collapse to
  `LockTimeout`, `MvccConflict`, or `AtomicConflict` as appropriate.
* Integration specs for handler precedence: inline `ON`, user `SYNC POLICY`,
  then baked-in default.
* Multi-object specs that reject any multi-cell transaction admitting
  `ATOMIC`.
* End-to-end transpile tests, especially
  `transpile-tests/350_polymorphic_unified_tick.clear`, which verifies one
  polymorphic mutation body across local, shared, locked, write-locked,
  versioned, and atomic-pointer storage.

There is not a dedicated checked-in fuzz corpus for polymorphic sync today.
The relevant protection is mostly unit specs plus targeted transpile tests.

## Mental Model

Think of a synchronized value as three separate things:

* The **type**: `Counter`
* The **strategy**: `@shared:locked`, `@versioned`, `@boxed:atomic`
* The **gate**: `WITH`, `WITH EXCLUSIVE`, `WITH POLYMORPHIC`, etc...

Most functions should care about the type. A few functions care about the
gate. Very few functions should care about the exact strategy.

Polymorphic Synchronization is what lets those three concerns stay separate.
