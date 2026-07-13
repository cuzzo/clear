# Measuring True Clean Transpilation

Status: implementation plan

Checkpoint: `b2bb9787b`

## Problem

The current audit does not measure clean transpilation. It measures whether the
Ruby source was traversed and whether lax output contains unsupported comments.
In particular, `RubyToClear::Audit#analyze_transpile`:

1. calls the transpiler with `raise_on_error: false`;
2. counts source lines represented by `# [UNSUPPORTED: ...]` blocks;
3. calls a file complete when that count is zero.

It does not ask the CLEAR parser, annotator, ownership checker, backend, Zig
compiler, or the original Ruby implementation whether the output is valid.
Therefore the existing LoC and Prism-node percentages are structural emission
coverage, not clean transpilation coverage.

The parser work demonstrates the distinction. Nearly all Ruby source and Prism
nodes can be emitted while the generated CLEAR still fails on invalid names,
wrong union variants, missing fields, borrowed values, optional values, and
scope errors. An emitted file with any such error is not cleanly transpiled.

The honest whole-repository clean-transpilation percentage is currently
**unknown**. We will not estimate it from the existing audit.

## Definitions

Every source unit will be evaluated through independent gates. Passing an
earlier gate must never be reported as passing a later one.

| Gate | Name | Requirement |
| --- | --- | --- |
| G0 | Ruby parsed | Prism parses the source without errors. |
| G1 | Strictly emitted | `ruby-to-clear --strict` exits successfully and emits no unsupported escape hatch. |
| G2 | CLEAR parsed | The emitted CLEAR is accepted by the real CLEAR parser. |
| G3 | CLEAR analyzed | Name resolution, types, effects, ownership, lifetimes, and all frontend checks pass. |
| G4 | Backend built | CLEAR emits Zig and Zig compiles the result in the unit's real build mode. |
| G5 | Behavior verified | A Ruby/CLEAR differential oracle produces identical canonical output. |

The report will use these terms:

- **structurally emitted**: G1 only;
- **frontend clean**: G1 through G3;
- **build clean**: G1 through G4 on raw generated output;
- **verified equivalent**: G1 through G5.

The unqualified phrase **clean transpilation** means build clean. Behavioral
equivalence is reported separately because code can compile and still be wrong.

## Non-Negotiable Rules

1. Generated CLEAR is tested before any formatter or autofix mutates it.
2. Autofix-assisted success is a separate result and never counts as raw clean.
3. Lax placeholders, unsupported comments, `unsupportedRuby`, or equivalent
   escape hatches fail G1 even if the remaining file compiles.
4. A frontend error fails every later gate. Emitting Zig text is not success.
5. A Zig compile error fails G4 even when CLEAR frontend analysis passed.
6. A runtime mismatch fails G5 even when both implementations exit zero.
7. Timeouts, compiler crashes, and harness crashes are failures with their own
   categories, not exclusions from the denominator.
8. Generated LoC is never used as the denominator. Metrics are based on the
   original Ruby source units and source LoC.
9. Prism-node coverage is never presented as semantic correctness.
10. Every headline number must link to a machine-readable run artifact.

## Evaluation Unit

Initially, the conservative unit is a complete Ruby file plus the dependency
closure needed to compile its generated CLEAR. A file's source LoC counts as
clean only when the complete file passes the relevant gate.

This deliberately under-credits partially working files. Later, declaration-
level source maps can provide finer attribution, but they must not infer that
code after the compiler's first error was valid.

Each unit will be described in a checked-in manifest with:

- Ruby source path;
- generated CLEAR path;
- helper configuration;
- library, program, or test build mode;
- required generated CLEAR dependencies;
- package flags and build settings;
- timeout;
- optional differential oracle and fixture corpus.

The manifest prevents false failures caused by compiling a library file as a
standalone executable, and false successes caused by silently omitting its real
dependencies.

## Verifier

Add a new executable, provisionally `ruby-to-clear-verify`. It will not replace
the Prism audit. It will orchestrate the actual toolchain and write immutable
artifacts for each run.

For every manifest unit it will:

1. parse the Ruby source with Prism;
2. transpile with strict mode into a fresh temporary directory;
3. scan for forbidden escape hatches and record the generated-file hash;
4. invoke the real CLEAR frontend with the unit's package/dependency closure;
5. distinguish CLEAR parse, semantic, ownership/lifetime, and backend failures;
6. compile the emitted Zig using the same mode used by `./clear build` or
   `./clear test`;
7. when configured, run Ruby and CLEAR against identical fixtures;
8. canonicalize oracle output, then compare bytes;
9. save commands, exit statuses, timings, stdout, stderr, diagnostics, and
   tool revisions;
10. emit JSON for automation and Markdown for humans.

The verifier must use process argument arrays rather than shell-composed
commands, enforce per-stage timeouts, and preserve the first failing artifact.
It must be deterministic when run twice at the same revision.

Proposed output layout:

```text
tmp/ruby-to-clear-verify/<run-id>/
  report.json
  report.md
  units/<unit>/generated.clear
  units/<unit>/generated.zig
  units/<unit>/commands.json
  units/<unit>/stdout.log
  units/<unit>/stderr.log
  units/<unit>/oracle.ruby.msgpack
  units/<unit>/oracle.clear.msgpack
```

## Failure Taxonomy

Every failed unit gets one primary stage and all available diagnostics.

