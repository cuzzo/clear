# Nil-Kill Multi-Language Support Design

## Goal

Modernize Nil-Kill so language support is added through explicit adapters and stable data contracts instead of Ruby-shaped runtime facts leaking through the whole system.

Nil-Kill should have five separable concerns:

1. Static analysis
2. Runtime tracing
3. Analysis of runtime traces
4. Reporting
5. Auto-fixing

The target architecture lets someone add a Python, JavaScript/TypeScript, or Lua tracer by emitting the documented trace format. Nil-Kill should then normalize, analyze, and report on those traces without tracer-specific code paths. Auto-fixing remains Ruby-only initially, but the design should make it straightforward to add fix providers for other languages later.

## Non-Goals

- Do not require non-Ruby tracers to mimic Ruby internals such as ivars, Sorbet sigs, or `T.let`.
- Do not require every language to support auto-fixing.
- Do not make reporting read raw trace files directly.
- Do not make runtime tracing mandatory for static-only reports.
- Do not force every language to implement the same type-system surface area.
- Do not change current Ruby output unless a versioned report format explicitly calls that out.

## Current Problem

Nil-Kill currently has a Ruby-first pipeline where several concerns are coupled:

- Static indexing is tied to Ruby source shape and Sorbet concepts.
- Runtime collection is tied to Ruby instrumentation and Ruby `Coverage`.
- Runtime loading, normalization, and evidence storage happen inside inference flow.
- Action proposal assumes Ruby-oriented targets and fix kinds.
- Reporting reads evidence that still contains Ruby-specific concepts.
- Auto-fixing is implemented as a Ruby source rewrite pipeline.

That makes the existing path effective for Ruby, but hard to extend. A Python tracer, for example, should not need to invent fake Ruby ivars or Sorbet sig data just to make reports work. It should emit trace events, let Nil-Kill normalize them into common evidence, and then allow analyzers/reporters to operate on that evidence.

## Proposed Architecture

```text
Language Static Adapter
        |
        v
 Static Evidence v2
        |
        v
 Evidence Store <---- Runtime Evidence v2 <---- Trace Normalizer <---- Raw Trace Events v1
        |
        v
 Generic + Language Analyzers
        |
        v
 Actions
        |
        +----> Reporter
        |
        +----> Optional AutoFix Provider
```

Core rules:

- Static adapters produce normalized static evidence.
- Runtime tracers emit raw JSONL events that follow a stable schema.
- Trace normalization is the only layer that reads raw tracer events.
- Analyzers consume normalized static and runtime evidence.
- Reporters consume normalized evidence and actions, not language-specific trace files.
- Auto-fix providers are optional per language and consume actions plus source metadata.

## Stable Identity Model

Nil-Kill needs stable-enough identifiers that work across languages and runs.

Recommended IDs:

- `symbol_id`: `language\0path\0owner\0kind\0name\0line`
- `method_id`: `language\0path\0owner\0method\0name\0line`
- `field_id`: `language\0path\0owner\0field\0name`
- `callsite_id`: `language\0path\0line\0column\0callee`

These are not intended to be globally semantic forever. They are deterministic join keys for one repository snapshot. Each evidence bundle should also include file digests so stale trace data can be rejected or marked low-confidence.

Ruby compatibility can keep aliases for existing `[owner, method, kind]` keys during migration, but new code should use the language-neutral IDs.

## Evidence Bundle Format

Normalized evidence should be persisted as one versioned bundle:

```json
{
  "schema_version": 2,
  "tool": "nil-kill",
  "generated_at": "2026-06-13T00:00:00Z",
  "root": "/repo",
  "languages": ["ruby", "python"],
  "targets": ["app", "lib"],
  "static": {},
  "runtime": {},
  "actions": [],
  "diagnostics": [],
  "metadata": {}
}
```

The bundle is the contract between phases. Reports and auto-fix providers should be able to run from this bundle without re-reading raw traces.

## Static Evidence v2

Static evidence describes source structure and language-level declarations. It can come from Tree-sitter, a language-native parser, type-checker output, or a combination.

