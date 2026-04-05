// SROA Benchmark — Rust Baseline
//
// BigVec has 130 f64 fields; sum3() reads only x1,x2,x3.
// Rust's LLVM aggressively SROA's+DCE's the unused fields even through
// black_box/volatile — this measures SROA quality, not runtime speed.
// The Rust number is not directly comparable to C/CLEAR.

use std::time::Instant;

#[derive(Clone, Copy, Default)]
struct BigVec {
    x1: f64, x2: f64, x3: f64, x4: f64, x5: f64,
    x6: f64, x7: f64, x8: f64, x9: f64, x10: f64,
    x11: f64, x12: f64, x13: f64, x14: f64, x15: f64,
    x16: f64, x17: f64, x18: f64, x19: f64, x20: f64,
    x21: f64, x22: f64, x23: f64, x24: f64, x25: f64,
    x26: f64, x27: f64, x28: f64, x29: f64, x30: f64,
    x31: f64, x32: f64, x33: f64, x34: f64, x35: f64,
    x36: f64, x37: f64, x38: f64, x39: f64, x40: f64,
    x41: f64, x42: f64, x43: f64, x44: f64, x45: f64,
    x46: f64, x47: f64, x48: f64, x49: f64, x50: f64,
    x51: f64, x52: f64, x53: f64, x54: f64, x55: f64,
    x56: f64, x57: f64, x58: f64, x59: f64, x60: f64,
    x61: f64, x62: f64, x63: f64, x64: f64, x65: f64,
    x66: f64, x67: f64, x68: f64, x69: f64, x70: f64,
    x71: f64, x72: f64, x73: f64, x74: f64, x75: f64,
    x76: f64, x77: f64, x78: f64, x79: f64, x80: f64,
    x81: f64, x82: f64, x83: f64, x84: f64, x85: f64,
    x86: f64, x87: f64, x88: f64, x89: f64, x90: f64,
    x91: f64, x92: f64, x93: f64, x94: f64, x95: f64,
    x96: f64, x97: f64, x98: f64, x99: f64, x100: f64,
    x101: f64, x102: f64, x103: f64, x104: f64, x105: f64,
    x106: f64, x107: f64, x108: f64, x109: f64, x110: f64,
    x111: f64, x112: f64, x113: f64, x114: f64, x115: f64,
    x116: f64, x117: f64, x118: f64, x119: f64, x120: f64,
    x121: f64, x122: f64, x123: f64, x124: f64, x125: f64,
    x126: f64, x127: f64, x128: f64, x129: f64, x130: f64,
}

#[inline(never)]
fn sum3(v: BigVec) -> f64 {
    v.x1 + v.x2 + v.x3
}

fn main() {
    let start = Instant::now();

    let mut acc: f64 = 0.0;
    for _ in 0..100_000 {
        let mut bv = BigVec::default();
        bv.x1 = acc;
        bv.x2 = acc + 1.0;
        bv.x3 = acc + 2.0;
        // Pass through a volatile read to force the full struct to be materialized
        // on the stack, matching what C and CLEAR actually do.
        let ptr = &bv as *const BigVec;
        let bv = unsafe { std::ptr::read_volatile(ptr) };
        acc += sum3(bv);
    }

    assert!(acc > 0.0);

    let duration = start.elapsed();
    println!("acc = {:.6}", acc);
    println!("Time: {:.4} seconds", duration.as_secs_f64());
}
