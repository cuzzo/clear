# proxy — C++

**Revision:** `dc3d95c763ec` · **Scope:** `include/proxy` · **Result:** results
are partial only. Header-only C++ is an explicit Decomplex ingestion gap, so no
cross-tool conclusion or product defect is warranted.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 6 headers, 194 methods, 8 fields; no Type Next for C++ declarations. |
| Espalier | Only 33 functions surfaced, 16 unknown and 17 known time bounds. This is materially below Nil-Kill's 194 extracted methods. |
| Decomplex | Failed before analysis: it accepted no supported source file for header-only input. |

## Independent source audit

- The library's substantive work is template/type-erasure dispatch, proxy
  construction, and meta-data adaptation. It is compile-time-heavy and
  allocation/dispatch behavior depends on instantiated facade/proxy types.
- A reported `proxy` owner in `v4/proxy.h` is plausible, but the 33-function
  result cannot represent the 194 methods Nil-Kill extracted. It is not enough
  evidence to judge either complexity or state identity.
- RAII/ownership semantics are encoded in template types and generated
  instantiations, which source-only generic function counts cannot fully model.

## Assessment and follow-up

- This repository is a high-value regression for accepting `*.h`/`*.hpp` as
  first-class production C++ input in Decomplex and for aligning function
  extraction between tools.
- Do not treat the partial Espalier output as a code-quality assessment. No
  candidate library bug was recorded.
