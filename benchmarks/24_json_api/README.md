# Benchmark 24: JSON API Server

TCP server that stores/retrieves JSON documents. SET generates JSON files,
GET reads and parses them (sum of array elements via std.json FFI).

## Results

```
Server              SET(ms)  GET(ms)  Peak RSS     Verified
Rust (tokio)             60       17    5788 KB    2500/2500
Go (goroutines)          72       62   11776 KB    2500/2500
CLEAR (fibers)          382      139  233868 KB    2500/2500
```

## Known Issues

### Fiber stealing corrupts epoll fd registration

Unpinned BG fibers that do TCP I/O crash at 4+ cores. When a fiber is
stolen from scheduler A to scheduler B, its client fd is registered with
scheduler A's epoll. On the next `read()`, if WouldBlock fires, the fd
gets registered with scheduler B's epoll. Now TWO epoll instances watch
the same fd. Both wake the fiber on data arrival, causing double-push
to the ready queue and use-after-free.

Workaround: pin handler fibers by capturing a `@sharded` map. This
prevents stealing but limits throughput to one scheduler.

Fix: unregister fds from the old scheduler's epoll when a fiber is stolen,
or track fd-to-scheduler affinity in the runtime.

### High memory usage (234MB vs 6MB Rust)

`parseFromSliceLeaky` (std.json) allocates parse nodes on `heapAlloc`
and never frees them. Each GET leaks ~200 bytes of parse tree. With
2500 GETs, this accumulates. Fix: use `parseFromSlice` with proper
cleanup, or allocate on the frame arena (freed per loop iteration).

### SET/GET throughput

CLEAR is 6x slower on SET and 8x slower on GET vs Rust. The bottleneck
is RESP parsing (character-by-character WHILE loops) and string
concatenation (`resp = resp + "..."` per command).
