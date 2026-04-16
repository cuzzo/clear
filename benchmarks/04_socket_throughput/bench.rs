// Socket Throughput Benchmark — Rust Baseline
//
// TCP loopback: writer thread sends 100,000 × 256-byte messages, reader
// reads until all 25,600,000 bytes received using a 4096-byte stack
// buffer. Zero heap allocation in the read loop.
//
// Timer covers only the read loop (matches CLEAR's BENCH_RESULT scope).

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::Instant;

const N: usize = 100_000;
const MSG_SIZE: usize = 256;
const TOTAL: usize = N * MSG_SIZE;
const PORT: u16 = 14539;

fn main() {
    let listener = TcpListener::bind(("127.0.0.1", PORT)).expect("bind failed");

    let writer = thread::spawn(move || {
        let mut stream = TcpStream::connect(("127.0.0.1", PORT)).expect("connect failed");
        let msg = [b'X'; MSG_SIZE];
        for _ in 0..N {
            stream.write_all(&msg).expect("write failed");
        }
    });

    let (mut reader, _) = listener.accept().expect("accept failed");

    let start = Instant::now();

    let mut buf = [0u8; 4096];
    let mut total_bytes: usize = 0;
    while total_bytes < TOTAL {
        let n = reader.read(&mut buf).expect("read failed");
        assert!(n > 0);
        total_bytes += n;
    }

    let elapsed_ms = start.elapsed().as_secs_f64() * 1e3;
    writer.join().expect("writer panicked");

    println!("BENCH_RESULT: {:.0} ms", elapsed_ms);
    println!("total_bytes = {}", total_bytes);
    println!("Throughput: {:.0} MB/s", TOTAL as f64 / (elapsed_ms / 1e3) / 1e6);
}
