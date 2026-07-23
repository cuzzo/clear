# tsyringe — TypeScript

**Revision:** `e033769d97cf` · **Scope:** `src` · **Result:** DI resolution and
registry mutation are real hotspots; no probable defect.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 60 files, 178 methods, 30 fields; **57** ranked Type Next candidates after enabling gradual-TypeScript advice. Top candidate `resolveRegistration.registration` unlocks 9 flow facts. |
| Espalier | 53/88 bounds unknown (60.2%). `InternalDependencyContainer` is the top owner. |
| Decomplex | Five convergences: `register`, `resolveRegistration`, `createChildContainer`, `isRegistered`, and dependency error formatting. |

## Independent source audit

- `register` chooses between token/provider forms and manages lifecycle
  registrations; `resolveRegistration` selects cached, delayed, factory, value,
  or class behavior. Their branch density is genuine DI semantics.
- `createChildContainer` copies only selected registrations and parent links.
  It is a meaningful ownership/lifetime boundary, not a generic state smell.
- Resolver work can be proportional to dependency-graph depth and registration
  multiplicity. Espalier does not yet express this graph parameter, so unknown
  is preferable to inventing a flat bound.

## Assessment and follow-up

- TypeScript ownership attribution is coherent here: only five functions
  converge, avoiding the broad module/class conflation seen in earlier larger
  corpus runs.
- No probable cycle, cache, or mutable-aliasing defect was identified. Future
  analysis should model resolution depth and multi-registration fan-out, while
  preserving explicit “cycle detection external/unknown” status.

## Second-pass time/space audit

- **Partial evidence:** 53/53 unknown time and space results retain components.
  Decorator metadata helpers and registry resolution are under-specified;
  factory/provider execution is appropriately opaque. The three-function sample
  is two under-specified and one appropriate.
- **Actual dominant work:** `resolve`/`resolveRegistration` traverse dependency
  edges, registration lists, scoped caches, and possibly nested resolution;
  space is resolution context/cache depth. This is more significant than the
  currently known `O(1)` registration overloads.
- **Coverage verdict:** a dependency-depth/fan-out symbolic bound should be
  produced without assuming provider cost. The new Type Next queue is useful,
  but its “add or verify” wording is important until TypeScript annotations are
  fully consumed by the resolver.
