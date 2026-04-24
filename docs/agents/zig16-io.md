# Zig 0.16 Io Integration — Design

## Framing

This is a **features + capabilities** project, not a speedup project. Our
existing io_uring path for TCP and path-based file IO is already optimal —
`02_concurrent_search` beats Go by ~70% and Rust by ~24%. Do not expect raw
perf wins on workloads we already benchmark.

What this work unlocks:
- Streaming API (`conn.lines()`, `file.chunks(n)`) for pipeline composition
- Memory-bounded processing of large files / long network streams (today's
  pipeline collects eagerly → OOMs on 10 GB files)
- Long-lived `File` handle ops become fiber-aware (today `fileReadAll(f)` /
  `fileWrite(f,data)` block the kernel thread)
- UDP, DNS, Unix sockets (new capabilities)
- Eventually TLS + stdlib HTTP (via minimal Io shim, deferred)

If the goal is "beat Go on benchmarks we publish today," this work moves
nothing. If the goal is "match Go's `os.Open + bufio.Scanner` ergonomics and
enable workloads we can't run today," it's the right work.

## Current State (starting line)

- **TCP**: io_uring-backed, fiber-aware. `scheduler.zig:948-1126`,
  `runtime-header.zig:1470-1635`.
- **File IO**: mixed.
  - `readFile(path)` **IS** io_uring-backed and fiber-aware
    (`runtime-header.zig:508-539`, guarded on `fp.scheduler_running`).
  - `File.read(buf)` / `File.writeAll(data)` / `fileReadAll(f)` / `fileWrite(f,data)`
    **are NOT** fiber-aware — they call `std.posix.read` / `std.c.write`
    directly (`runtime-header.zig:170-182, 465-494`).
- **Streams**: `Range`, `IntRange`, `SplitStream` in `zig/lib/streams.zig`.
  Pipelines collect eagerly to a list before running — no pull-based
  streaming.
- **Scheduler**: `IoWaiter` is already a generic "park fiber on io_uring CQE"
  primitive; any SQE can encode a waiter and wake its task.
- **Missing**: no HTTP server, no UDP, no DNS (beyond blocking
  `getAddressList`), no Unix sockets, no TLS.
- **Stdlib usage**: hand-rolled syscalls + direct `linux.IoUring`. No
  `std.net` / `std.fs` / `std.Io`.

## Zig 0.16 `std.Io` — adoption decision

**Decision: do not adopt `std.Io` as our IO foundation.**

`std.Io` is a fat pointer (`userdata + vtable`, ~100 entries) with its own
fiber runtime when using `std.Io.Uring`. Adopting it as foundation means
abandoning our scheduler, losing:
- ParkingMutex/RwLock, `@locked(rank:N)` DAG
- Fiber profiler, lock telemetry, lock hold-time + contention stats
- Deadlock detection
- Our cooperative yield model

A custom `std.Io` vtable backed by our scheduler is ~400-800 LoC and adds
nothing to perf (vtable indirection is noise next to a syscall). Its only
benefit is **interop with stdlib code that itself takes an `Io`** —
specifically `std.http.*` and `std.crypto.tls`.

**Plan**:
- **Phases 1-4**: no `std.Io` involvement. Build streams + pipeline fusion
  directly on our scheduler.
- **Where we want stdlib byte-stream consumers** (`std.json.Scanner`,
  `std.compress`, `std.zip`), wrap our sockets / files as
  `std.Io.Reader` — a *separate, 4-entry* vtable, not the full `Io`.
- **Later (Phase 5+)**: minimal ~8-entry `std.Io` shim, added only if/when
  we decide TLS + `std.http` is worth it vs writing our own HTTP/1.

## Design principles

1. **`Io` (if we ever add it) is invisible.** Compiler threads it through;
   users never write `io` in signatures.
2. **Sync is the default.** `conn.read()` reads-as-Python, yields fiber
   under the hood.
3. **Streams for composition, calls for one-shot.** `conn.lines()` is a
   stream; `conn.readExact(4)` is not.
4. **`NEXT` / `COLLECT` tied to stream-returning methods**, not to
   `read()`. `read()` stays a sync one-shot.
