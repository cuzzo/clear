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
