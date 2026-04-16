# Benchmark 20: TCP KV Store

Minimal RESP-compatible server (SET/GET/INCR/DECR/PING) measured against DragonflyDB using `redis-benchmark`.

- CLEAR: `@sharded(128)` HashMap with per-shard locking, one BG fiber per client connection, response batching (one `tcpWrite` per `tcpRead`), port 6390
- DragonflyDB v1.37: production RESP server, port 6391

Load: `redis-benchmark -t set,get,incr -n 100000 -c 50 -P 16`

## Results

| Server | SET (rps) | GET (rps) | INCR (rps) | Peak RSS |
|--------|-----------|-----------|------------|---------|
| DragonflyDB | ~990K | ~1.05M | ~1.02M | ~62 MB |
| CLEAR (fibers) | ~1.27M | ~1.41M | ~1.41M | ~39 MB |

CLEAR is +28-38% faster than DragonflyDB at equivalent load and uses ~63% of the memory.

## Why CLEAR wins here

CLEAR's RESP parser handles a full pipeline batch in one `tcpRead` call and emits all responses in one `tcpWrite`. DragonflyDB handles pipelining too, but has more infrastructure overhead (eviction, keyspace notifications, persistence checks, cluster plumbing) that adds latency on every command. CLEAR's server is a minimal implementation with none of that.

This is a favorable workload for CLEAR: pure in-memory, no persistence, no eviction, pipelined small commands. Under write-heavy workloads with large values, persistence requirements, or Lua scripting, DragonflyDB's feature set would be required.
