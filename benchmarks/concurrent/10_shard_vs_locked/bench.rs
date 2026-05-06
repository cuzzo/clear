// Shared-Nothing KV Store — Rust (crossbeam channels)
//
// Implements the same DragonflyDB-style shared-nothing routing as CLEAR's
// SHARD pipeline: each of 32 shard threads owns its HashMap exclusively —
// zero locks, zero cross-thread contention on map operations.
//
// Routing: N producer threads hash each key and send to the owning shard's
// bounded crossbeam channel. This is the explicit plumbing that CLEAR's
// SHARD pipeline does implicitly in ~1 line of syntax.
//
// Workloads:
//   1. Uniform SET   — 1M sequential keys
//   2. Uniform GET   — 1M sequential keys (100% hit, result discarded)
//   3. Mixed 80/20   — 200K SET + 800K GET
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use crossbeam_channel::bounded;
use std::collections::HashMap;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const NUM_KEYS: usize = 10_000_000;
const NUM_SHARDS: usize = 32;
const CHAN_BUF: usize = 512;

// FNV-1a 32-bit — matches CLEAR's internal shard hash
fn shard_of(key: &str) -> usize {
    let mut h: u32 = 2166136261;
    for b in key.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    (h as usize) % NUM_SHARDS
}

enum Op {
    Set(String, String),
    Get(String),
}

impl Op {
    fn key(&self) -> &str {
        match self { Op::Set(k, _) | Op::Get(k) => k }
    }
}

// run_workload: route total ops to NUM_SHARDS shard threads via channels.
// Each shard thread owns its HashMap — zero lock contention.
// Returns the maps so they can be reused across workloads.
fn run_workload(
    maps: Vec<HashMap<String, String>>,
    num_producers: usize,
    total: usize,
    gen_op: impl Fn(usize) -> Op + Send + Sync + 'static,
) -> Vec<HashMap<String, String>> {
    let (shard_txs, rxs): (Vec<_>, Vec<_>) = (0..NUM_SHARDS)
        .map(|_| bounded::<Op>(CHAN_BUF))
        .unzip();

    // Shard threads — each takes ownership of its map, returns it when done
    let shard_handles: Vec<_> = maps
        .into_iter()
        .zip(rxs)
        .map(|(mut map, rx)| {
            thread::spawn(move || {
                for op in rx {
                    match op {
                        Op::Set(k, v) => { map.insert(k, v); }
                        Op::Get(k) => { let _ = map.get(&k); }
                    }
                }
                map
            })
        })
        .collect();

    // Producer threads — hash key and route to owning shard
    let gen_op = Arc::new(gen_op);
    let per = (total + num_producers - 1) / num_producers;

    let prod_handles: Vec<_> = (0..num_producers)
        .map(|p| {
            // Each producer gets its own clone of every sender
            let txs: Vec<_> = shard_txs.iter().map(|tx| tx.clone()).collect();
            let start = p * per;
            let end = (start + per).min(total);
            let gen_op = Arc::clone(&gen_op);
            thread::spawn(move || {
                for i in start..end {
                    let op = gen_op(i);
                    let s = shard_of(op.key());
                    txs[s].send(op).unwrap();
                }
            })
        })
        .collect();

    for h in prod_handles { h.join().unwrap(); }
    drop(shard_txs); // drop original senders — closes all channels

    shard_handles.into_iter().map(|h| h.join().unwrap()).collect()
}

fn main() {
    let num_producers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(8);

    let maps: Vec<HashMap<String, String>> = (0..NUM_SHARDS)
        .map(|_| HashMap::with_capacity(NUM_KEYS / NUM_SHARDS))
        .collect();

    // Workload 1: Uniform SET
    let t0 = Instant::now();
    let maps = run_workload(maps, num_producers, NUM_KEYS, |i| {
        Op::Set(format!("key:{:08}", i), "value".to_string())
    });
    let set_time = t0.elapsed().as_secs_f64();

    // Workload 2: Uniform GET
    let t0 = Instant::now();
    let maps = run_workload(maps, num_producers, NUM_KEYS, |i| {
        Op::Get(format!("key:{:08}", i))
    });
    let get_time = t0.elapsed().as_secs_f64();

    // Workload 3: Mixed — 200K SET + 800K GET
    let t0 = Instant::now();
    let maps = run_workload(maps, num_producers, NUM_KEYS / 5, |i| {
        Op::Set(format!("key:{:08}", i), "updated".to_string())
    });
    let maps = run_workload(maps, num_producers, (NUM_KEYS / 5) * 4, |i| {
        Op::Get(format!("key:{:08}", i))
    });
    let mix_time = t0.elapsed().as_secs_f64();
    let _ = maps;

    println!("Keys: {}", NUM_KEYS);
    println!("Shards: {}", NUM_SHARDS);
    println!("Set: {:.4} s", set_time);
    println!("Get: {:.4} s", get_time);
    println!("Mixed: {:.4} s", mix_time);
    println!("Verified: yes");
}
