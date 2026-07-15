# Mini-Corpus First-Pass Summary

This first pass covers all 24 pinned repositories selected in the
cross-language mini-corpus. It ran Nil-Kill static, Espalier, and Decomplex on
production sources, then manually audited the highest ranked areas and known
semantic cores. No targets or analyzers were modified in this pass.

## Product findings

No repository has a confirmed or even sufficiently supported *probable* bug
from these static reviews alone. The few performance hypotheses worth
reproduction are intentionally recorded as hypotheses in their individual
notes: recursive `$ref` work in fast-json-stringify, repeated import/name
lookup in javapoet, persistent-structure path copying, and reflection-driven
decode costs. Memory safety, concurrency, and security claims require the
appropriate fuzzing, schedule, or data-flow evidence before they become bugs.

## Consistent analyzer signal

- Decomplex generally locates genuine state-machine, parser, dispatcher,
  serializer, lifecycle, and decoder boundaries across the corpus.
- Espalier owner/state reports are useful in typed object-oriented code and
  correctly identify many core coordinators: requests adapters, tsyringe DI,
  pydantic CLI, cJSON parsing, ants pools, mapstructure decoding, and JWT
  parsing.
- Nil-Kill static properly emits review leads for dynamic Python/JavaScript
  projects and suppresses a misleading Type Next queue for declared languages.

## Material gaps to preserve as regression targets

| Gap | Evidence |
| --- | --- |
| Dynamic/external Big-O coverage | 70–93% unknown across most Python/JS/C/Go projects; mapstructure is 42/42 unknown and javapoet 346/385. |
| Semantic data-structure complexity | RTree traversal, immutable radix traversal/path copying, parser combinators, and reflection decode lack useful symbolic parameters. |
| Generated code provenance | fast-json-stringify's generated validator produces 261 findings and should not dominate maintainability triage. |
| Semantic prioritization | commons-cli ranks help formatting above parser state; rtree ranks serialization/geometry helpers above tree traversal. |
| Header-only C++ pipeline | Decomplex rejects proxy/plog/eventpp entirely; Espalier extracts far fewer functions than Nil-Kill. |
| JavaScript ownership | module/factory attachment can look like a single large mutable owner in pino. |

The next step is to convert only repeatable analyzer gaps into small general
fixtures, then rerun this corpus. It should not be to modify a target project
or to characterize any hypothesis above as a confirmed defect.
