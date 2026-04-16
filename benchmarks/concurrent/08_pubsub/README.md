# Benchmark 16: Pub-Sub

1 publisher, 64 subscribers, 10K messages.
Each subscriber processes every message (2000 LCG iterations).
Total work: 10K x 64 x 2000 = 1.28 billion LCG iterations.

## Implementation

- **CLEAR**: publisher writes once to a `SplitStream` ring buffer. Each
  subscriber `CLONE`s an independent cursor — zero message copying. Publisher
  blocks only when the slowest subscriber's cursor is a full buffer behind.
- **Go**: publisher loops over 64 buffered channels (cap 64), sending one
  message per subscriber per iteration. Publisher blocks if any channel is
  full. 64 consumer goroutines drain their own channel.
- **Rust**: same as Go with `crossbeam::channel::bounded(64)` and native
  threads instead of goroutines.

## Results (best of 5, all cores)

```
CLEAR     149ms
Go        174ms
Rust      875ms
```

CLEAR's shared ring buffer avoids the N-copy fan-out: the publisher writes
each message once and subscribers read independently via their cursors.
Go and Rust pay 64 channel sends per message; the sequential publisher loop
stalls on head-of-line blocking if any one subscriber's channel is full.

Rust's gap vs Go comes from OS thread wake latency: each `tx.send()` that
unblocks a native thread pays a full context switch, while Go's goroutine
scheduler resumes goroutines cooperatively without OS involvement.