5. **Cancellation / timeout via `WITH ON TIMEOUT`.** Maps to our scheduler
   directly (not `std.Io.Timeout`, since we're not adopting `Io`).

## Target API

### Networking

```clear
-- TCP server
server = TCPServer.bind("0.0.0.0:8080")
FOR conn IN server.connections() DO     -- Stream[TCPClient]
  BG: handle(conn)
END

-- TCP client
conn = TCPClient.connect("host:443")
conn.write(req)
resp = conn.readAll()

-- stream variants
FOR line IN conn.lines() DO ... END
FOR chunk IN conn.chunks(4096) DO ... END
first_4 = conn.readExact(4)

-- UDP
sock = UDPSocket.bind(":5353")
FOR (data, addr) IN sock.datagrams() DO ... END

-- DNS
addrs = DNS.lookup("example.com")
```

### Files

```clear
-- sync one-shot (stays as-is, already io_uring)
content = readFile("path")
writeFile("path", content)

-- opened handle (becomes fiber-aware)
f = File.open("path")
FOR line IN f.lines() DO ... END
FOR chunk IN f.chunks(64*1024) DO ... END
bytes = f.readAll()
f.close()                                 -- or WITH f = File.open(...) DO ... END
```

### HTTP (Phase 5+, via Io shim)

```clear
server = HTTPServer.bind(":8080")
FOR req IN server.requests() DO
  BG: req.respond(200, "hello")
END

resp = HTTP.get("https://api/...")
json = resp.json()
```

## Implementation Plan

Phases ordered by value and independence. Each ships passing tests +
(where relevant) benchmarks before the next.

### Phase 1 — Fiber-aware `File` handle IO

Wire `File.read`, `File.writeAll`, `fileReadAll`, `fileWrite` through the
existing `submitRead` / `submitWrite` scheduler entry points. Currently
they call `std.posix.read` / `std.c.write` and block the kernel thread.

- Mirror the pattern in `readFile(path)` (`runtime-header.zig:515-528`):
  guard on `fp.scheduler_running`, submit+yield when scheduler is active,
  fall back to blocking for CLI/test contexts.
- No API change; purely runtime.

**Measurable**: open-read-close in N fibers should scale with fiber count,
not thread count.

**Difficulty**: Easy. Pattern already established. 1-2 days.

**Risk**: regression on tiny handle reads (<4 KB) — io_uring submit/
completion overhead vs direct syscall. Accept 5-10% for now.

### Phase 2 — Streams from io_uring sources

Expose `Stream[T]` wrappers for sockets and files:

- `TCPClient.lines() -> Stream[String]`
- `TCPClient.chunks(n) -> Stream[U8[]]`
- `TCPClient.bytes() -> Stream[U8]`
- `File.lines() -> Stream[String]`
- `File.chunks(n) -> Stream[U8[]]`

Underneath: a single heap-allocated buffered reader per source,
per-stream wrapper pulls via existing `submitRead` / `submitRecv`.

Wire `NEXT` / `COLLECT` to operate on these streams.
`FOR x IN stream` desugars to `WHILE NEXT stream AS x`.

**Difficulty**: Medium. Buffering + stream wrapper is mechanical; the
integration with existing `Stream[T]` infrastructure is where care is
needed. 3-4 days.

### Phase 3 — Pipeline fusion over streams *(critical path)*

Today `stream |> SELECT |> WHERE |> EACH` collects to a list first.
We need pull-based fusion: emitted code loops on `NEXT source` with
transforms inline, sinks at the tail.

Compiler change in `src/backends/pipeline_generator.rb` +
`src/mir/`:
- Detect when pipeline source is a `Stream` (not a collection)
- Emit a `while` over `NEXT source` with transforms fused inside
- Keep collection-source pipelines unchanged (already optimal)

This is the single change that makes `file.lines() |> WHERE $ contains "ERROR"
|> EACH print` feel like Python but run at grep speed — and run
bounded-memory on a 100 GB file.

**Difficulty**: Hard. Pipeline generator currently assumes collection
semantics. Requires new emission path for stream sources, careful
ownership handling across the fused loop, test coverage across every
combinator. 1-2 weeks.

**Risk**: This is where the design can slip. Land behind a feature flag,
convert combinators progressively. Spike a single fused `SELECT` early
before committing to the full surface.

### Phase 4 — UDP + Unix sockets + DNS

Direct io_uring / syscall implementations, no `Io` involvement.

- UDP: io_uring `RECVMSG` / `SENDMSG` ops. ~200 LoC in `scheduler.zig`
  + intrinsics.
- Unix sockets: same syscalls as TCP with `AF_UNIX`. Trivial add.
- DNS (v1): `std.net.getAddressList` — blocking, pure Zig, ~ms resolution
  time, acceptable. Async DNS deferred.

**Difficulty**: Easy-Medium. 2-3 days.

### Phase 5 — `std.Io.Reader` / `Writer` wrappers

Wrap our sockets + files as `std.Io.Reader` / `Writer` (4-entry Reader
vtable: `stream`, `discard`, `readVec`, `rebase`). Unlocks byte-stream
stdlib consumers without needing the full `std.Io`:

- `std.json.Scanner` → streaming JSON parse
- `std.compress.gzip` / `flate` → streaming decompression
- `std.zip` → archive reading
- Most of `std.crypto.hash` → streaming hash

Expose as `reader()` / `writer()` methods on `TCPClient` and `File`.

**Difficulty**: Easy. ~30 LoC per source. 1-2 days total.

### Phase 6 — Timeouts + cancellation

`WITH ON TIMEOUT` already parses and has codegen stubs. Wire it to
scheduler-level cancellation: submit op, register timer, on timer fire
cancel the SQE and wake the fiber with a `Timeout` error.

**Difficulty**: Easy-Medium. Cancellation of an in-flight io_uring SQE
requires IORING_OP_ASYNC_CANCEL. 3-4 days.

### Phase 7 — `std.Io` shim (deferred, optional)

Minimal ~8-entry `std.Io` vtable routing to our scheduler:
- `netAccept`, `netRead`, `netWrite`, `netConnectIp`
- `futex`, `sleep`
- `async` / `await` / `cancel`
- everything else: `error.Unsupported`

Purpose: hand a valid `Io` to `std.http.Client` / `Server` / `std.crypto.tls`
so we can expose those without writing our own.

**Only pursue if/when TLS + stdlib HTTP is the alternative to writing
~2000 LoC of HTTP/1 + no TLS ourselves.** Otherwise defer indefinitely.

**Difficulty**: Medium. ~400-800 LoC.

**Risk**: vtable churn between Zig 0.16 → 0.17. Keep the shim in one file
(`zig/runtime/clear-io-shim.zig`) so future porting is localized.

### Phase 8 — HTTP intrinsics (depends on Phase 7)

Expose `HTTPServer`, `HTTP.get/post`, `HTTP.Client` using stdlib behind
the Phase 7 shim. Or write our own HTTP/1 if Phase 7 is abandoned.

## Phase Summary

| Phase | Value | Effort | Risk |
|-------|-------|--------|------|
| 1. Fiber-aware File handles | Capability | Easy | Low |
| 2. Streams from io_uring sources | Ergonomic | Med | None |
| 3. Pipeline fusion over streams | **Headline** | **Hard** | **Compiler refactor** |
| 4. UDP + Unix + DNS | Capability | Easy-Med | None |
| 5. `std.Io.Reader` wrappers | Stdlib interop | Easy | None |
| 6. Timeouts + cancellation | Wires existing syntax | Easy-Med | SQE cancel model |
| 7. `std.Io` shim (deferred) | Only if we want TLS/stdlib HTTP | Med | Vtable churn |
| 8. HTTP (depends on 7) | Headline demo | Easy given 7 | None |

## Critical path

Phase 3. Everything else is mechanical. Spike a stream-fused `SELECT`
before committing to the full Phase 2 surface, so we know the pipeline
lowering can support what the API promises.

## Open decisions

1. **Buffer ownership for streams**: does the `U8[]` yielded by
   `conn.chunks(n)` borrow the reader's buffer (zero-copy, lifetime-bound
   to next pull) or copy?
   **Recommend**: borrow by default (MIR-tracked), offer `.copy()` for
   escape. Matches the rest of our ownership model.

2. **Stream ABI across pipeline stages**: does every stage push/pull
   `T` one at a time, or do we allow chunk-level batching (push/pull
   `T[]` for locality)?
   **Recommend**: start one-at-a-time to ship Phase 3, add chunk
   batching later if profiling shows per-element overhead.

3. **Concurrent stream consumers**: can two fibers both `NEXT` the same
   stream?
   **Recommend**: no for v1 — streams are single-consumer. `SplitStream`
   already exists for multi-subscriber patterns.

## What this project does NOT do

- Does not speed up `02_concurrent_search` or any existing benchmark
- Does not make us cross-platform (each phase is Linux-only until we
  add kqueue/IOCP backends)
- Does not replace our scheduler
- Does not adopt Zig's new async fibers; ours stay