Recommended top-level sections:

```json
{
  "files": [],
  "owners": [],
  "methods": [],
  "fields": [],
  "callsites": [],
  "state_reads": [],
  "state_writes": [],
  "param_origins": [],
  "return_origins": [],
  "nil_guards": [],
  "type_assertions": [],
  "collections": [],
  "language_extensions": {}
}
```

### Files

```json
{
  "path": "lib/example.rb",
  "language": "ruby",
  "digest": "sha256:...",
  "parser": "tree-sitter-ruby",
  "parser_version": "..."
}
```

### Owners

Owners are classes, modules, namespaces, structs, objects, or files depending on language.

```json
{
  "id": "ruby\u0000lib/example.rb\u0000Example\u0000owner\u0000Example\u00001",
  "name": "Example",
  "kind": "class",
  "path": "lib/example.rb",
  "span": {"start_line": 1, "start_column": 0, "end_line": 20, "end_column": 3},
  "language": "ruby"
}
```

### Methods

Methods also cover functions, closures when nameable, constructors, test bodies, and top-level functions.

```json
{
  "id": "python\u0000pkg/a.py\u0000User\u0000method\u0000name\u000012",
  "owner_id": "python\u0000pkg/a.py\u0000User\u0000owner\u0000User\u00001",
  "owner": "User",
  "name": "name",
  "kind": "method",
  "path": "pkg/a.py",
  "line": 12,
  "span": {"start_line": 12, "start_column": 2, "end_line": 15, "end_column": 0},
  "params": [
    {"name": "self", "declared_type": null, "nilable": null},
    {"name": "fallback", "declared_type": "str | None", "nilable": true}
  ],
  "return": {"declared_type": "str", "nilable": false},
  "signature": {"source": "annotation", "raw": "def name(self, fallback: str | None) -> str"},
  "visibility": "public",
  "language": "python"
}
```

### Fields

Fields include Ruby ivars, Python attributes, TypeScript object properties, Lua table fields, and Zig struct fields when those languages are supported.

```json
{
  "id": "typescript\u0000src/user.ts\u0000User\u0000field\u0000name",
  "owner_id": "typescript\u0000src/user.ts\u0000User\u0000owner\u0000User\u00001",
  "name": "name",
  "declared_type": "string | null",
  "nilable": true,
  "static_origin": "property_declaration",
  "language": "typescript"
}
```

### Language Extensions

Language-specific data belongs under `language_extensions`, keyed by language. This prevents the canonical schema from growing Ruby-only concepts while preserving useful detail.

```json
{
  "language_extensions": {
    "ruby": {
      "sorbet_sigs": [],
      "t_lets": [],
      "rbi_symbols": []
    },
    "typescript": {
      "compiler_symbols": []
    }
  }
}
```

## Raw Runtime Trace Events v1

Runtime tracers should emit JSONL. Each line is one event.

Common fields:

```json
{
  "schema_version": 1,
  "event": "method_return",
  "language": "python",
  "run_id": "uuid",
  "pid": 123,
  "thread_id": "main",
  "timestamp_ns": 123456789,
  "path": "pkg/a.py",
  "line": 12,
  "method_id": null,
  "locator": {
    "owner": "User",
    "name": "name",
    "kind": "method"
  },
  "payload": {}
}
```

The tracer may provide `method_id` if it can compute the same ID as static analysis. Otherwise it should provide a locator. The normalizer resolves locators to IDs using static evidence.

### Required Event Types

A useful tracer should emit at least:

- `process_start`
- `process_end`
- `method_call`
- `method_return` or `return_observed`
- `param_observed`
- `coverage` or method hit counts

### Optional High-Value Event Types

- `method_raise`
- `field_observed`
- `collection_observed`
- `hash_shape_observed`
- `call_edge`
- `type_assertion_observed`
- `branch_observed`
- `nil_guard_observed`

### Example Param Event

