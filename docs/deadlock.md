# Deadlock in CLEAR

**Matrix row:** Deadlock — C: F, Rust: F, Go: F, Pony: A+, BEAM: A+, CLEAR: A-*

The asterisk: CLEAR uses locks for read-heavy workloads where MVCC unpredictability is a non-starter. Locks can deadlock in standard mode. CLEAR provides runtime detection + recovery, and `STRICT EXTREME` (roadmap) will add compile-time lock-ordering enforcement.

---

## Why the AB/BA Pattern Is Not the Main CLEAR Footgun

The classic two-thread deadlock (thread A holds lock 1, waits for lock 2; thread B holds lock 2, waits for lock 1) requires two actors holding their respective lock simultaneously. In CLEAR's cooperative fiber scheduler, fibers only yield at explicit yield points (`NEXT`, I/O). There is no yield between acquiring the first lock and acquiring the second inside a `WITH EXCLUSIVE` block, so the AB/BA cycle cannot form on a single scheduler: the first fiber grabs both locks before the second fiber ever runs.

The AB/BA pattern does become dangerous with `@parallel` (multi-scheduler, multiple OS threads), because the fibers then run on different OS threads simultaneously. But in the common single-scheduler case, it is not the footgun to worry about.

---

## The Real Footgun: Re-Entrant Locking

CLEAR's `@locked` uses a non-recursive `pthread_mutex_t`. If a fiber tries to acquire a lock it already holds, `pthread_mutex_lock` blocks the OS thread — and since the fiber holding the lock IS that OS thread, it can never release it. Deadlock.

```ruby clear illustrative
STRUCT State { value: Int64 }

FN main() RETURNS Void ->
    s = State{ value: 0 } @locked;

    t = BG {
        WITH EXCLUSIVE s AS outer {
            outer.value = 1;
            # DEADLOCK: trying to re-acquire the same mutex this fiber holds.
            # pthread_mutex_lock blocks the OS thread. The lock is never
            # released because the releaser IS the blocked fiber.
            WITH EXCLUSIVE s AS inner {
                inner.value = 2;
            }
        }
    };

    NEXT t;  # hangs here
END
```

This compiles without error and hangs at runtime.

**Fix:** restructure so the same lock is never acquired twice on the same call path. Pass the already-locked inner value to helper functions instead of locking again:

```ruby clear illustrative
FN update_inner(inner: State) RETURNS Void ->
    # Takes the already-unlocked value; no lock needed here.
    inner.value = 2;
END

FN main() RETURNS Void ->
    s = State{ value: 0 } @locked;

    t = BG {
        WITH EXCLUSIVE s AS inner {
            inner.value = 1;
            update_inner(inner);  # pass the unlocked value, not the lock
        }
    };

    NEXT t;
END
```

---

## The NEXT-Inside-WITH Footgun

A subtler variant: fiber A holds a lock and calls `NEXT` on a promise produced by fiber B — but fiber B also needs that lock to complete.

```ruby clear illustrative
STRUCT State { value: Int64 }

FN main() RETURNS Void ->
    s = State{ value: 0 } @locked;

    producer = BG {
        # producer needs 's' to do its work
        WITH EXCLUSIVE s AS inner {
            inner.value = 42;
        }
    };

    consumer = BG {
        WITH EXCLUSIVE s AS outer {
            # consumer holds 's', then waits for producer
            NEXT producer;  # DEADLOCK: producer can't acquire 's' — consumer holds it
            print(outer.value.toString());
        }
    };

    NEXT consumer;  # hangs here
END
```

The fiber holding the lock yields via `NEXT`, but the lock is NOT released when a fiber yields — `WITH EXCLUSIVE` holds the lock for the duration of the block, not just until the next yield point. The producer is stuck waiting for the lock that the consumer holds while waiting for the producer.

**Fix:** resolve the promise before entering the lock, or restructure so the two operations don't depend on each other:

```ruby clear illustrative
FN main() RETURNS Void ->
    s = State{ value: 0 } @locked;

    producer = BG {
        WITH EXCLUSIVE s AS inner {
            inner.value = 42;
        }
    };

    NEXT producer;  # wait for producer BEFORE acquiring the lock

    WITH s AS inner {
        print(inner.value.toString());  # 42
    }
END
```

---

## STRICT EXTREME: Compile-Time Lock Ordering (Roadmap)

In `STRICT EXTREME` mode (planned, not yet implemented), the compiler will enforce a global acquisition hierarchy via the `OwnershipGraph`. Re-entrant acquisition and AB/BA cycles will be detected at build time:

```
error: re-entrant lock acquisition
  fiber acquires 's' at line 8 (WITH EXCLUSIVE)
  then acquires 's' again at line 11 (WITH EXCLUSIVE)
  fix: pass the already-locked pointer to helper functions instead
```

See [docs/strict-extreme.md](strict-extreme.md) for the full STRICT EXTREME roadmap.

---

## Fix: Single Lock Scope (Always Safe)

Restructure so each operation needs only one lock at a time. No re-entrancy, no NEXT-inside-WITH:

```ruby clear illustrative
FN main() RETURNS Void ->
    a = Account{ balance: 100 } @locked;
    b = Account{ balance: 200 } @locked;

    t1 = BG {
        amount = 0;
        WITH EXCLUSIVE a AS ra {
            amount = ra.balance / 2;
            ra.balance = ra.balance - amount;
        }
        # a is unlocked here. No re-entrancy possible.
        WITH EXCLUSIVE b AS rb {
            rb.balance = rb.balance + amount;
        }
    };

    NEXT t1;
END
```

The tradeoff: releasing between the two operations creates a TOCTOU window (see [examples/footguns/05_toctou](https://github.com/cuzzo/clear/blob/master/examples/footguns/05_toctou/main.clear)).

---

## Why C, Go, and Rust Get F

All three languages expose the same non-recursive mutex with no re-entrancy detection and no built-in deadlock timeout:

- **C** (`pthread_mutex_lock`): hangs forever on re-entrant lock or AB/BA cycle. No detection without Helgrind or TSan.
- **Go** (`sync.Mutex`): hangs forever for partial deadlocks. Detects global deadlock (all goroutines blocked) with a panic. Race detector does not catch deadlocks.
- **Rust** (`std::sync::Mutex`): hangs forever. Attempting to lock from the same thread panics on some platforms (documented as "may panic or deadlock"). `parking_lot` adds optional cycle detection.

---

## Summary

| Pattern | Current CLEAR behavior | Planned fix |
|---|---|---|
| Re-entrant lock (same fiber re-acquires) | Hangs — non-recursive mutex | STRICT EXTREME: compile error |
| NEXT inside WITH (holding lock while awaiting) | Hangs — lock not released on yield | STRICT EXTREME: compile error |
| AB/BA across @parallel fibers | Hangs — same as C/Go/Rust | STRICT EXTREME: compile error |
| AB/BA on single scheduler | Does not occur — no yield between lock acquisitions | N/A |
