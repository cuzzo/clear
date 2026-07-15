# Mini-Corpus First-Pass Summary

This first pass covers all 24 pinned repositories selected in the
cross-language mini-corpus. It ran Nil-Kill static, Espalier, and Decomplex on
production sources, then manually audited the highest ranked areas and known
semantic cores. The follow-up pass changed Nil-Kill only: gradual TypeScript
now publishes Type Next advice, then tsyringe and tsup were rerun. No evaluated
target repository was modified.

## Product findings

No repository has a confirmed or even sufficiently supported *probable* bug
from these static reviews alone. The few performance hypotheses worth
reproduction are intentionally recorded as hypotheses in their individual
notes: recursive `$ref` work in fast-json-stringify, repeated import/name
lookup in javapoet, persistent-structure path copying, and reflection-driven
decode costs. Memory safety, concurrency, and security claims require the
appropriate fuzzing, schedule, or data-flow evidence before they become bugs.

## Second-pass complexity audit

Every final `unknown` in the corpus retains a non-unknown known component for
both time and space: **3,227/3,227** unknown-time and **3,227/3,227**
unknown-space results. That is valuable partial evidence, but it is not a
final bound. Three unknowns were source-reviewed in each of the 24 projects:
**47/72** were locally analyzable but under-specified, and **25/72** correctly
remained final-unknown because their remaining cost was an external tool,
kernel, callback, virtual/reflection contract, or compile-time template
operation. This is a spot-check sample, not a statistical claim about every
function.

The audit found one concrete false *known* result: `eventpp`
`EventDispatcher::dispatch` is labeled `O(1)` despite calling a callback list
that invokes every listener. That is a general interprocedural summary failure
and is recorded without changing the analyzer in this task.

## Consistent analyzer signal

- Decomplex generally locates genuine state-machine, parser, dispatcher,
  serializer, lifecycle, and decoder boundaries across the corpus.
- Espalier owner/state reports are useful in typed object-oriented code and
  correctly identify many core coordinators: requests adapters, tsyringe DI,
  pydantic CLI, cJSON parsing, ants pools, mapstructure decoding, and JWT
  parsing.
- Nil-Kill static properly emits review leads for dynamic Python/JavaScript and
  gradual TypeScript projects, while suppressing a misleading Type Next queue
  for languages with mandatory declarations.

## Material gaps to preserve as regression targets

| Gap | Evidence |
| --- | --- |
| Dynamic/external Big-O coverage | 70–93% final unknown across most Python/JS/C/Go projects. All retain components, but local symbolic terms are usually missing; mapstructure is 42/42 unknown and javapoet 346/385. |
| Semantic data-structure complexity | RTree traversal, immutable radix traversal/path copying, parser combinators, and reflection decode lack useful final symbolic parameters despite visible local loops/allocations. |
| Generated code provenance | fast-json-stringify's generated validator produces 261 findings and should not dominate maintainability triage. |
| Semantic prioritization | commons-cli ranks help formatting above parser state; rtree ranks serialization/geometry helpers above tree traversal. |
| Header-only C++ pipeline | Decomplex rejects proxy/plog/eventpp entirely; Espalier extracts far fewer functions than Nil-Kill. |
| JavaScript ownership | module/factory attachment can look like a single large mutable owner in pino. |
| Interprocedural complexity | eventpp dispatch drops callback-list traversal and reports an incorrect `O(1)` known bound. |

The next step is to convert only repeatable analyzer gaps into small general
fixtures, then rerun this corpus. It should not be to modify a target project
or to characterize any hypothesis above as a confirmed defect.
