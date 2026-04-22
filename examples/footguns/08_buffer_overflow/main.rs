// Footgun: Buffer Overflow — Rust
//
// Rust performs bounds checking on every slice index operation in both
// debug AND release builds. An out-of-bounds index panics immediately;
// it never silently corrupts memory. Raw pointer arithmetic exists but
// is confined to `unsafe` blocks, which are explicit and auditable.
//
// The bounds check cost in release mode is the same as Go's (~1-3%).
// The compiler can sometimes elide the check when it can prove the index
// is in range at compile time (e.g., in a for..in loop over the slice).

fn bounds_checked() {
    let mut buf = vec![0u8; 4];

    // This panics at runtime (both debug and release):
    //   "index out of bounds: the len is 4 but the index is 10"
    // buf[10] = b'x';

    // Use get() for fallible access — returns Option<&T>, no panic.
    if let Some(b) = buf.get_mut(10) {
        *b = b'x';
        println!("wrote to index 10");
    } else {
        println!("index 10 out of range (len={})", buf.len());
    }

    for (i, b) in buf.iter_mut().enumerate() {
        *b = b'0' + i as u8;
    }
    println!("buf: {}", std::str::from_utf8(&buf).unwrap());
}

// Off-by-one: Rust's for loop uses ExactSizeIterator — can't overshoot.
fn off_by_one() {
    let arr = [0i32; 8];
    // arr[8] would panic. Using iter() makes the upper bound implicit.
    for (i, v) in arr.iter().enumerate() {
        let _ = (i, v);
    }
    println!("arr[7]={}", arr[7]);
}

// Show the panic explicitly using std::panic::catch_unwind.
fn show_panic() {
    let result = std::panic::catch_unwind(|| {
        let buf = vec![0u8; 4];
        let _ = buf[10]; // panics
    });
    match result {
        Ok(_) => println!("no panic"),
        Err(e) => println!("caught panic: {:?}", e),
    }
}

fn main() {
    println!("--- bounds-checked access ---");
    bounds_checked();

    println!("--- off-by-one (safe) ---");
    off_by_one();

    println!("--- explicit out-of-bounds (caught panic) ---");
    show_panic();
}

// Compile: rustc main.rs -o buf_rs && ./buf_rs
//
// Key insight: Rust's slice type carries its length. The compiler emits a
// bounds check for every `slice[i]` expression. Use `slice.get(i)` for
// fallible access that returns Option instead of panicking.
// unsafe { *ptr.add(10) } bypasses the check — only valid when you can
// prove the offset is in range by other means.
