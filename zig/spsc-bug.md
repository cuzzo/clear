# SPSC / io_uring Regression Notes

## Current Best Repro

The original `L6` hammer failure is now best understood through the focused
`PartitionedStringMap` repros in `zig/lib/partitioned-map-test.zig`, not the
full SPSC hammer itself.

Most useful current repros:

```bash
zig test zig/runtime/switch.S zig/runtime/onRoot.S \
  --dep safety --dep ebr --dep ownership \
  -Mroot=zig/partitioned-map-test.zig \
  -Msafety=zig/lib/safety.zig \
  -Mebr=zig/lib/ebr.zig \
  -Mownership=zig/lib/ownership.zig \
  -lc --test-filter "tiny 2-worker 2-key 1-remote-shard"
```

and

```bash
zig test zig/runtime/switch.S zig/runtime/onRoot.S \
  --dep safety --dep ebr --dep ownership \
  -Mroot=zig/partitioned-map-test.zig \
  -Msafety=zig/lib/safety.zig \
  -Mebr=zig/lib/ebr.zig \
  -Mownership=zig/lib/ownership.zig \
  -lc --test-filter "ctx counters drain"
```

The tiny `2 worker / 2 key / 1 remote shard` loop is now the smallest strong
failure. It fails even though large broad stress is no longer needed.

## What Has Been Ruled Out

These focused tests now pass:

- forced same-remote-shard `get-remove`
- disjoint-shard `get-remove`
- local-owner vs remote-owner `get-remove`
- overlapping-key `get-remove`
- single-worker repeated remote `get-remove`
- same-keys vs fresh-keys across iterations
- raw back-to-back `RemoteCall` read-then-mutate barrier
- remote alloc then cross-scheduler free
- phased `get` then `remove`
- persistent-map repeated `get/remove` with counters

This means the remaining bug is not explained by:

- generic `RemoteCall` chaining
- cross-scheduler `c_allocator` free
- key overlap alone
- key reuse across iterations alone
- local-vs-remote ownership alone
- map recreation alone
- concurrency alone, because the single-worker repeated remote case passes

## Strong Current Signal

The strongest narrowing result is:

- the tiny interleaved remote `get/remove` loop fails
- the phased `get`-then-`remove` version passes
- a delayed-destroy diagnostic for `GetCtx` / `RemoveCtx` also passes

That strongly suggests the remaining bug is in the lifetime / reclamation edge
around interleaved remote `get` and `remove`, not in broad scheduler or map
ownership logic.

## Counter Instrumentation

Test-only hooks were added around `PartitionedStringMap` `GetCtx` and
`RemoveCtx` creation/destruction. The counter-drain test can still crash
before it proves a clean drain, which is itself useful: the failure is close to
the get/remove context lifecycle.

## Working Hypothesis

The remaining bug is a lifetime-sensitive interleaving in the remote
`PartitionedStringMap` lookup/remove path:

- remote `get`
- immediate remote `remove`
- repeated across a tiny concurrent loop

The passing delayed-destroy diagnostic suggests immediate teardown of
`GetCtx` / `RemoveCtx` state is involved, even though the simpler broad
allocator and raw-remote-call hypotheses have now been ruled out.

## Next Debugging Target

Debug the tiny `2 worker / 2 key / 1 remote shard` repro under `gdb` or with
even narrower operation logging. That test is now the best place to continue.

## Update: Scheduler-State Instrumentation

Additional instrumentation changed the interpretation of the latest tiny
`PartitionedStringMap` intermittent.

What the scheduler-state dump showed on failure:

- `status.done == false`
- `active_tasks == 0`
- `dirty_mask == 0`
- `ready == 0`
- `pinned == 0`
- `sleepers == 0`

That state is consistent with the local scheduler being genuinely idle while
the synthetic test "main" task was no longer local.

The actual issue was in the focused test harness:

- `runCheckedMain()` submitted its synthetic main task as stealable work
- another scheduler could steal that task
- the local scheduler could then return from `run()` correctly idle
- the harness still treated that as a failure because it expected the local
  scheduler to observe completion directly

Fix applied:

- pin the synthetic main task in:
  - `zig/lib/partitioned-map-test.zig`
  - `zig/lib/runtime-isolation-test.zig`

Result:

- the repeated tiny event-log repro passed `20/20` looped runs after pinning
  the harness main task

Conclusion:

- this latest `PartitionedStringMap` intermittent was a harness artifact, not
  evidence that the real `PartitionedStringMap` `GetCtx` / `RemoveCtx` teardown
  path was still corrupting memory in that repro.
