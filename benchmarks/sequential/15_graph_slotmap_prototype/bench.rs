use std::cell::RefCell;
use std::env;
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant};

const EDGE_COUNT: usize = 4;

struct Node {
    value: u64,
    edges: [Weak<RefCell<Node>>; EDGE_COUNT],
}

fn capacity() -> usize {
    if let Ok(raw) = env::var("BENCH_N") {
        if let Ok(value) = raw.parse::<usize>() {
            if (4096..=1_048_576).contains(&value) {
                return value;
            }
        }
    }
    let scale = env::var("BENCH_SCALE")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(1.0);
    (1_000_000.0 * scale).max(4096.0) as usize
}

fn even_at_least(raw: usize, minimum: usize) -> usize {
    let value = raw.max(minimum);
    value + (value & 1)
}

fn local_target(i: u32, edge: u32, core: u32) -> usize {
    ((i % core + edge + 1) % core) as usize
}

fn random_target(i: u32, edge: u32, core: u32) -> usize {
    (i.wrapping_mul(1_664_525)
        .wrapping_add((edge + 1).wrapping_mul(1_013_904_223))
        % core) as usize
}

fn ms(value: Duration) -> f64 {
    value.as_secs_f64() * 1_000.0
}

fn main() {
    let capacity = capacity();
    let core = capacity * 3 / 4;
    let churn = capacity - core;
    let read_rounds = even_at_least(9_000_000 / core, 12);
    let write_rounds = even_at_least(1_000_000 / capacity, 4);
    let churn_rounds = even_at_least(1_000_000 / churn, 4);
    let sparse_rounds = (100_000_000 / capacity).max(100);

    let phase = Instant::now();
    let mut roots: Vec<Option<Rc<RefCell<Node>>>> = (0..capacity)
        .map(|i| {
            Some(Rc::new(RefCell::new(Node {
                value: i as u64,
                edges: std::array::from_fn(|_| Weak::new()),
            })))
        })
        .collect();
    for i in 0..capacity {
        let mut node = roots[i].as_ref().unwrap().borrow_mut();
        for edge in 0..EDGE_COUNT {
            node.edges[edge] = Rc::downgrade(
                roots[local_target(i as u32, edge as u32, core as u32)]
                    .as_ref()
                    .unwrap(),
            );
        }
    }
    let build = phase.elapsed();

    let phase = Instant::now();
    let mut local_checksum = 0_u64;
    for _ in 0..read_rounds {
        for root in roots.iter().take(core) {
            let node = root.as_ref().unwrap().borrow();
            for edge in &node.edges {
                local_checksum =
                    local_checksum.wrapping_add(edge.upgrade().unwrap().borrow().value);
            }
        }
    }
    let local_read = phase.elapsed();

    let phase = Instant::now();
    for round in 0..write_rounds {
        let use_random = round & 1 != 0 || round + 1 == write_rounds;
        for i in 0..capacity {
            let mut node = roots[i].as_ref().unwrap().borrow_mut();
            for edge in 0..EDGE_COUNT {
                let target = if use_random {
                    random_target(i as u32, edge as u32, core as u32)
                } else {
                    local_target(i as u32, edge as u32, core as u32)
                };
                node.edges[edge] = Rc::downgrade(roots[target].as_ref().unwrap());
            }
        }
    }
    let edge_write = phase.elapsed();

    let phase = Instant::now();
    let mut random_checksum = 0_u64;
    for _ in 0..read_rounds {
        for root in roots.iter().take(core) {
            let node = root.as_ref().unwrap().borrow();
            for edge in &node.edges {
                random_checksum =
                    random_checksum.wrapping_add(edge.upgrade().unwrap().borrow().value);
            }
        }
    }
    let random_read = phase.elapsed();

    let phase = Instant::now();
    for round in 0..churn_rounds {
        for tail in 0..churn {
            roots[core + tail] = Some(Rc::new(RefCell::new(Node {
                value: (tail + round) as u64,
                edges: std::array::from_fn(|edge| {
                    Rc::downgrade(
                        roots[random_target(tail as u32, edge as u32, core as u32)]
                            .as_ref()
                            .unwrap(),
                    )
                }),
            })));
        }
    }
    let churn_elapsed = phase.elapsed();

    let phase = Instant::now();
    let keep = (capacity / 100).max(1);
    for root in roots.iter_mut().skip(keep) {
        *root = None;
    }
    let collapse = phase.elapsed();

    let phase = Instant::now();
    let mut sparse_checksum = 0_u64;
    for _ in 0..sparse_rounds {
        for root in &roots {
            if let Some(root) = root {
                sparse_checksum = sparse_checksum.wrapping_add(root.borrow().value);
            }
        }
    }
    let sparse_scan = phase.elapsed();

    let total = build + local_read + edge_write + random_read + churn_elapsed + collapse;
    let peak_requested = capacity
        * (std::mem::size_of::<Option<Rc<RefCell<Node>>>>()
            + 2 * std::mem::size_of::<usize>()
            + std::mem::size_of::<RefCell<Node>>());
    let retained_lower_bound = capacity * std::mem::size_of::<Option<Rc<RefCell<Node>>>>()
        + keep * (2 * std::mem::size_of::<usize>() + std::mem::size_of::<RefCell<Node>>());

    println!("BENCH_RESULT: {:.3} ms", ms(total));
    println!(
        "BENCH_LAYOUT: impl=rust-rc-refcell-weak root_slot_bytes={} node_bytes={} refcell_node_bytes={} weak_edge_bytes={}",
        std::mem::size_of::<Option<Rc<RefCell<Node>>>>(),
        std::mem::size_of::<Node>(),
        std::mem::size_of::<RefCell<Node>>(),
        std::mem::size_of::<Weak<RefCell<Node>>>()
    );
    println!(
        "BENCH_INFO: impl=rust-rc-refcell-weak nodes={} live={} peak_mib={:.2} retained_lower_bound_mib={:.2} bytes_per_capacity={:.1} local_checksum={} random_checksum={}",
        capacity,
        keep,
        peak_requested as f64 / (1024.0 * 1024.0),
        retained_lower_bound as f64 / (1024.0 * 1024.0),
        peak_requested as f64 / capacity as f64,
        local_checksum,
        random_checksum
    );
    println!(
        "BENCH_PHASES: impl=rust-rc-refcell-weak build_ms={:.3} local_read_ms={:.3} edge_write_ms={:.3} random_read_ms={:.3} churn_ms={:.3} collapse_ms={:.3} sparse_scan_ms={:.3} sparse_checksum={}",
        ms(build), ms(local_read), ms(edge_write), ms(random_read), ms(churn_elapsed),
        ms(collapse), ms(sparse_scan), sparse_checksum
    );
}
