# tsup — TypeScript

**Revision:** `b6bcae8504d0` · **Scope:** `src` · **Result:** build orchestration
is correctly ranked; Big-O is not yet meaningful for its async/tool-driven
workload.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 34 files, 86 methods, 51 fields; **30** ranked Type Next candidates after enabling gradual-TypeScript advice. `runEsbuild.options` unlocks 17 flow facts. |
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

## Second-pass time/space audit

- **Partial evidence:** all 74 unknown time/space results retain components.
  `rollupDtsFiles` has a correct local `O(N)` component but no final bound;
  `runEsbuild`/DTS tool calls are appropriately opaque; file cleanup is
  under-specified. The sample is two appropriate, one under-specified.
- **Actual dominant work:** build work scales with entries, formats, plugins,
  emitted files, and the external Esbuild/Rollup graphs. Memory includes build
  contexts and generated bundle/declaration material.
- **Coverage verdict:** Espalier should compose entry/file/plugin loops and
  label external tool cost separately. It cannot honestly infer the external
  bundler algorithm, but it should not discard the local dimensions.