```json
{
  "schema_version": 1,
  "event": "param_observed",
  "language": "javascript",
  "run_id": "run-1",
  "pid": 42,
  "thread_id": "main",
  "timestamp_ns": 100,
  "path": "src/user.js",
  "line": 8,
  "locator": {"owner": null, "name": "displayName", "kind": "function"},
  "payload": {
    "param": "fallback",
    "type": {"name": "null", "kind": "null", "nullable": true, "language": "javascript", "display": "null"},
    "sample_count": 1
  }
}
```

## Runtime Type Model

Raw events should not be forced into Ruby class names. They should use a normalized runtime type object:

```json
{
  "name": "Array",
  "kind": "array",
  "nullable": false,
  "language": "javascript",
  "display": "Array<string | null>",
  "confidence": "observed",
  "members": [
    {"name": "string", "kind": "primitive", "nullable": false, "language": "javascript", "display": "string"},
    {"name": "null", "kind": "null", "nullable": true, "language": "javascript", "display": "null"}
  ]
}
```

Allowed `kind` values:

- `primitive`
- `class`
- `struct`
- `interface`
- `union`
- `array`
- `map`
- `record`
- `function`
- `null`
- `unknown`

The normalizer can project this model into Ruby/Sorbet display types when needed. The normalized store should retain the language-neutral form.

## Runtime Evidence v2

The trace normalizer reads raw events and static evidence, then emits normalized runtime evidence.

Recommended sections:

```json
{
  "runs": [],
  "method_hits": {},
  "param_observations": {},
  "return_observations": {},
  "field_observations": {},
  "collection_observations": {},
  "hash_shape_observations": {},
  "call_edges": [],
  "coverage": {},
  "exceptions": {},
  "diagnostics": []
}
```

Normalizer responsibilities:

- Resolve raw event locators to static IDs.
- Merge repeated observations deterministically.
- Track counts and run IDs.
- Preserve unresolved events as diagnostics.
- Mark evidence stale when source digests do not match.
- Convert language-native runtime samples into the common runtime type model.
- Emit compatibility aliases for existing Ruby report paths during migration.

Unresolved events should not be dropped silently. They should become diagnostics such as:

```json
{
  "severity": "warning",
  "code": "unresolved_method_locator",
  "path": "pkg/a.py",
  "line": 12,
  "locator": {"owner": "User", "name": "name", "kind": "method"}
}
```

## Analyzer Layer

The current inference flow should be split into smaller units:

- `StaticEvidenceLoader`: loads static evidence files.
- `RuntimeTraceLoader`: streams raw trace JSONL.
- `RuntimeNormalizer`: produces runtime evidence.
- `EvidenceStore`: stores canonical static/runtime facts and legacy aliases.
- `Analyzers::*`: produce findings from evidence.
- `ActionProposers::*`: convert findings into action records.

Generic analyzers should operate on normalized evidence:

- Runtime nil observed in a non-null static slot.
- Runtime type differs from declared/static type.
- Field shape differs from static declaration.
- Collection or record element shape pressure.
- Unreached methods, branches, or guards.
- Fallibility/exception evidence.
- Deterministic nil guards.

Ruby-specific analyzers should remain isolated:

- Sorbet sig narrowing.
- `T.let` narrowing.
- RBI-specific recommendations.
- Ruby guard autocorrection.
- Ruby hash-record promotion.

## Action Format

Actions are the bridge between analysis, reporting, and optional auto-fixing.

```json
{
  "schema_version": 2,
  "id": "action-1",
  "kind": "fix_signature_param",
  "language": "ruby",
  "confidence": "high",
  "target": {
    "path": "lib/example.rb",
    "line": 10,
    "span": {"start_line": 10, "start_column": 8, "end_line": 10, "end_column": 20},
    "symbol_id": "ruby\u0000lib/example.rb\u0000Example\u0000method\u0000call\u000010"
  },
  "preconditions": [
    {"kind": "file_digest", "value": "sha256:..."}
  ],
  "edits": [],
  "data": {
    "param": "name",
    "from": "String",
    "to": "T.nilable(String)"
  },
  "provenance": {
    "static": ["method-id"],
    "runtime": ["run-1"]
  }
}
```

