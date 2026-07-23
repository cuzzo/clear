# pluggy — Python

**Revision:** `c1a5f3ea743c` · **Scope:** `src/pluggy` · **Result:** dynamic
plugin lifecycle is correctly surfaced; no probable product defect.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 7 files, 86 methods, 81 fields; 38 Type Next candidates. |
| Espalier | 58/82 time bounds unknown (70.7%). `PluginManager` and `_name2plugin` have the highest state pressure. |
| Decomplex | `PluginManager.register`, hook construction, entry-point loading, and pending-hook validation converge across detectors. |

## Independent source audit

- `PluginManager.register` validates names, manages the name-to-plugin map,
  discovers hook implementations, and records undo state on failure. This is a
  genuine transactional state boundary.
- `load_setuptools_entrypoints` and hook dispatch are dominated by external
  entry-point discovery and user callbacks. An overall static bound would be
  misleading unless callback contracts are represented.
- `_name2plugin` is shared registry state by design. The analyzer correctly
  identifies it as important, but a write/read count cannot establish a stale
  registration or aliasing bug.

## Assessment and follow-up

- The tools distinguish core lifecycle code from trivial markers well. The
  project is a strong negative control for “dynamic dispatch is a defect.”
- Unknown Big-O is expected but still indicates a missing capability: callback
  fan-out should be reported as parameterized/opaque, rather than generic
  unknown, when receiver dispatch is intentional.
- No probable library bug. A useful future fixture is failed registration
  followed by re-registration, to validate rollback state identity.

## Second-pass time/space audit

- **Partial evidence:** all 58 unknown time/space results retain components.
  Registry lookups/registration scans and `_multicall` wrapper traversal are
  under-specified; user hook invocation is appropriately opaque. The sampled
  split is two under-specified, one appropriate.
- **Actual dominant work:** registration is proportional to discovered hook
  implementations; hook execution is proportional to implementations and
  wrapper nesting, plus user callback cost. Registry and wrapper stacks supply
  the corresponding space terms.
- **Coverage verdict:** callback cost should stay opaque, but callback count,
  wrapper depth, and local registry loops are available from the source. A
  parameterized hook-fan-out bound is a capability Espalier should provide.
