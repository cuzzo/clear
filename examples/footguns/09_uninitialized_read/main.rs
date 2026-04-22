// Footgun: Uninitialized Read — Rust
//
// Rust makes uninitialized reads a compile-time error. The compiler tracks
// initialization state for every variable through definite-assignment
// analysis. If any path through the function might leave a variable
// uninitialized before it is used, the program will not compile.
//
// `MaybeUninit<T>` exists for performance-critical cases (e.g., large
// stack arrays where zeroing is measurable overhead), but reading from it
// requires `unsafe` and an explicit `assume_init()` call — making the
// risk visible and auditable.

// COMPILE ERROR: use of possibly-uninitialized variable `x`
// fn uninitialized_local() {
//     let x: i32;
//     println!("x = {}", x); // error[E0381]: used binding `x` isn't initialized
// }

// COMPILE ERROR: `sum` may be used uninitialized.
// fn conditional_init(n: i32) -> i32 {
//     let sum: i32;
//     if n > 0 {
//         sum = 0; // only initialized in one branch
//     }
//     sum // error[E0381]: used binding `sum` isn't initialized
// }

// CORRECT: compiler forces every path to initialize.
fn conditional_init(n: i32) -> i32 {
    // Option 1: initialize at declaration
    let mut sum = 0i32;
    for i in 0..n {
        sum += i;
    }
    sum
}

// CORRECT: structs must have every field initialized at construction.
// There is no partial struct literal — every field must appear.
#[derive(Debug)]
struct Triple {
    a: i32,
    b: i32,
    c: i32,
}

fn init_struct() -> Triple {
    // COMPILE ERROR if any field is omitted:
    //   Triple { a: 1, b: 2 } -- error[E0063]: missing field `c`
    Triple { a: 1, b: 2, c: 0 }
}

fn main() {
    // uninitialized_local(); // doesn't compile
    println!("conditional_init(0) = {}", conditional_init(0));

    let t = init_struct();
    println!("t = {:?}", t);
}

// Compile: rustc main.rs -o uninit_rs && ./uninit_rs
//
// Key insight: Rust's definite-assignment analysis is performed by the
// borrow checker. It is a compile-time guarantee, not a runtime check.
// The cost is zero: no initialization overhead, no runtime tracking.
// `MaybeUninit<T>` provides an escape hatch when zero-initialization
// is genuinely too expensive, but requires `unsafe` to read.
