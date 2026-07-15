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
