# tsup — TypeScript

**Revision:** `b6bcae8504d0` · **Scope:** `src` · **Result:** build orchestration
is correctly ranked; Big-O is not yet meaningful for its async/tool-driven
workload.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 34 files, 86 methods, 51 fields; no Type Next for a statically typed corpus. |
| Espalier | 74/86 bounds unknown (86.0%). `index.build` is the top coordinator with 58 conditional calls. |
| Decomplex | 29 convergences: `runEsbuild`, plugin completion, DTS rollup, CLI main, and build orchestration. |

## Independent source audit

- `build` normalizes options, creates one or more build contexts, selects watch
  behavior, and schedules external Esbuild/Rollup work. It deserves its top
  ranking, but runtime is dominated by tool and filesystem inputs.
- `runEsbuild`, `buildFinished`, and `rollupDtsFile` cross plugin/subprocess
  boundaries. Their conditionals represent compatibility/error handling, not a
  static claim of superlinear CPU work.
- Plugin container context is the only high-state object. The limited state
  pressure is consistent with an orchestration library rather than an
  accidental global-state design.

## Assessment and follow-up

- Signal is strong for architecture triage; Big-O has only 12 complete bounds,
  so it must not be used to prioritize performance changes yet.
- No candidate product bug. The missing feature is an I/O/tool boundary model
  that reports “per entry / per plugin / external” components instead of losing
  the entire bound to unknown.
