// SOA vs AOS Layout Benchmark -- Rust
//
// Particle simulation: N particles, M iterations of position update.
// 16 fields per particle (128 bytes). Hot loop touches only x/vx/y/vy.
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust

use std::time::Instant;

const N_PARTICLES: usize = 100_000;
const ITERATIONS: usize = 100;

#[allow(dead_code)]
struct Particle {
    x: f64, y: f64, z: f64,
    vx: f64, vy: f64, vz: f64,
    mass: f64, radius: f64, charge: f64,
    ax: f64, ay: f64, az: f64,
    age: f64, energy: f64, temperature: f64, pressure: f64,
    r01: f64, r02: f64, r03: f64, r04: f64,
    r05: f64, r06: f64, r07: f64, r08: f64,
    r09: f64, r10: f64, r11: f64, r12: f64,
    r13: f64, r14: f64, r15: f64, r16: f64,
    r17: f64, r18: f64, r19: f64, r20: f64,
    r21: f64, r22: f64, r23: f64, r24: f64,
    r25: f64, r26: f64, r27: f64, r28: f64,
    r29: f64, r30: f64, r31: f64, r32: f64,
    r33: f64, r34: f64, r35: f64, r36: f64,
    r37: f64, r38: f64, r39: f64, r40: f64,
    r41: f64, r42: f64, r43: f64, r44: f64,
    r45: f64, r46: f64, r47: f64, r48: f64,
}

struct SoaParticles {
    x: Vec<f64>, y: Vec<f64>,
    vx: Vec<f64>, vy: Vec<f64>,
}

fn run_aos() -> (f64, f64) {
    let mut particles: Vec<Particle> = (0..N_PARTICLES)
        .map(|i| Particle {
            x: i as f64, y: i as f64 * 2.0, z: 0.0,
            vx: 1.0, vy: 0.5, vz: 0.0,
            mass: 1.0, radius: 0.1, charge: 0.0,
            ax: 0.0, ay: 0.0, az: 0.0,
            age: 0.0, energy: 0.0, temperature: 0.0, pressure: 0.0,
            r01: 0.0, r02: 0.0, r03: 0.0, r04: 0.0,
            r05: 0.0, r06: 0.0, r07: 0.0, r08: 0.0,
            r09: 0.0, r10: 0.0, r11: 0.0, r12: 0.0,
            r13: 0.0, r14: 0.0, r15: 0.0, r16: 0.0,
            r17: 0.0, r18: 0.0, r19: 0.0, r20: 0.0,
            r21: 0.0, r22: 0.0, r23: 0.0, r24: 0.0,
            r25: 0.0, r26: 0.0, r27: 0.0, r28: 0.0,
            r29: 0.0, r30: 0.0, r31: 0.0, r32: 0.0,
            r33: 0.0, r34: 0.0, r35: 0.0, r36: 0.0,
            r37: 0.0, r38: 0.0, r39: 0.0, r40: 0.0,
            r41: 0.0, r42: 0.0, r43: 0.0, r44: 0.0,
            r45: 0.0, r46: 0.0, r47: 0.0, r48: 0.0,
        })
        .collect();

    let t0 = Instant::now();
    for _ in 0..ITERATIONS {
        for p in particles.iter_mut() {
            p.x += p.vx;
            p.y += p.vy;
        }
    }
    let elapsed = t0.elapsed().as_secs_f64() * 1000.0;

    let sum: f64 = particles.iter().map(|p| p.x + p.y).sum();
    println!("AOS checksum: {:.0}", sum);
    (elapsed, sum)
}

fn run_soa() -> (f64, f64) {
    let mut soa = SoaParticles {
        x: (0..N_PARTICLES).map(|i| i as f64).collect(),
        y: (0..N_PARTICLES).map(|i| i as f64 * 2.0).collect(),
        vx: vec![1.0; N_PARTICLES],
        vy: vec![0.5; N_PARTICLES],
    };

    let t0 = Instant::now();
    for _ in 0..ITERATIONS {
        for i in 0..N_PARTICLES {
            soa.x[i] += soa.vx[i];
        }
        for i in 0..N_PARTICLES {
            soa.y[i] += soa.vy[i];
        }
    }
    let elapsed = t0.elapsed().as_secs_f64() * 1000.0;

    let sum: f64 = (0..N_PARTICLES).map(|i| soa.x[i] + soa.y[i]).sum();
    println!("SOA checksum: {:.0}", sum);
    (elapsed, sum)
}

fn main() {
    // Warm up
    run_aos();
    run_soa();

    let (aos_ms, _) = run_aos();
    let (soa_ms, _) = run_soa();

    // BENCH_RESULT = SOA (the fast path we compare against CLEAR)
    println!("BENCH_RESULT: {:.0} ms", soa_ms);
    println!("SOA vs AOS ({} particles x {} iters)", N_PARTICLES, ITERATIONS);
    println!("  AOS:         {:.1} ms", aos_ms);
    println!("  SOA:         {:.1} ms", soa_ms);
    println!("  Speedup:     {:.2}x", aos_ms / soa_ms);
}
