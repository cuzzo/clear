// Footgun: Use-After-Free — Rust
//
// Rust's ownership system makes UAF a compile-time error.
// Every value has exactly one owner. When ownership moves (or the
// owner drops), the value is gone. The compiler tracks this statically
// and rejects any subsequent use at the call site — no runtime needed.

#[derive(Debug)]
struct Player {
    name: String,
    score: i32,
}

fn consume(_p: Player) {
    // Takes ownership; Player is dropped at end of this function.
}

fn main() {
    let p = Player { name: "Alice".to_string(), score: 100 };
    println!("before: {:?}", p);

    consume(p); // ownership moves into consume(); p is gone

    // compile error: use of moved value: `p`
    // println!("after: {:?}", p);

    // ----------------------------------------------------------------
    // Dangling reference: also caught at compile time via lifetimes.
    // The borrow checker ensures a reference cannot outlive its owner.

    let reference: &Player;
    {
        let local = Player { name: "Bob".to_string(), score: 50 };
        // compile error: `local` does not live long enough
        // reference = &local;
        let _ = local;
    }
    // using `reference` here would be UAF in C; Rust rejects it above.
    let _ = reference; // suppressed: the above line is commented out
}

// Compile: rustc main.rs
// Uncommenting the flagged lines produces:
//   error[E0382]: use of moved value: `p`
//   error[E0597]: `local` does not live long enough