Recommended generic action kinds:

- `fix_signature_param`
- `fix_signature_return`
- `add_type_annotation`
- `narrow_field_type`
- `add_nullability`
- `remove_dead_nil_guard`
- `replace_deterministic_guard`
- `promote_hash_record`
- `add_runtime_assertion`
- `manual_review`

Ruby legacy action names can be mapped to these generic action kinds while preserving old report output during migration.

## Reporting

Reporting should be a pure projection of evidence plus actions.

Reporter inputs:

- Evidence bundle v2.
- Optional action file if actions are generated separately.
- Reporter options such as format, severity threshold, and compatibility mode.

Reporter outputs:

- Existing Ruby report format by default for Ruby projects.
- Multi-language report format when evidence includes non-Ruby languages.
- Diagnostics for missing runtime data, stale files, unsupported auto-fix providers, and unresolved trace events.

Report code should not know how to parse Python trace events, Ruby instrumentation logs, or JavaScript coverage files. That logic belongs to the normalizer.

## Auto-Fix Provider Interface

Auto-fixing is optional and language-specific.

Provider interface:

```ruby
module NilKill
  module AutoFix
    class Provider
      def language = raise NotImplementedError
      def supports?(action) = raise NotImplementedError
      def plan(action, source_index) = raise NotImplementedError
      def apply(plan, workspace) = raise NotImplementedError
      def verify(plan, command_runner) = raise NotImplementedError
    end
  end
end
```

Initial providers:

- `AutoFix::RubyProvider`: wraps the existing Ruby apply/autocorrect flow.
- `AutoFix::NullProvider`: returns unsupported diagnostics and leaves actions report-only.

Future providers:

- Python: likely use LibCST, Ruff, Pyright, or MyPy-aware transforms.
- JavaScript/TypeScript: likely use TypeScript compiler API, ts-morph, ESLint, or Biome.
- Lua: likely use Tree-sitter edits plus StyLua formatting, or a Lua CST library if one is adopted.

Provider invariants:

- A provider must declare which action kinds it supports.
- Unsupported actions remain visible in reports and do not fail the run.
- A provider must check file digests before mutating source.
- A provider should verify with the language's normal formatter/type checker/test command when available.

## CLI Shape

Keep existing commands as compatibility wrappers, but expose the pipeline explicitly.

Proposed commands:

```text
nil-kill static --language ruby --output static.json
nil-kill collect --tracer ruby --output traces/ -- bundle exec ruby test.rb
nil-kill normalize --static static.json --traces traces/ --output evidence.json
nil-kill analyze --evidence evidence.json --output actions.json
nil-kill report --evidence evidence.json --actions actions.json
nil-kill apply --actions actions.json --provider ruby
nil-kill trace-spec
```

Compatibility wrappers:

- Existing Ruby collect/infer/report/apply commands should call the new phases internally.
- Existing report output should remain stable unless `--format v2` or similar is requested.

## Suggested Module Layout

```text
lib/nil_kill/schema/
lib/nil_kill/static/
lib/nil_kill/tracing/
lib/nil_kill/runtime/
lib/nil_kill/analyzers/
lib/nil_kill/actions/
lib/nil_kill/reporting/
lib/nil_kill/autofix/
lib/nil_kill/languages/ruby/
lib/nil_kill/languages/python/
lib/nil_kill/languages/javascript/
lib/nil_kill/languages/typescript/
lib/nil_kill/languages/lua/
```

Ruby-specific files should move under `languages/ruby` over time. Shared schema, storage, analysis, and reporting code should remain language-neutral.

## Relationship To Tree-Sitter Work

Nil-Kill should reuse the generalized Tree-sitter layer already built for the other gems where possible.

Near-term path:

- Expand the current Nil-Kill static evidence to the Static Evidence v2 schema.
- Use Tree-sitter for language-neutral structure: files, owners, methods/functions, params, fields, callsites, guards, and branches.
- Keep richer Ruby/Sorbet extraction in the Ruby adapter.
- Add language profiles for Python, JavaScript, TypeScript, and Lua as their nullability/type annotation conventions become useful.

