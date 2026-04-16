// SROA Benchmark — Rust Baseline
//
// BigVec has 130 i64 fields (1040 bytes). sum3() reads only x1, x2, x3.
// 127 of the 130 field initialisations are dead.
//
// Rust's LLVM applies SROA + DCE identically to C when using integers.
// (Float benchmarks are skipped here — fast-math makes float SROA results
// incomparable across languages. See planned fastmath benchmark in README.)
//
// black_box(acc) prevents LLVM from constant-folding the loop while still
// allowing SROA to decompose the struct within each iteration.
// acc is reduced mod 1_000_000_007 to stay bounded.
//
// N = 100_000_000 iterations.

use std::hint::black_box;
use std::time::Instant;

#[derive(Clone, Copy, Default)]
struct BigVec {
    x1: i64, x2: i64, x3: i64, x4: i64, x5: i64,
    x6: i64, x7: i64, x8: i64, x9: i64, x10: i64,
    x11: i64, x12: i64, x13: i64, x14: i64, x15: i64,
    x16: i64, x17: i64, x18: i64, x19: i64, x20: i64,
    x21: i64, x22: i64, x23: i64, x24: i64, x25: i64,
    x26: i64, x27: i64, x28: i64, x29: i64, x30: i64,
    x31: i64, x32: i64, x33: i64, x34: i64, x35: i64,
    x36: i64, x37: i64, x38: i64, x39: i64, x40: i64,
    x41: i64, x42: i64, x43: i64, x44: i64, x45: i64,
    x46: i64, x47: i64, x48: i64, x49: i64, x50: i64,
    x51: i64, x52: i64, x53: i64, x54: i64, x55: i64,
    x56: i64, x57: i64, x58: i64, x59: i64, x60: i64,
    x61: i64, x62: i64, x63: i64, x64: i64, x65: i64,
    x66: i64, x67: i64, x68: i64, x69: i64, x70: i64,
    x71: i64, x72: i64, x73: i64, x74: i64, x75: i64,
    x76: i64, x77: i64, x78: i64, x79: i64, x80: i64,
    x81: i64, x82: i64, x83: i64, x84: i64, x85: i64,
    x86: i64, x87: i64, x88: i64, x89: i64, x90: i64,
    x91: i64, x92: i64, x93: i64, x94: i64, x95: i64,
    x96: i64, x97: i64, x98: i64, x99: i64, x100: i64,
    x101: i64, x102: i64, x103: i64, x104: i64, x105: i64,
    x106: i64, x107: i64, x108: i64, x109: i64, x110: i64,
    x111: i64, x112: i64, x113: i64, x114: i64, x115: i64,
    x116: i64, x117: i64, x118: i64, x119: i64, x120: i64,
    x121: i64, x122: i64, x123: i64, x124: i64, x125: i64,
    x126: i64, x127: i64, x128: i64, x129: i64, x130: i64,
}

fn sum3(v: BigVec) -> i64 {
    v.x1 + v.x2 + v.x3
}

fn main() {
    let start = Instant::now();

    let mut acc: i64 = 1;
    for _ in 0..100_000_000_i64 {
        let a = black_box(acc);
        let bv = BigVec { x1: a, x2: a + 1, x3: a + 2, ..Default::default() };
        acc = sum3(bv) % 1_000_000_007;
    }

    assert!(acc > 0);

    let duration = start.elapsed();
    println!("acc = {}", acc);
    println!("Time: {:.4} seconds", duration.as_secs_f64());
}
