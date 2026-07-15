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
