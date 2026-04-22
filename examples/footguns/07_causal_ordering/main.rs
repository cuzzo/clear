// Footgun: Causal Message Ordering — Rust
//
// Rust's std::sync::mpsc channels are FIFO per sender and establish
// happens-before between send and receive on the same channel. But
// crossing channel boundaries in a relay pattern breaks the chain
// for any out-of-band shared state, exactly as in Go.
//
// Rust prevents data races (no unsynchronized access to sharedData),
// but it does not enforce causal ordering of messages across channels.
// The programmer must structure the code so that the data itself travels
// through the channel, not a separate signal about the data.

use std::sync::{mpsc, Arc, Mutex};
use std::thread;

// BROKEN: writer updates shared state, signals relay via ch1.
// Relay forwards signal via ch2. Reader checks shared state after ch2.
// The happens-before chain for shared_data is broken at the relay hop.
fn broken_relay() {
    let shared_data: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let (tx1, rx1) = mpsc::channel::<()>(); // writer → relay
    let (tx2, rx2) = mpsc::channel::<()>(); // relay  → reader

    let data_w = Arc::clone(&shared_data);
    let writer = thread::spawn(move || {
        *data_w.lock().unwrap() = "important result".to_string();
        tx1.send(()).unwrap(); // signal relay
    });

    let relay = thread::spawn(move || {
        rx1.recv().unwrap();
        // rx1 receive h-b tx1 send (writer's signal).
        // But tx2 send does NOT transitively carry shared_data's h-b to
        // the reader. The reader's rx2 receive only h-b tx2 send here.
        tx2.send(()).unwrap();
    });

    let data_r = Arc::clone(&shared_data);
    let reader = thread::spawn(move || {
        rx2.recv().unwrap();
        // Mutex acquire provides a barrier, so in practice this is safe
        // here because the Mutex itself provides sequential consistency.
        // However, if shared_data were an atomic or raw pointer instead,
        // the happens-before chain would be broken and we could observe
        // the pre-write value on weakly-ordered hardware.
        println!("broken relay: '{}'", data_r.lock().unwrap());
    });

    writer.join().unwrap();
    relay.join().unwrap();
    reader.join().unwrap();
}

// CORRECT: send the data through the channel; the channel carries
// both the value and the happens-before guarantee in one operation.
fn correct_relay() {
    let (tx1, rx1) = mpsc::channel::<String>(); // carries the data
    let (tx2, rx2) = mpsc::channel::<String>(); // carries the data

    let writer = thread::spawn(move || {
        tx1.send("important result".to_string()).unwrap();
    });

    let relay = thread::spawn(move || {
        let data = rx1.recv().unwrap(); // h-b: data is visible here
        tx2.send(data).unwrap();        // forward the data itself
    });

    let reader = thread::spawn(move || {
        let data = rx2.recv().unwrap(); // h-b: data guaranteed visible
        println!("correct relay: '{}'", data);
    });

    writer.join().unwrap();
    relay.join().unwrap();
    reader.join().unwrap();
}

fn main() {
    println!("--- broken relay (signal separate from data) ---");
    broken_relay();

    println!("--- correct relay (data through channel) ---");
    correct_relay();
}

// Compile: rustc main.rs -o causal && ./causal
//
// Key insight: happens-before is a property of specific synchronization
// operations, not of logical program flow. A relay that receives on ch1
// and sends on ch2 does not automatically propagate the h-b from ch1
// to the reader of ch2 unless the data itself moves through ch2.
