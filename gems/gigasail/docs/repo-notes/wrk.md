# wrk — C

**Revision:** `a211dd5a7050` · **Scope:** `src` · **Result:** event loop,
HTTP parser, and process orchestration are correctly highlighted; no static
finding establishes a throughput or lifecycle bug.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 28 files, 182 methods, 173 fields; C declarations make Type Next inapplicable. |
| Espalier | 156/186 bounds unknown (83.9%). `aeEventLoop` and `wrk.main` dominate state/coordinator pressure. |
| Decomplex | 58 convergences, led by `http_parser_execute`, `aeMain`, `aeProcessEvents`, event-loop construction, and time-event processing. |

## Independent source audit

- `http_parser_execute` is a large generated/state-machine-like HTTP parser;
  its branch volume and state transitions are expected protocol complexity, not
  by themselves a maintainability defect.
- `aeProcessEvents` scans ready file/time events, invokes callbacks, and
  updates masks. Its runtime depends on ready-event count and callback cost;
  that is a genuine systems hot path.
- `wrk.main` wires threads, Lua scripting, connections, and event loops. It is
  a genuine orchestration boundary but not an inner-loop CPU metric.

## Assessment and follow-up

- Rankings correctly prioritize the benchmark's actual execution core. The
  high unknown rate reflects callbacks, epoll/kqueue boundaries, and parser
  state rather than evidence of bad asymptotics.
- No probable product defect. A meaningful follow-up would model event-ready
  count and callback fan-out, then compare inferred per-tick work with a
  controlled benchmark; static inspection cannot establish latency regressions.

## Second-pass time/space audit

- **Partial evidence:** all 156 unknown time/space results retain components.
  `aeCreateEventLoop` has a visible linear allocation and is under-specified;
  `http_parser_execute` should expose input-byte/state-machine work; kernel
  wait/callback execution is appropriately opaque. The sample is two
  under-specified, one appropriate.
- **Actual dominant work:** each event-loop tick is ready events plus time
  events plus callback work; HTTP parsing is input-byte proportional. Event
  arrays, connection buffers, parser state, and Lua/request payloads dominate
  memory, not the small loop-control frames.
- **Coverage verdict:** local ready-set/timer loops and allocations should be
  emitted as symbolic terms with callback/kernel work opaque. The current
  unknowns hide most of the benchmark's actual work profile.
