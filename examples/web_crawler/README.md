# Web Crawler

Concurrent page fetcher using CLEAR fibers + native Zig HTTP via EXTERN FFI.

## Build & Run

```bash
cd examples/web_crawler
zig build test
```

Uses `build.zig` (not `./clear build`) because it has a native Zig package dependency (`packages/http/`).

## What it tests

- EXTERN FN: Zig `std.net` TCP client wrapped as CLEAR FFI
- BG fibers: 3 concurrent page fetches
- Struct returns with string fields (escape promotion)
- Canned test server on a background OS thread
