# eventpp — C++

**Revision:** `1224dd6c9bd4` · **Scope:** `include/eventpp` · **Result:**
callback-list and queue operations are credible hotspots, but results remain
partial because header-only C++ is unsupported by Decomplex.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 23 headers, 323 methods, 94 fields; Type Next not applicable. |
| Espalier | 127 functions, 85 unknown (66.9%), far below Nil-Kill method extraction. `callbacklist` and `hetereventqueue.process` are top pressure. |
| Decomplex | Blocked on header-only C++ input. |

## Independent source audit

- `callbacklist` owns listener linkage, iteration, removal, and re-entrant
  safety; `next` read/write pressure is semantically meaningful.
- `hetereventqueue.process` dispatches queued variant events and invokes user
  callbacks. Its work scales with queue size and callback behavior, which must
  remain an explicit parameter/opaque component.
- `eventdispatcher.dispatch` and listener insertion are template/policy-driven;
  cross-policy merging would be a false ownership identity.

## Assessment and follow-up

- The ranked regions are reasonable manual-review leads, but no time/space or
  thread-safety judgment is possible from this partial extraction.
- The paired Nil-Kill/Espalier function-count discrepancy plus Decomplex
  rejection is a concrete C++ pipeline gap. No candidate product bug is
  recorded pending complete header analysis and concurrency-aware testing.

## Second-pass time/space audit

- **Partial evidence:** 85/85 unknown time/space results retain components.
  Queue processing and callback-list mutation are under-specified; user
  callback cost is appropriately opaque. The three-sample split is two
  under-specified, one appropriate.
- **Incorrect known bound:** `EventDispatcher::dispatch` is reported `O(1)`,
  but it calls `directDispatch`, which invokes the selected `CallbackList`.
  That list executes every listener, so its local cost is `O(listeners)` plus
  opaque callback work. This is an interprocedural undercount, not merely an
  unknown.
- **Actual dominant work:** dispatch/process scale with listeners or queued
  events; callback nodes/queued variants are the space terms. Espalier should
  propagate callback-list summaries through `directDispatch` after complete
  header extraction.
