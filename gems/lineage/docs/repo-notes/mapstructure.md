# mapstructure — Go

**Revision:** `8508981c8b6c` · **Scope:** production root `*.go` files ·
**Result:** decoder/reflection paths are correctly ranked, but all 42 Big-O
results are unknown—an unambiguous Go/reflection analysis gap.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 3 files, 42 methods, 21 fields; Type Next not applicable to Go. |
| Espalier | 42/42 bounds unknown (100%). `Decoder.decodeStructFromMap` is top coordinator and `Decoder` top owner. |
| Decomplex | 33 convergences: `decodeArray`, `decodeSlice`, `Decode`, `decodeStructFromMap`, and metadata decode. |

## Independent source audit

- `Decode` dispatches based on reflection kind; `decodeArray`/`decodeSlice`
  iterate input elements and recursively decode them. `decodeStructFromMap`
  matches keys, fields, tags, embedded structures, and metadata.
- These are the actual core costs. A useful model is input element/key count ×
  destination fields/depth, with reflection helpers as opaque but bounded
  operations where appropriate.
- The detector's clone/decision reports on `Decode`/`DecodeMetadata` are
  plausible shared dispatch logic but must not obscure the recursive decoder
  behavior.

## Assessment and follow-up

- No performance or correctness defect is proven. However, zero complete
  bounds is unacceptable for a corpus deliberately centered on map/slice
  decoding; this should be a priority Espalier regression fixture.
- A future workload should vary map keys, embedded structs, and slice nesting
  to distinguish linear decode from repeated field scans. No source change is
  proposed here.

## Second-pass time/space audit

- **Partial evidence:** 42/42 unknown time/space results retain components.
  `typedDecodeHook`, `DecodeHookExec`, and composed hooks are correctly
  parameterized by hook-chain length but under-specified as final results; the
  sample contains three locally analyzable cases, no external-only case.
- **Actual dominant work:** `decodeArray`/`decodeSlice` are element-recursive;
  `decodeStructFromMap` builds key/unused maps, explores embedded fields,
  decodes fields, and may sort errors. Its bounds involve keys, fields, nested
  values, and `O(keys log keys)` error formatting; maps/errors/metadata drive
  space.
- **Coverage verdict:** reflection does not excuse losing explicit source loops
  and allocations. Espalier misses the corpus's clearest locally derivable
  time/space model and should support it generally.
