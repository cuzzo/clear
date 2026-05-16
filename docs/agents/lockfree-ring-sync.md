# Lock-Free Ring Synchronization (@shared:ring)

## Overview
Standard mutexes (`@shared:locked`) and read-writer locks (`@shared:writeLocked`) suffer from **Software Blocking** and **Hardware Cache Contention** in high-concurrency, write-heavy workloads. When multiple cores fight for a single lock, the CPU spend most of its time "ping-ponging" cache lines over the memory bus.

The `shared:ring` (Dedicated Writer) architecture replaces mutual exclusion with an **Asynchronous Command Stream**. Writers "fire and forget" mutations into a lock-free MPSC ring buffer, while a dedicated fiber owns the state and applies updates in a cache-local loop.

## Goals
1.  **Eliminate Software Blocking**: Producers (writers) should never be suspended by the scheduler unless the ring buffer is full.
2.  **Maximize Cache Locality**: The "Master State" should stay pinned to the L1/L2 cache of a single core (the Dedicated Writer).
3.  **Non-Blocking Reads**: Readers should see a consistent (though eventually consistent) snapshot of the state without ever blocking the writer or being blocked by it.
4.  **Batching**: The writer should be able to drain the ring and apply multiple mutations in a single pass, amortizing overhead.

## Architecture

### 1. The Transport: MPSC Ring Buffer
- **Multi-Producer**: Many fibers can push mutation commands simultaneously using atomic `fetchAdd` on the head index.
- **Single-Consumer**: Only one fiber (the Dedicated Writer) ever pops from the tail.
- **Hardware Contention**: Contention is limited to the atomic head index, which is orders of magnitude faster than a full context switch or mutex acquisition.

### 2. The Dedicated Writer
- Upon initialization of a `@shared:ring` variable, the runtime spawns a **Pinned Fiber**.
- This fiber is the **exclusive owner** of the data. 
- It loops on the ring buffer, popping "Mutation Commands" and applying them to the local state.

### 3. Non-Blocking Readers
- Readers use **EBR (Epoch-Based Reclamation)** or a **Seqlock**.
- When a fiber enters `WITH my_ring_obj AS r`, it sees the state as it existed at the moment the writer last updated the "Published" pointer.
- Zero locks, zero waiting.

## Implementation Plan

### Phase 1: Frontend & Type System
- **Parser**: Add `@ring` to `CAP_SIGIL_ATTRS` (sync dimension).
- **Type System**: Add `ring?` predicate to `Type`. Map `T @shared:ring` to `CheatLib.RingLocked(T)` in `ZigTypeMapper`.
- **Annotator**: 
    - Enforce that `@ring` requires `@shared`.
    - Prevent `RETURN` or assignments inside `WITH EXCLUSIVE` blocks for ring objects (asynchronous semantics).

### Phase 2: Zig Runtime
- Implement `MpscRing(T)` in `zig/queues.zig` or `zig/shared-memory.zig`.
- Implement `RingLocked(T)` which manages the data, the ring, and the spawning of the writer fiber.
- Integrate with `EBR` for safe reader access.

### Phase 3: Command Hoisting (The Transpiler)
The transpiler must transform synchronous mutation blocks into asynchronous commands:
1.  **Analyze**: Identify variables modified inside `WITH EXCLUSIVE`.
2.  **Hoist**: Create a "Mutation Struct" containing the captured values needed for the update.
3.  **Generate**: Create an `apply` function that the Dedicated Writer will call.
4.  **Emit**: Replace the block with a `push` to the ring buffer.

## Design Constraints & Pitfalls
- **No Immediate Feedback**: You cannot get a result back from a write immediately. If you need the new value (e.g., an atomic increment that returns the new ID), use `@shared:locked`.
- **Eventual Consistency**: Readers may be a few microseconds behind the latest "pushed" mutation.
- **Memory Pressure**: A fast producer and a slow writer can fill the ring. The system must provide natural backpressure by yielding the producer when the ring is full.
