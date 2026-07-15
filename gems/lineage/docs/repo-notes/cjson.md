# cJSON — C

**Revision:** `fb16e5cf3587` · **Scope:** `cJSON.c`, `cJSON_Utils.c` · **Result:**
recursive parse/print and allocation cleanup are real critical paths; repeated
array-constructor findings are mostly duplication noise. No probable defect is
claimed without memory-safety reproduction.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 4 files, 154 methods, 30 fields; Type Next is not applicable to C declarations. |
| Espalier | 120/154 bounds unknown (77.9%). It identifies `parse_object` and `child` pointer lifecycle as top pressure. |
| Decomplex | 89 convergences. Four `cJSON_Create*Array` variants rank highest, followed by `print_object` and parser functions. |

## Independent source audit

- `parse_object`, `parse_array`, `print_object`, and `print_array` recursively
  traverse an input/tree and allocate or grow output buffers. They are the
  actual time, stack, and failure-cleanup surfaces.
- The `CreateInt/Float/Double/StringArray` functions share an allocation/link
  loop with repetitive cleanup. The convergence is useful for consolidation
  review but grossly overstates their individual architectural importance.
- `cJSON_Utils` manipulates `child`/linked-node relationships. Pointer state is
  semantically central, but static reads/writes do not prove a use-after-free
  or invalidation error.

## Assessment and follow-up

- Overall complexity should be reported as tree/input dependent; 34 complete
  bounds leave recursive parse/print insufficiently characterized.
- Source inspection found no candidate memory-safety defect. Such claims need
  ASan/fuzz or a minimal adversarial payload, neither of which this task runs.
- A useful analyzer enhancement is recursive-tree summaries plus a separate
  generated/repeated-family grouping, so the array constructors stop eclipsing
  parse/print in triage.