| Code | Category |
| --- | --- |
| R0 | Ruby/Prism parse failure |
| T0 | Transpiler exception |
| T1 | Unsupported or placeholder output |
| C0 | CLEAR syntax/parse failure |
| C1 | CLEAR name or declaration failure |
| C2 | CLEAR type or union failure |
| C3 | CLEAR effect, mutability, ownership, or lifetime failure |
| C4 | CLEAR backend/Zig-emission failure |
| Z0 | Zig compile or link failure |
| B0 | Runtime crash or nonzero exit |
| B1 | Differential output mismatch |
| F0 | Raw output fails but temporary autofixed output passes |
| H0 | Harness timeout or crash |

Diagnostics will also be grouped by normalized fingerprint so one transpiler
bug affecting hundreds of files is visible as one root cause with a large blast
radius.

## Metrics

The primary dashboard will report both file-weighted and source-LoC-weighted
results for every gate:

```text
G1 strict emission:       passed files / all files; passed source LoC / all source LoC
G2 CLEAR parse:           passed files / all files; passed source LoC / all source LoC
G3 CLEAR frontend:        passed files / all files; passed source LoC / all source LoC
G4 build clean:           passed files / all files; passed source LoC / all source LoC
G5 verified equivalent:   passed oracle cases / all oracle cases
```

The report will additionally show:

- raw-clean versus autofix-assisted counts;
- failures by stage and diagnostic fingerprint;
- regressions and improvements relative to a pinned baseline report;
- compile time and timeout counts;
- units with no behavioral oracle;
- exact corpus and manifest coverage.

No aggregate may collapse G1 through G4 into a single “transpiled” number.

## Prism-Node Metrics

Prism statistics remain useful for prioritization, but their labels must be
honest:

- **encountered**: the node appeared in parsed Ruby;
- **handler present**: the transpiler dispatched it without an unsupported
  fallback;
- **compile exercised**: the node appeared in a unit that passed G4;
- **behavior exercised**: the node appeared in a G5 fixture;
- **behavior verified**: every relevant fixture containing that node matched.

A node handler is not “clean” merely because it returned a string. A node type
with 99% handler coverage and 0% G4 exercise is reported as 0% build-verified.
Node occurrences in a failed file are not credited as compile exercised until
declaration-level source mapping can prove their generated regions were checked.

## Behavioral Oracles

Compilation detects garbage that errors. Differential tests detect garbage that
compiles.

The first high-value oracles are:

1. lexer token streams encoded in MessagePack;
2. parser ASTs encoded in MessagePack with stable type tags and field order;
3. diagnostic codes, spans, and structured metadata;
4. focused fixtures for mutation, optional values, unions, blocks, keyword
   arguments, exceptions, and collection operations.

Ruby and CLEAR must consume identical input bytes. Their outputs must be
canonicalized independently and compared byte-for-byte. Sorting or dropping
fields solely to make outputs agree is forbidden. Any intentional normalization
must be documented as part of the shared serialization contract.

Oracle results are reported as cases, not extrapolated to untested files. A
build-clean file without an oracle remains build clean, not verified equivalent.

## Autofix Measurement

Autofix is valuable, but it must not hide transpiler defects.

For a raw G2/G3 failure, the verifier may copy the artifact, run CLEAR autofix
in the temporary directory, and retry. It records:

- whether autofix changed the file;
- the exact diff;
- whether the fixed artifact passes G2 through G4;
- normalized fix categories, including missing `!`, `MUTABLE`, or `COPY`.

This produces two actionable numbers:

- raw build-clean percentage;
- fix-assisted build-clean percentage.

The gap is transpiler debt. It is never merged into the raw result, and fixed
generated files are never written back as the source of truth.

## Rollout

### Phase 1: Make The Current Claim Honest

- Rename current audit output from “translation coverage” to “structural
  emission coverage”.
- Add a disclaimer that it does not compile generated CLEAR.
- Remove “complete” or redefine it as “no unsupported markers”.
- Check in a corpus manifest and JSON report schema.

### Phase 2: Implement G1 Through G4

- Build `ruby-to-clear-verify` with isolated artifacts and timeouts.
- Start with known dependency closures for lexer and parser.
- Add compiler library units next, then expand to the complete manifest.
- Store the first baseline without attempting to improve the number.

### Phase 3: Add Differential G5

- Finish byte-identical lexer and parser MessagePack harnesses.
- Add fixture families for common lowering semantics.
- Record oracle coverage independently from build coverage.

### Phase 4: Add Provenance

- Emit a sidecar map from Ruby file/declaration/Prism node locations to generated
  CLEAR spans.
- Attribute diagnostics back to Ruby declarations.
- Introduce declaration-level clean LoC only after the mapping is tested against
  multiline and generated-helper cases.

### Phase 5: Enforce CI

- Fail CI on any regression in G3, G4, or existing G5 cases.
- Fail CI when forbidden escape hatches appear in a previously clean unit.
- Require an explicit baseline update with a report diff for corpus changes.
- Ratchet thresholds upward; never replace a lower-gate metric with a higher
  sounding label.

## Initial Success Criteria

The measurement project is complete when:

1. one command evaluates the checked-in corpus manifest from Ruby through Zig;
2. the command exits nonzero when any claimed-clean unit fails its gate;
3. raw and autofix-assisted results are separate;
4. every failure has a reproducible command and retained artifact;
5. lexer and parser differential results are byte-identical or clearly failed;
6. the report states the exact build-clean percentage without using Prism-node
   or unsupported-comment coverage as a proxy;
7. rerunning the same revision produces the same classifications;
8. no file is called clean merely because the transpiler emitted text.

Until those criteria are met, the project status is: structural coverage is
high, true clean-transpilation coverage is unknown, and parser evidence proves
the two numbers are not interchangeable.
