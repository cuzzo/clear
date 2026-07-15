# fast-json-stringify — JavaScript

**Revision:** `6aa2ed4cc403` · **Scope:** `index.js`, `lib` · **Result:** schema
compiler surfaces are correctly ranked; one generated validator creates obvious
analysis noise, and no product bug was inferred.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 7 files, 50 methods, 25 fields; 88 Type Next candidates. |
| Espalier | 38/50 bounds unknown (76.0%). |
| Decomplex | `schema-validator.validate10` produces 261 findings; `build`, `buildInnerObject`, `buildArray`, `traverse`, and reference resolution also converge. |

## Independent source audit

- `build`, `buildInnerObject`, `buildArray`, `traverse`, and `resolveRef` form
  a schema compiler. Traversal and generated-serializer construction genuinely
  scale with schema size/depth and reference topology.
- `lib/schema-validator.js` is generated validator-style code. Its enormous
  finding count measures a flattened decision tree rather than maintainability
  debt a project maintainer would refactor. It is a false-positive class unless
  generated-source filtering or provenance is supplied.
- Runtime serializers are emitted as strings/functions; a conventional static
  source analysis cannot establish their resulting cost from this repository
  alone.

## Assessment and follow-up

- The independent hot path and ranking agree on schema/reference traversal.
- The analyzer should carry generated-source provenance and lower or suppress
  architecture findings for it, while retaining source-level validator errors
  if a security-oriented tool needs them.
- No probable library defect. A performance hypothesis—repeated `$ref`
  resolution on recursive schemas—needs a constructed workload before it is
  treated as actionable.

## Second-pass time/space audit

- **Partial evidence:** all 38 unknown time/space results retain components.
  `resolveRef` is under-specified—string searching and schema-map traversal are
  locally visible; `build`/`traverse` are under-specified recursive schema
  walks; generated validator dispatch is appropriately opaque as generated
  runtime code. The sample is two under-specified, one appropriate.
- **Actual dominant work:** schema/reference traversal and generated serializer
  construction scale with schema nodes, properties/items, reference-chain
  depth, and emitted program size. Generated code and serializer output are the
  principal space consumers.
- **Coverage verdict:** recursive schema graphs with cycle detection and
  string/reference primitives are analyzable and should yield a symbolic bound.
  The tool finds the right functions but misses their actual time/space drivers.
