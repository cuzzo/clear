# SHARED MUTABLE DEATH

## CHEAT - The Unfair Advantage

```ruby
STRUCT Account {
  balance: Float64,
}

STRUCT Cache {
  sharedItems: Locked<HashMap<String, Locked<Account>>,
}

FN insert(cache: Cache, id: String, account: TAKES Account) ->
  sharedAccount = Locked.new(account);
  WITH sharedItems AS MUT items {
    items.insert(id, GIVE sharedAccount);
  }
END

FN get(cache: Cache, id: String) RETURNS Locked<Account> ->
  RETURN LOAN(items.get(id));
END

FN transact(cache: Cache) ->
  -- Lock order automatically sorted
  WITH cache.get("a") AS MUT a, cache.get("b") AS MUT b {
    a.balance += 10;
    b.balance -= 10;
  }
END
```

 * What can go wrong? Nothing.
 * What is confusing? If you have minimal database experience (the vast majority of programmers in the world), nothing.

## Rust - This is Safe?

```rust
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

struct Account {
    balance: f64,
}

impl Account {
    fn new(balance: f64) -> Self {
        Account { balance }
    }
}

struct Cache {
    sharedItems: Arc<RwLock<HashMap<String, Arc<RwLock<Account>>>>>,
}

impl Cache {
    fn new() -> Self {
        Cache {
            sharedItems: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    fn insert(&self, key: String, value: Account) {
        let shared_value = Arc::new(RwLock::new(value)); // Wrap for sharing.
        let mut map = self.items.write().unwrap(); // Acquire lock to safely insert data into map
        map.insert(key, shared_value);
        // Lock released here - HashMap lock is NOT held during data operations
    }

    fn get(&self, key: &str) -> Option<Arc<RwLock<Account>>> {
        let map = self.items.read().unwrap(); // Acquire lock to safely read data
        map.get(key).cloned(); // Important: Return a clone of the Arc - not of the Account!
        // Lock released here - HashMap lock is NOT held during data operations
    }
}

fn unsafeTransfer(cache: Cache) {
    let cache = Arc::new(Cache::new());

    // Get references to items
    let item_a = cache.get("a").unwrap();
    let item_b = cache.get("b").unwrap();

    // SAFE: Acquire locks in consistent order (lexicographic by key)
    // to prevent deadlock
    let mut a = item_a.write().unwrap();
    let mut b = item_b.write().unwrap();

    a.balance += 10;  // increment a
    b.balance -= 10;  // decrement b

    // DANGER ZONE - Things that can go wrong:

    // 1. DEADLOCK - Acquiring locks in different orders
    // Thread 1: lock(a) then lock(b)
    // Thread 2: lock(b) then lock(a)
    // Both threads will wait forever!

    // 2. PANIC ON UNWRAP - If another thread panicked while holding lock
    // let a = item_a.write().unwrap(); // This will panic if lock is poisoned

    // 3. HOLDING LOCKS TOO LONG - Blocks all other threads
    // {
    //     let _a = item_a.write().unwrap();
    //     std::thread::sleep(std::time::Duration::from_secs(10)); // BAD!
    // }

    // 4. READING STALE DATA - If you don't lock for entire transaction
    // let a_val = *item_a.read().unwrap();  // Read a
    // // Another thread modifies both a and b here!
    // let b_val = *item_b.read().unwrap();  // Read b
    // // Now a_val + b_val might not equal expected invariant!

    // 5. WRITE-WRITE RACE - Multiple writers without proper ordering
    // Thread 1: write(a), write(b)
    // Thread 2: write(a), write(b)
    // Final state depends on interleaving!

    // 6. FORGETTING TO DROP LOCKS - Locks released at end of scope
    // If you store the guard, you hold the lock until guard is dropped
    // let guard = item_a.write().unwrap();
    // do_long_computation(); // Lock held entire time!

    // 7. ARC LEAK - If you create reference cycles
    // Rust's Arc prevents most issues but weak refs can still leak
}

// SAFE PATTERN: Always acquire locks in same order
fn transfer(from: &Arc<RwLock<i32>>, to: &Arc<RwLock<i32>>, amount: i32) {
    // Use pointer addresses to create consistent ordering
    let (first, second, swap) = if Arc::as_ptr(from) < Arc::as_ptr(to) {
        (from, to, false)
    } else {
        (to, from, true)
    };

    let mut first_lock = first.write().unwrap();
    let mut second_lock = second.write().unwrap();

    if swap {
        *second_lock += amount;
        *first_lock -= amount;
    } else {
        *first_lock -= amount;
        *second_lock += amount;
    }
}
```

## Swift - This is Ergonomic?

