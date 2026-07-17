# plog — C++

**Revision:** `6bee2eaa3b82` · **Scope:** `include/plog` · **Result:** partial
header-only coverage only; macro/platform formatting paths are useful adapter
tests, not trustworthy product rankings yet.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 27 headers, 153 methods, 21 fields; Type Next not applicable. |
| Espalier | 121 functions, 68 unknown (56.2%). `tm` in `Util.h` and `CsvFormatter.format` rank highest. |
| Decomplex | Blocked on header-only C++ input, so there is no Decomplex evidence. |

## Independent source audit

- Logging formatting, date/time conversion, string streams, macro gates, and
  platform conditionals are the real source shapes. Their cost depends on
  message size, enabled severity, and sink behavior.
- `CsvFormatter.format` is a small formatting boundary; its “coordinator” score
  is not evidence that it dominates production work.
- Singleton/global logger configuration and macro expansion need distinction
  between compile-time-disabled paths and runtime mutable state.

## Assessment and follow-up

- The extraction is better than proxy but still lacks Decomplex entirely; no
  one-tool ranking should be turned into product advice.
- Useful missing capability: preprocess/macro provenance and header-only
  compilation-unit handling. No probable plog defect was identified.

## Second-pass time/space audit

- **Partial evidence:** all 68 unknown time/space results retain components.
  Appender virtual I/O is appropriately opaque; `write`/`format` paths and CSV
  field assembly are under-specified string/output work. The sample is two
  under-specified, one appropriate.
- **Actual dominant work:** enabled logging is proportional to message,
  formatting fields, and sink fan-out; buffer/string allocation is the matching
  space term. Compile-time-disabled macro paths should not be ranked as runtime
  work.
- **Coverage verdict:** message-length/output-size primitives and macro
  provenance are general C++ requirements. Header-only incompleteness still
  prevents treating this as a complete audit.
