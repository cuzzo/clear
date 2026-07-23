# rtree — Java

**Revision:** `364c739f2987` · **Scope:** `src/main/java` · **Result:** real
tree search/insertion is less prominent than serialization/geometry helpers;
this is a meaningful analyzer prioritization gap, not a product defect claim.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 88 files, 752 methods, 208 fields; no Type Next for Java. |
| Espalier | 296/529 bounds unknown (55.9%). `RTree` is top owner, but `FlatBuffersHelper.addEntries` is top coordinator. |
| Decomplex | Ten convergences concentrate on geometry equality/intersection helpers rather than core recursive tree operations. |

## Independent source audit

- `RTree.add`, delete paths, and search descend a persistent spatial hierarchy,
  select child nodes, and may rebuild structure. These are the main algorithmic
  costs and need bounds in terms of height, branching, and result count.
- `FlatBuffersHelper.addEntries` is a real serialization loop but not the core
  spatial algorithm. Its top rank demonstrates call/branch counting outranking
  semantic data-structure traversal.
- Geometry `equals`, `intersects`, and `contains` are bounded primitive
  operations; their detector convergence is noise for architecture triage.

## Assessment and follow-up

- This is a key regression corpus for nested traversal and structural-sharing
  complexity. Espalier should attach symbols to tree height/node/result inputs,
  rather than leaving the important algorithms opaque.
- No probable RTree bug. A future ground-truth test should assert that search
  and insertion rank above geometry helpers under a traversal-aware model.

## Second-pass time/space audit

- **Partial evidence:** all 296 unknown time/space results retain components.
  `search`, `searchLeaf`, and `searchNonLeaf` are under-specified tree
  traversals; selector/geometry contracts introduce appropriate opaque terms.
  The sample is two under-specified, one appropriate.
- **Actual dominant work:** search visits candidate nodes and returns matches;
  insertion/deletion descend tree height and may split/rebuild persistent nodes.
  Time depends on height, branching, overlap, and results; space includes
  traversal stacks, result streams, and copied path nodes.
- **Coverage verdict:** recursive tree traversal and structural-sharing facts
  are source-visible and should be modeled. Espalier currently misses the
  library's most algorithmically significant time/space functions.
