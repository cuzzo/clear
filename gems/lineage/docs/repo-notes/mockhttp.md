# MockHttp — C#

**Revision:** `cfbc8266df93` · **Scope:** `RichardSzalay.MockHttp` · **Result:**
request matching and async response selection are correctly surfaced; no
probable product defect.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 28 files, 188 methods, 41 fields; no Type Next for C#. |
| Espalier | 119/188 bounds unknown (63.3%). `MockedRequestExtensions` has high API breadth; `MockHttpMessageHandler.SendAsync` is the highest coordinator. |
| Decomplex | Request form/query/content matcher families and `SendAsync` converge across detectors. |

## Independent source audit

- `SendAsync` selects a matching request definition, enforces expectations,
  invokes a response factory, and returns asynchronously. It is the correct
  state/error boundary.
- Query/form/content matchers inspect user request data and can enumerate
  collections proportional to parameter/content shape. Their similar source
  structure is intentional fluent-matcher variation, not necessarily clones to
  remove.
- The broad extension-method owner is largely fluent API surface; extension
  methods do not imply a single shared mutable object.

## Assessment and follow-up

- There is useful signal in matching and expectation lifecycle; there is some
  owner-level noise from extension aggregation.
- No candidate defect. Future complexity summaries should expose request
  matcher count × request field count, and identity should distinguish static
  extension helpers from handler-owned state.
