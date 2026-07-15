# go-immutable-radix — Go

**Revision:** `65dce5bf5254` · **Scope:** production root `*.go` files ·
**Result:** iterator and persistent-update paths are correctly surfaced;
structural sharing prevents state-pressure findings from implying mutation
bugs.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 7 files, 69 methods, 30 fields; no Type Next for Go. |
| Espalier | 52/69 bounds unknown (75.4%). `Txn[T]` is top owner; `insert` is top coordinator. |
| Decomplex | 34 convergences: `SeekLowerBound`, `Next`, `delete`, `deletePrefix`, and reverse iteration. |

## Independent source audit

- `SeekLowerBound`, `Next`, and reverse iteration descend/advance through radix
  edges. Complexity depends on key length, tree height, and branching—not only
  a local loop count.
- `Txn.insert`, `delete`, and `deletePrefix` copy/relink the path to preserve
  immutable tree versions. Their state writes are local transaction assembly,
  not shared mutable-root corruption.
- The reported `Tree.root` lifecycle score is zero, consistent with immutable
  publication. That is a useful negative control for state identity analysis.

## Assessment and follow-up

- Decomplex finds the difficult functions, although it overreports their
  inherent case analysis as refactoring pressure. No product bug found.
- Espalier should represent `O(key length + traversal height)`/copy-path space
  rather than generic unknown. This repository is an important oracle for
  avoiding false mutable-alias conclusions on persistent structures.

## Second-pass time/space audit

- **Partial evidence:** all 52 unknown time/space results retain components.
  `Tree.Insert`, `DeletePrefix`, and iterator seek are locally analyzable radix
  path traversals/copies; the three sampled wrappers are all under-specified.
- **Actual dominant work:** lookup/seek/insert/delete depend on key length and
  traversed radix height; transactions copy changed paths and edges, which is
  the principal allocation term. `longestPrefix` supplies a direct key-length
  loop that should compose into callers.
- **Coverage verdict:** this is a general interprocedural recursive-structure
  gap. Espalier should find these symbolic bounds and should not hide them
  merely because public methods delegate to transaction methods.
