// Footgun: Memory Leak — Rust
//
// Rust's RAII (Drop trait) makes the common C leak pattern impossible:
// every heap allocation is tied to an owner, and the owner's destructor
// runs unconditionally when the owner goes out of scope — including on
// early returns and panics. No manual free() to forget.
//
// There are two intentional escape hatches that CAN leak:
//   mem::forget(v)  — explicitly suppresses Drop
//   Box::leak(b)    — intentionally converts a Box into a &'static ref
// Both require you to explicitly opt in. Accidental leaks via forgotten
// free() are not a category in safe Rust.

fn process(input: &str) -> Option<String> {
    let buf = format!("processed: {}", input); // heap allocation

    if input.starts_with('!') {
        return None; // buf is dropped here automatically — no leak
    }

    Some(buf) // ownership moves to caller
}

fn main() {
    // Happy path
    if let Some(r) = process("hello") {
        println!("{}", r);
    } // r dropped here

    // Error path: buf inside process() is dropped at the early return.
    // There is no leak.
    if process("!bad").is_none() {
        println!("error (no leak: Rust dropped buf at the early return)");
    }

    // -----------------------------------------------------------------
    // Intentional leak via mem::forget — requires explicit opt-in:
    let v = vec![1, 2, 3];
    std::mem::forget(v); // explicitly suppress Drop; v's memory leaks
    println!("intentional leak via mem::forget (requires explicit call)");

    // Box::leak for 'static references — also intentional:
    let s: &'static str = Box::leak(Box::new(String::from("static")));
    println!("leaked static ref: {}", s);
}

// Compile and run:  rustc main.rs -o leak && ./leak
// Valgrind will show the mem::forget and Box::leak allocations, which
// are intentional. The process() early-return path is leak-free.
