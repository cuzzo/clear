// Socket Throughput Benchmark — Rust Baseline
//
// Same pattern as bench.c: writer thread sends 100,000 × 256-byte messages
// through a Unix socket, reader thread measures read throughput with a
// stack-allocated [u8; 4096] buffer (zero heap allocation in the hot path).

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::thread;
use std::time::Instant;

const N: usize = 100_000;
const MSG_SIZE: usize = 256;

fn main() {
    let (mut reader, mut writer) = UnixStream::pair().expect("socketpair failed");

    let writer_handle = thread::spawn(move || {
        let msg = [b'X'; MSG_SIZE];
        for _ in 0..N {
            writer.write_all(&msg).expect("write failed");
        }
    });

    let start = Instant::now();

    // Stack buffer — zero heap allocation in the read loop.
    let mut buf = [0u8; MSG_SIZE];
    let mut total_bytes: usize = 0;
    for _ in 0..N {
        reader.read_exact(&mut buf).expect("read failed");
        total_bytes += buf.len();
    }

    let elapsed = start.elapsed().as_secs_f64();

    writer_handle.join().expect("writer thread panicked");

    println!("reads = {}", N);
    println!("total_bytes = {}", total_bytes);
    println!("Time: {:.4} seconds", elapsed);
    println!("Throughput: {:.2} M reads/sec", N as f64 / elapsed / 1e6);
}
