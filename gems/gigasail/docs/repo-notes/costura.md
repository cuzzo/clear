# Costura — C#

**Revision:** `55874fe54f66` · **Scope:** production `src/Costura*` projects ·
**Result:** resource embedding and assembly rewriting are genuine high-risk
boundaries; no probable defect asserted.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 25 files, 135 methods, 118 fields; Type Next is not applicable to C#. |
| Espalier | 83/132 bounds unknown (62.9%). Partial `ModuleWeaver` ownership is the dominant state owner. |
| Decomplex | 22 convergences: `EmbedResources`, reference filtering, `InnerEmbed`, loader import, and template attachment. |

## Independent source audit

- `EmbedResources` walks assemblies/resources, chooses compression/embedding,
  modifies IL/module state, and handles exceptional paths. Its high rank is
  justified; it is the project's operational core.
- `GetFilteredReferences`/`GetFilteredRuntimeReferences` traverse metadata and
  configuration. They may scale with reference count but output is typically
  build-time, not a runtime server hot path.
- `ModuleWeaver` spans multiple partial-class files. Joining this state is
  correct only if partial declarations are resolved as one symbol; file-based
  owners would otherwise create false fragmentation.

## Assessment and follow-up

- The tools correctly point at source rewriting/resource lifetime code. No
  specific leaked stream, invalid mutation, or asymptotic product was found by
  inspection.
- Big-O needs metadata/reference collection summaries. Findings should remain
  build-time maintenance signal, not a performance alarm, until workload data
  distinguishes small from huge assemblies.

## Second-pass time/space audit

- **Partial evidence:** all 83 unknown time/space results retain components.
  `EmbedResources` and reference filters are under-specified collection and
  byte-stream traversals; Cecil/assembly-loader behavior is appropriately
  opaque. The sample is two under-specified, one appropriate.
- **Actual dominant work:** resources, references, and assembly metadata are
  scanned/filtered and may be compressed or injected; time and retained buffers
  scale with input assembly/resource size. This is build-time space, not a
  runtime request cost.
- **Coverage verdict:** local foreach/filter/compression-buffer terms should be
  composed, while external metadata rewriting remains opaque. The source facts
  are sufficient for a substantially better partial bound.