```swift
class Account {
    var balance: Double

    init(balance: Double) {
        self.balance = balance
    }
}

class Cache {
    private var items: [String: Item] = [:]
    private let itemsLock = NSLock()

    class Item {
        private var account: Account
        private var lock = pthread_rwlock_t()

        init(_ account: Account) {
            self.account = account
            pthread_rwlock_init(&lock, nil)
        }

        deinit {
            pthread_rwlock_destroy(&lock)
        }

        func read<T>(_ block: (Account) -> T) -> T {
            pthread_rwlock_rdlock(&lock)
            defer { pthread_rwlock_unlock(&lock) }
            return block(account)
        }

        func write(_ block: (inout Account) -> Void) {
            pthread_rwlock_wrlock(&lock)
            defer { pthread_rwlock_unlock(&lock) }
            block(&account)
        }

        func unsafeLock() {
            pthread_rwlock_wrlock(&lock)
        }

        func unsafeUnlock() {
            pthread_rwlock_unlock(&lock)
        }

        func unsafeAccount() -> Account {
            return account
        }
    }

    func insert(key: String, account: Account) {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        items[key] = Item(account)
        // Lock released - dictionary NOT held during account operations
    }

    // Returns reference to Item
    // ONLY locks the items dictionary briefly
    func get(key: String) -> Item? {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        return items[key]
        // Lock released - dictionary NOT held during account operations
    }
}

// If you don't do EXACTLY this, in this order, you have even more room for failure than Rust
func transfer(from: Cache.Item, to: Cache.Item, amount: Double) {
    let fromId = ObjectIdentifier(from)
    let toId = ObjectIdentifier(to)

    let (first, second, swap) = fromId < toId
        ? (from, to, false)
        : (to, from, true) // Don't forget to order the locks or you're deadlocked.

    first.unsafeLock()
    second.unsafeLock()
    defer {
        second.unsafeUnlock() // Don't forget to defer unlocking, or you're deadlocked.
        first.unsafeUnlock()
    }

    if swap {
        to.unsafeAccount().balance += 10
        from.unsafeAccount().balance -= 10
    } else {
        from.unsafeAccount().balance -= 10
        to.unsafeAccount().balance += 10
    }
}
```

## Go - This is Simple?
```go
import (
	"sync"
	"unsafe"
)

type Account struct {
	balance float64
	// In Go, you mix data and locks in the same struct.
	// WARNING: If you copy this struct (pass by value), you copy the mutex state!
	// You now have two different locks protecting nothing.
	mu sync.Mutex
        // Hope is a bad strategy
}

type Cache struct {
	items map[string]*Account
	mu    sync.RWMutex
}

func (c *Cache) Insert(id string, account *Account) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.items[id] = account
}

func (c *Cache) Get(id string) *Account {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.items[id] // Returns pointer to shared mutable state
}

// The "Simple" Naive Approach
func UnsafeTransfer(cache *Cache) {
	a := cache.Get("a")
	b := cache.Get("b")

	// DANGER: Naive locking order
	// Goroutine 1: Transfer A -> B
	// Goroutine 2: Transfer B -> A
	// Result: DEADLOCK.
	a.mu.Lock()
	defer a.mu.Unlock()

	// Simulate work to ensure deadlock happens
	// time.Sleep(1 * time.Millisecond)

	b.mu.Lock()
	defer b.mu.Unlock()

	a.balance -= 10
	b.balance += 10
}

// The "Safe" Approach
// Go does not allow comparing pointers with '<'.
// You must import "unsafe" to do basic concurrency safety patterns.
func SafeTransfer(a, b *Account) {
	// 1. Convert pointers to integers to sort them
	ptrA := uintptr(unsafe.Pointer(a))
	ptrB := uintptr(unsafe.Pointer(b))

	// 2. Lock in deterministic order
	if ptrA < ptrB {
		a.mu.Lock()
		b.mu.Lock()
	} else {
		b.mu.Lock()
		a.mu.Lock()
	}

	// 3. Defer unlocks (LIFO)
	defer b.mu.Unlock()
	defer a.mu.Unlock()

	// 4. Do the work
	a.balance -= 10
	b.balance += 10
}
```

## C - YOLO
```c
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>

typedef struct {
    double balance;
    pthread_mutex_t lock; // Hope you remember to init this. And destroy it.
} Account;

// C doesn't have a HashMap. You write your own.
// It will probably have bugs.
typedef struct Node {
    char* key;
    Account* value;
    struct Node* next;
} Node;

typedef struct {
    Node* buckets[100]; // Fixed size because resizing is hard.
    pthread_rwlock_t global_lock;
} Cache;

Account* create_account(double bal) {
    Account* a = malloc(sizeof(Account));
    if (!a) exit(1); // Standard error handling strategy: crash.
    a->balance = bal;
    // If you forget this line, undefined behavior later.
    pthread_mutex_init(&a->lock, NULL);
    return a;
}

// THE "YOLO" TRANSFER
void transfer(Account* a, Account* b, double amount) {
    if (!a || !b) return; // Null check? Maybe.

    // LOCK ORDERING?
    // In C, pointer comparison is strictly only defined within the same array.
    // Comparing two malloc'd pointers is technically Undefined Behavior (UB)
    // depending on your compiler interpretation, but everyone does it anyway.
    if (a < b) {
        pthread_mutex_lock(&a->lock);
        pthread_mutex_lock(&b->lock);
    } else {
        pthread_mutex_lock(&b->lock);
        pthread_mutex_lock(&a->lock);
    }

    a->balance -= amount;
    b->balance += amount;

    // NO RAII / NO DEFER
    // If you return early here, you deadlock the program.
    // if (some_error) return; // <--- DEATH

    pthread_mutex_unlock(&a->lock);
    pthread_mutex_unlock(&b->lock);
}

void disaster_scenario(Cache* c) {
    // 1. Get a pointer to an account
    pthread_rwlock_rdlock(&c->global_lock);
    Account* a = c->buckets[0]->value;
    pthread_rwlock_unlock(&c->global_lock);

    // 2. MEANWHILE, IN ANOTHER THREAD:
    // Some other thread deletes 'a' and frees the memory.

    // 3. BACK IN THIS THREAD:
    // We try to lock 'a'.
    // 'a' is now a dangling pointer pointing to freed memory.
    // SEGFAULT (Best case).
    // SILENT DATA CORRUPTION (Worst case).
    pthread_mutex_lock(&a->lock);
}
```
