// Footgun: Iterator Invalidation — Rust
//
// Rust's borrow checker prevents iterator invalidation at compile time.
// An iterator borrows the collection immutably. Any attempt to mutate the
// collection (push, remove, clear) while the iterator is live is a
// compile-time error: you cannot hold a mutable reference to the collection
// while an immutable reference (the iterator) is alive.
//
// This rule makes the entire class of "container modified during iteration"
// bugs impossible in safe Rust. The compiler error message even points to
// the conflicting borrows.

fn main() {
    // COMPILE ERROR: push during iteration.
    // let mut v = vec![1, 2, 3];
    // for x in &v {
    //     v.push(*x * 10); // error: cannot borrow `v` as mutable because
    //                      // it is also borrowed as immutable
    // }

    // COMPILE ERROR: remove during iteration.
    // let mut v = vec![1, 2, 3, 4, 5];
    // for (i, &x) in v.iter().enumerate() {
    //     if x % 2 == 0 {
    //         v.remove(i); // error: cannot borrow `v` as mutable because
    //                      // it is also borrowed as immutable
    //     }
    // }

    // CORRECT: collect indices first, then modify — borrows don't overlap.
    let mut v = vec![1, 2, 3, 4, 5];
    let to_remove: Vec<usize> = v.iter()
        .enumerate()
        .filter(|(_, &x)| x % 2 == 0)
        .map(|(i, _)| i)
        .collect();
    for i in to_remove.iter().rev() {
        v.remove(*i);
    }
    println!("after removing evens: {:?}", v);

    // CORRECT: retain() — the idiomatic in-place filter.
    let mut v2 = vec![1, 2, 3, 4, 5];
    v2.retain(|&x| x % 2 != 0); // no iterator borrow during mutation
    println!("retain odds: {:?}", v2);

    // CORRECT: iterator chaining produces a new collection.
    let v3 = vec![1, 2, 3, 4, 5];
    let odds: Vec<i32> = v3.iter().filter(|&&x| x % 2 != 0).copied().collect();
    println!("filter new: {:?}", odds);

    // CORRECT: drain() removes while iterating — explicit ownership transfer.
    let mut v4 = vec![1, 2, 3, 4, 5];
    let evens: Vec<i32> = v4.drain_filter(|&mut x| x % 2 == 0).collect();
    println!("drained evens: {:?}, remaining: {:?}", evens, v4);
}

// Compile: rustc main.rs -o iter_rs && ./iter_rs
// (drain_filter requires nightly: rustc +nightly main.rs; or replace with retain)
//
// Key insight: Rust's iterator-invalidation safety comes from the same rule
// as alias mutation: you cannot hold &T and &mut T simultaneously. An
// iterator holds &T (shared borrow); push/remove require &mut T (mutable
// borrow) — these are mutually exclusive. The fix is always to separate
// the read phase (collect indices or values) from the mutation phase.