Tree-sitter should provide static structure. It should not be responsible for runtime traces or auto-fixes.

## Language Adapter Expectations

### Ruby

- Static: existing Ruby/Sorbet indexing plus Tree-sitter structure where helpful.
- Runtime: existing Ruby tracer wrapped into Raw Runtime Trace Events v1.
- Analysis: full existing Nil-Kill behavior.
- Auto-fix: supported through `AutoFix::RubyProvider`.

### Python

- Static: Tree-sitter plus Python annotations; optionally consume MyPy/Pyright output later.
- Runtime: `sys.settrace`, coverage.py data, or a small wrapper around tests.
- Analysis: params, returns, attributes, call edges, coverage, and nil/`None` evidence.
- Auto-fix: future provider, likely LibCST-based.

### JavaScript/TypeScript

- Static: Tree-sitter for JS, Tree-sitter or TypeScript compiler API for TS.
- Runtime: Node/V8 hooks, Istanbul coverage, or test-runner integration.
- Analysis: params, returns, properties, object shapes, `null`/`undefined`, coverage.
- Auto-fix: future provider using TypeScript compiler API, ts-morph, ESLint, or Biome.

### Lua

- Static: Tree-sitter Lua once included in the shared syntax layer.
- Runtime: `debug.sethook` plus wrapped function entry/exit where feasible.
- Analysis: params, returns, table fields, nil evidence, coverage-like hit counts.
- Auto-fix: future provider, likely limited until a reliable CST rewrite path is chosen.

## Migration Plan

1. Add schema objects and validators for Static Evidence v2, Raw Runtime Trace Events v1, Runtime Evidence v2, and Actions v2.
2. Wrap current Ruby runtime JSONL into Raw Runtime Trace Events v1 without changing existing Ruby command output.
3. Extract current runtime loading from inference into `RuntimeTraceLoader` and `RuntimeNormalizer`.
4. Emit Runtime Evidence v2 plus legacy Ruby aliases from the normalizer.
5. Extract current action generation into analyzer/action proposer classes that consume normalized evidence.
6. Move report rendering to consume evidence/actions only.
7. Move Ruby apply logic behind `AutoFix::RubyProvider`.
8. Keep existing CLI commands as wrappers over the new phases.
9. Add golden fixtures for a minimal Python static index and raw trace; verify Nil-Kill can normalize, analyze, and report without a Python auto-fixer.
10. Add equivalent JS/TS and Lua trace fixtures before adding real tracers.
11. Add real tracer spikes one language at a time.

## Acceptance Tests

Required tests:

- Ruby reports remain byte-for-byte stable in compatibility mode.
- Existing Ruby auto-fix tests pass through `AutoFix::RubyProvider`.
- Raw trace schema validation rejects malformed events with clear diagnostics.
- Normalization is deterministic for repeated runs.
- A fake Python trace plus static evidence produces param, return, field, and coverage evidence.
- A fake JS/TS trace distinguishes `null`, `undefined`, and missing properties.
- A fake Lua trace reports table field nil observations.
- Unsupported auto-fix providers produce report diagnostics instead of failing.
- Stale runtime traces are detected through file digest mismatches.

## Compatibility Strategy

During migration, normalized evidence should emit both:

- Canonical v2 fields.
- Legacy Ruby aliases used by existing reports and apply code.

Once the report and apply paths consume only v2 evidence/actions, the legacy aliases can be deprecated behind a compatibility flag.

The old command behavior should remain the default until the new pipeline has golden coverage for Ruby. New multi-language commands can opt into v2 output immediately.

## Non-Negotiable Invariants

- Schemas are versioned and append-only within a major version.
- Normalized evidence is deterministic.
- Analyzers never read raw trace files directly.
- Reporters never read raw trace files directly.
- Auto-fix never mutates source without an explicit provider and file digest precondition.
- Missing language support degrades to diagnostics and report-only findings, not crashes.
- Ruby remains the reference implementation, but not the shape every language must imitate.
