// Footgun: Alias Mutation — Rust
//
// Rust's borrow checker enforces a fundamental rule: at any point in time,
// you can have EITHER one mutable reference (&mut T) OR any number of
// shared references (&T) to the same data — never both simultaneously.
//
// This rule makes alias mutation a compile-time error. There is no way
// to hold a shared reference and a mutable reference to the same data at
// the same time in safe Rust. The "restrict lie" from C cannot compile.
//
// Interior mutability (Cell<T>, RefCell<T>, Mutex<T>) provides controlled
// shared mutation with explicit opt-in, moving the check to runtime.

// COMPILE ERROR: cannot borrow `arr` as mutable because it is also
// borrowed as immutable.
// fn aliased_mutation() {
//     let arr = vec![1, 2, 3, 4];
//     let view = &arr[0]; // immutable borrow
//     arr.push(5);        // error: mutable borrow while immutable borrow live
//     println!("{}", view);
// }

// COMPILE ERROR: two mutable borrows of the same data.
// fn two_mutable() {
//     let mut x = 42;
//     let p = &mut x;
//     let q = &mut x; // error: cannot borrow `x` as mutable more than once
//     *p = 1;
//     *q = 2;
// }

// CORRECT: split borrows from disjoint parts of a struct are fine.
struct Pair {
    a: i32,
    b: i32,
}

fn split_borrow(pair: &mut Pair) {
    let pa = &mut pair.a; // borrow field a
    let pb = &mut pair.b; // borrow field b — disjoint, allowed
    *pa = 10;
    *pb = 20;
    // *pa and *pb refer to different memory; no aliasing
}

// CORRECT: use indices instead of references when you need to mutate
// while also reading from the same collection.
fn no_alias_via_index() {
    let mut v = vec![1, 2, 3, 4];
    // Instead of holding a &v[i] while mutating v[j], use indices.
    for i in 0..v.len() {
        v[i] *= 2;
    }
    println!("doubled: {:?}", v);
}

// Interior mutability: RefCell moves the borrow check to runtime.
use std::cell::RefCell;

fn interior_mutability() {
    let data = RefCell::new(vec![1, 2, 3]);
    let r1 = data.borrow();       // shared borrow
    // let r2 = data.borrow_mut(); // would panic at runtime: already borrowed
    println!("data[0] = {}", r1[0]);
    drop(r1); // release shared borrow
    data.borrow_mut().push(4);   // now mutable borrow is fine
    println!("after push: {:?}", data.borrow());
}

fn main() {
    let mut pair = Pair { a: 0, b: 0 };
    split_borrow(&mut pair);
    println!("pair = ({}, {})", pair.a, pair.b);

    no_alias_via_index();
    interior_mutability();
}

// Compile: rustc main.rs -o alias_rs && ./alias_rs
//
// Key insight: Rust's aliasing rule (&mut T XOR &T) is enforced at compile
// time, not runtime. The cost is zero for safe code. Interior mutability
// (RefCell, Mutex) trades the compile-time check for a runtime one, with
// a clear opt-in at the type level.
