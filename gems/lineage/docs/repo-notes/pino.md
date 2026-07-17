# pino — JavaScript

**Revision:** `98d8fa4d95f1` · **Scope:** `pino.js`, `browser.js`, `file.js`,
`bin.js`, `lib` · **Result:** core logger construction/serialization are
well-ranked; broad browser-module ownership is partly representation noise.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 18 files, 108 methods, 103 fields; 117 Type Next candidates. |
| Espalier | 78/108 bounds unknown (72.2%). `browser.js` is top owner because many functions are attached to its exported factory. |
| Decomplex | 37 convergences: `pino`, `_asJson`, browser `asObject`/`createWrap`, transport construction, child logging, and multistream writes. |

## Independent source audit

- `pino` constructs logger state, child bindings, serializers, levels, streams,
  and transport behavior. `_asJson` is a true per-event formatting path with
  object/error/serializer branches.
- Browser `pino`, `asObject`, and `createWrap` are real compatibility paths,
  but the module-level “owner” score partly conflates exported helper functions
  with a single mutable class-like object.
- `transport` and multistream paths are asynchronous/back-pressure boundaries;
  static control flow alone cannot determine their latency or queue cost.

## Assessment and follow-up

- The main functional hotspots are credible. Module-as-owner reporting should
  be labeled differently from object state pressure for JavaScript.
- No probable product bug. Potential performance questions around serializer
  cost or multistream fan-out require benchmarked payload/stream workloads,
  not this static evidence.

## Second-pass time/space audit

- **Partial evidence:** 78/78 unknown time/space results retain components.
  `setupBaseLogFunctions` visibly iterates levels and is under-specified;
  `_asJson` has local object/serializer work that should be parameterized;
  transport execution is appropriately opaque. The sample is two
  under-specified, one appropriate.
- **Actual dominant work:** per-log-event JSON/error serialization is driven by
  bindings, message/object fields, serializers, and redaction paths;
  multistream/transport cost adds stream fan-out and back-pressure queues.
  Allocations are serialized buffers, child bindings, and queued writes.
- **Coverage verdict:** array/object iteration and stream-count components are
  locally discoverable; transport latency is not. `unknown` is safe but hides
  the primary logger data-size and fan-out terms.
