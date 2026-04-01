# Benchmark 24: JSON API Server

TCP server that stores/retrieves JSON documents. SET generates JSON files,
GET reads and parses them (sum of array elements via std.json FFI).

## Status

- 1 core: works correctly (100/100 verified)
- 4+ cores: crashes under concurrent GETs (segfault in JSON parsing)

## Known Issue

Concurrent GET requests crash at 4+ cores. The GET path calls
`readFile` + `parseFromSliceLeaky` (std.json via EXTERN FFI). At 1 core,
all fibers run cooperatively on one scheduler. At 4+ cores, handler
fibers are distributed across schedulers and call `onRootStack` + JSON
parsing concurrently. The segfault occurs in the parsing path.

Possible causes:
- std.json.parseFromSliceLeaky is not thread-safe with a shared allocator
- The EXTERN FFI onRootStack trampoline has a concurrency issue
- Frame allocator corruption from concurrent file reads

## Results (1 core, single-threaded)

```
Server          SET(ms)  GET(ms)  Peak RSS
Rust (tokio)        59       17    5864 KB
Go (goroutines)     60       59   13312 KB
CLEAR (1 core)      97        4    5420 KB
```

CLEAR's GET is fastest at 4ms (vs 17ms Rust, 59ms Go) because the fiber
cooperative model has zero context-switch overhead for sequential I/O.
