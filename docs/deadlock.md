# Deadlock in CLEAR

**Matrix row:** Deadlock — C: F, Rust: F, Go: F, Pony: A+, BEAM: A+, CLEAR: A-*

The asterisk: CLEAR uses locks for read-heavy workloads where MVCC unpredictability is a non-starter. Locks can deadlock in standard mode. CLEAR provides runtime detection + recovery, and `STRICT EXTREME` provides compile-time lock-ordering enforcement.

---

## The Classic Deadlock

Two fibers, two locks, opposite acquisition order:

```ruby clear illustrative
STRUCT Account { balance: Int64 }

FN main() RETURNS Void ->
    a = Account{ balance: 100 } @locked;
    b = Account{ balance: 200 } @locked;

    -- Fiber 1: acquires a, then tries to acquire b.
    t1 = BG {
        WITH EXCLUSIVE a AS ra {
            -- t1 holds a. If t2 is here simultaneously, t2 holds b.
            WITH EXCLUSIVE b AS rb {    -- blocks waiting for b
                rb.balance = rb.balance + ra.balance;
            }
        }
    };

    -- Fiber 2: acquires b, then tries to acquire a.
    t2 = BG {
        WITH EXCLUSIVE b AS rb {
            -- t2 holds b. If t1 is here simultaneously, t1 holds a.
            WITH EXCLUSIVE a AS ra {    -- blocks waiting for a — DEADLOCK
                ra.balance = ra.balance + rb.balance;
            }
        }
    };

    NEXT t1;
    NEXT t2;
END
```

CLEAR's cooperative scheduler means this deadlock is deterministic on a single scheduler — once t1 holds `a` and suspends waiting for `b` (which t2 holds), and t2 suspends waiting for `a` (which t1 holds), neither fiber can yield. On `CLEAR_THREADS > 1` with `@parallel`, the same cycle can occur across OS threads.

---

## Fix 1: Consistent Lock Ordering

Always acquire locks in the same global order. If every caller takes `a` before `b`, the cycle is impossible:

```ruby clear illustrative
FN transfer(src: Account @locked, dst: Account @locked, amount: Int64) RETURNS Void ->
    -- Both fibers acquire src first, then dst.
    -- As long as ALL callers follow this convention, no cycle can form.
    WITH EXCLUSIVE src AS s {
        WITH EXCLUSIVE dst AS d {
            d.balance = d.balance + amount;
            s.balance = s.balance - amount;
        }
    }
END

FN main() RETURNS Void ->
    a = Account{ balance: 100 } @locked;
    b = Account{ balance: 200 } @locked;

    -- Both fibers use the same src→dst order.
    t1 = BG { transfer(a, b, 50); };
    t2 = BG { transfer(a, b, 30); };

    NEXT t1;
    NEXT t2;
END
```

This is a convention, not a compiler guarantee in standard mode. See STRICT EXTREME below for the compile-time version.

---

## Fix 2: Single Lock Scope

Restructure so each operation needs only one lock at a time:

```ruby clear illustrative
FN main() RETURNS Void ->
    a = Account{ balance: 100 } @locked;
    b = Account{ balance: 200 } @locked;

    -- Read a, release lock; compute; acquire b, write.
    -- No two locks held simultaneously — deadlock structurally impossible.
    t1 = BG {
        amount = 0;
        WITH EXCLUSIVE a AS ra {
            amount = ra.balance / 2;
            ra.balance = ra.balance - amount;
        }
        -- a is unlocked here
        WITH EXCLUSIVE b AS rb {
            rb.balance = rb.balance + amount;
        }
    };

    NEXT t1;
END
```

The tradeoff: releasing between the two operations creates a TOCTOU window. Use this pattern when the two operations are not required to be atomic together.

---

## CLEAR's Runtime Mitigation

Standard-mode CLEAR locks detect when a fiber has been parked waiting for a mutex longer than the configured timeout. If the blocked task is marked `@killable`, the runtime terminates it with an error rather than hanging indefinitely:

```ruby clear illustrative
-- Illustrative — @killable and deadlock timeout are planned for v0.2
t1 = BG { @killable ->
    WITH EXCLUSIVE a AS ra {
        WITH EXCLUSIVE b AS rb {
            rb.balance = ra.balance;
        }
    }
};

-- If t1 deadlocks, the runtime kills it after the configured timeout
-- and NEXT returns an error instead of hanging.
result = NEXT t1 OR { print("task killed: deadlock timeout"); };
```

This turns a hang into a recoverable error. It does not prevent the deadlock — it limits the blast radius.

---

## STRICT EXTREME: Compile-Time Lock Ordering

In `STRICT EXTREME` mode the compiler enforces a global acquisition hierarchy via the `OwnershipGraph`. If any code path acquires `b` while holding `a`, but another path acquires `a` while holding `b`, the build fails:

```
error: lock cycle detected
  t1: acquires 'a' at line 12, then 'b' at line 14
  t2: acquires 'b' at line 20, then 'a' at line 22
  fix: establish a consistent acquisition order across all callers
```

This is a compile-time guarantee — the broken pattern from the first example above would not compile under `STRICT EXTREME`. No runtime overhead; the check is static.

See [docs/strict-extreme.md](strict-extreme.md) for the full STRICT EXTREME feature set.

---

## Why C, Go, and Rust Get F

All three languages give the programmer locks with no ordering enforcement and no built-in deadlock detection:

- **C** (`pthread_mutex_lock`): blocks forever on deadlock. No timeout by default. Requires manual `pthread_mutex_timedlock` or external tooling (Helgrind).
- **Go** (`sync.Mutex`): blocks forever. The race detector does not detect deadlocks; only Go's goroutine dump (Ctrl+C / SIGABRT) reveals the cycle after the fact.
- **Rust** (`std::sync::Mutex`): blocks forever. The borrow checker ensures memory safety but says nothing about lock ordering. `parking_lot` crate adds optional deadlock detection as a feature flag.

In all three, the programmer must either impose ordering by convention, use a single lock, or use a higher-level abstraction (channels, actors) to avoid locks entirely.

---

## Summary

| Approach | Prevents deadlock? | Cost |
|---|---|---|
| Consistent lock order (manual) | Yes, by convention | None (discipline only) |
| Single-lock-at-a-time restructure | Yes, structurally | May introduce TOCTOU window |
| `@killable` timeout recovery | No — limits blast radius | Slight runtime overhead |
| `STRICT EXTREME` lock ordering | Yes, at compile time | Build-time check only |
