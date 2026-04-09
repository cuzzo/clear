// SOA vs AOS Layout Benchmark -- Rust
//
// Particle simulation: N particles, M iterations of position update.
// 16 fields per particle (128 bytes). Hot loop touches only x/vx/y/vy.
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust

use std::time::Instant;

const N_PARTICLES: usize = 10_000;
const ITERATIONS: usize = 100;

#[allow(dead_code)]
struct Particle {
    x: f64, y: f64, z: f64,
    vx: f64, vy: f64, vz: f64,
    mass: f64, radius: f64, charge: f64,
    ax: f64, ay: f64, az: f64,
    age: f64, energy: f64, temperature: f64, pressure: f64,
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

    println!("Particles:   {}  (128 bytes/particle, 16 fields)", N_PARTICLES);
    println!("Iterations:  {}", ITERATIONS);
    println!("AOS:         {:.1} ms", aos_ms);
    println!("SOA:         {:.1} ms", soa_ms);
    println!("Speedup:     {:.2}x", aos_ms / soa_ms);
}
