# Espalier Tree-sitter Migration Design

Status: implemented. This document is kept as migration context; references to
the old Prism extractor describe the pre-migration state unless a section
explicitly says otherwise.

## Goal

Make Espalier usable on the same Tree-sitter-backed source languages as
Decomplex, SlopCop, and Boobytrap while preserving Espalier's current role as
an architecture-level synthesis tool.

The immediate scope is static analysis only. Nil-Kill's richer runtime,
nilability, Sorbet, rewrite, and Ruby instrumentation paths can remain
Ruby-specific while Espalier learns to consume language-neutral static evidence.

Current target languages are the languages already supported by
`Decomplex::Syntax`:

- Ruby
- Python
- JavaScript
- TypeScript
- Go
- Rust
- Zig

Lua is a future Nil-Kill target, but it is not currently in the shared
Decomplex language set. Supporting Lua consistently should start by adding a
Decomplex Tree-sitter language profile and grammar loading path, then letting
Espalier and Nil-Kill consume the same facts.

## Non-Goals

- Do not make Espalier own nilability, type inference, or rewrite logic.
- Do not make Nil-Kill depend on Espalier.
- Do not build sound whole-program semantic analysis.
- Do not require every language to provide identical evidence on day one.
- Do not change Espalier's architectural report categories unless the manifest
  evidence cannot support the old category outside Ruby.

## Dependency Direction

Nil-Kill should not depend on Espalier for static analysis data. Espalier is the
architecture aggregator and report consumer; Nil-Kill is an evidence producer.
Reversing that relationship would make Nil-Kill depend on report-level
architecture concepts and would couple two gems that should stay independently
usable.

The right dependency direction is:

```text
Decomplex::Syntax or shared SyntaxFacts
  -> Nil-Kill static evidence
  -> Espalier evidence loader

Decomplex::Syntax or shared SyntaxFacts
  -> Espalier source extractor
```

Short term, reuse `Decomplex::Syntax` directly because it already owns the
Tree-sitter parser facade and language profiles. If that becomes too much
cross-gem coupling, extract the reusable parser/fact layer into a small shared
gem or library namespace. The shared layer should still sit below both Nil-Kill
and Espalier.

## Current Coupling

Espalier currently has Ruby-specific assumptions in three places.

`Espalier::AstExtractor` is Prism-backed and extracts Ruby class/module owners,
instance variables, methods, visibility, and delegations from Ruby syntax.

The CLI discovers Ruby files only. A generalized run should discover source
files through the shared Tree-sitter language registry instead of hard-coding
`**/*.rb`.

The reporter and quality-overlap logic have Ruby path and method assumptions,
including report parsing for `.rb` paths and source lookup based on Ruby
`def` lines. A generalized manifest should carry enough file, line, span,
language, and function identity data that the reporter does not need to re-parse
Ruby source to locate methods.

Espalier also consumes Nil-Kill evidence through Ruby-shaped keys:

- `methods[].source.sig`
- `facts.ivar_runtime`
- `facts.ivar_protocols`
- `facts.ivar_param_origins`

Those keys can remain as compatibility aliases for Ruby, but generalized static
evidence needs language-neutral state names and method records.

## Minimum Nil-Kill Work

Nil-Kill needs a static-only evidence path that can run without the Ruby
`Infer` and `SourceIndex` stack.

Recommended entry point:

```ruby
NilKill::TreeSitterEvidence.build(files, root: Dir.pwd)
```

or, if the name should avoid promising a parser implementation:

```ruby
NilKill::StaticEvidence.build(files, root: Dir.pwd)
```

This path should reuse the shared Tree-sitter facts instead of building another
parser facade in Nil-Kill.

The minimum evidence schema should be language-neutral and versioned:

```json
{
  "schema_version": 2,
  "runtime_fields": false,
  "methods": [],
  "facts": {
    "state_types": {},
    "state_protocols": {},
    "state_param_origins": {},
    "signatures": {}
  }
}
```

`methods[]` records should include:

- `owner`
- `name`
- `kind`
- `path`
- `line`
- `language`
- `signature`
- optional `span`
- optional `params`

`facts.state_types` should map stable state identities to inferred or declared
type names when available. For many languages this will be sparse at first.

`facts.state_protocols` should map stable state identities to methods,
operators, or protocol operations called on that state.

`facts.state_param_origins` should map stable state identities to constructor,
initializer, receiver, or function parameters assigned into that state.

`facts.signatures` should preserve normalized signature strings for display and
matching. For languages without easy signatures, function name plus parameter
names is enough.

State identity should be language-neutral:

```text
owner\0state_name
```

Nil-Kill can continue emitting legacy Ruby aliases:

- `facts.ivar_runtime`
- `facts.ivar_protocols`
- `facts.ivar_param_origins`

Espalier should prefer the v2 keys when present and fall back to the legacy keys
for existing Ruby evidence.

## Nil-Kill Language Facts

Nil-Kill only needs to emit facts Espalier can use for static architectural
analysis.

Required facts:

- function and method declarations
- owner identity
- parameter names
- state reads and writes
- state values assigned from parameters
- method/protocol calls made against state fields
- optional declared return or field types where the language exposes them

Language-specific interpretation should stay conservative:

| Language | Minimum owner model | Minimum state model |
|---|---|---|
| Ruby | class/module | instance variables |
| Python | class and module/file owner | `self.x` fields |
| JavaScript | class, object/file/export owner | `this.x` fields and object fields where obvious |
| TypeScript | class, object/file/export owner | `this.x` fields plus declared field types where available |
| Go | receiver type, package/file owner | receiver field reads/writes |
| Rust | `impl` receiver, module/file owner | `self.x` field reads/writes |
| Zig | struct/container, file owner | container fields and obvious `self.x`/receiver field access |

Nil-Kill should skip unavailable facts rather than guessing. For example, Go and
Rust can expose receiver ownership, but global type inference should remain out
of scope.

## Espalier Work

Espalier should replace the Ruby-only Prism extractor with a Tree-sitter-backed
source extractor that consumes the same syntax facts as Nil-Kill.

The extractor should produce the current manifest concepts in language-neutral
form:

- owners
- functions
- state fields
- state reads and writes
- delegations
- visibility when known
- language and file extension metadata
- exact line/span references

The manifest can keep existing Ruby-shaped field names where needed for
compatibility, but the internal model should stop assuming that all state is an
`@ivar`.

Owner resolution should be language-aware:

| Language | Owner rule |
|---|---|
| Ruby | class/module owner |
| Python | class owner, otherwise module/file owner |
| JavaScript | class owner, exported object owner, otherwise file owner |
| TypeScript | class/interface-adjacent implementation owner, exported object owner, otherwise file owner |
| Go | receiver type owner, otherwise package/file owner |
| Rust | `impl` receiver owner, otherwise module/file owner |
| Zig | struct/container owner, otherwise file owner |

Delegation resolution should be conservative. Espalier only needs enough call
evidence to identify architectural collaboration pressure, so unresolved dynamic
calls should stay unresolved instead of being forced into an owner.

The existing `Decomplex::RubyTopology.scan(files)` dependency should be replaced
with a generic topology scan backed by shared call facts. Ruby can keep the old
RubyTopology path until the generic topology reaches parity.

The reporter should stop deriving method lines from source text. Method line,
span, file, and language should come from the manifest or quality-overlap
records. Report parsers for Decomplex, SlopCop, and Boobytrap overlap should
accept any supported source extension, not only `.rb`.

The CLI should discover files via:

```ruby
Decomplex::Syntax.supported_exts(parser: "tree_sitter")
```

or the equivalent shared syntax registry if the parser layer is extracted.

## Shared Syntax Facts Needed

Decomplex already exposes enough Tree-sitter facts for several metrics, but
Espalier and Nil-Kill need a slightly richer fact surface.

Needed additions:

- owner definitions
- function signatures and parameters
- call sites with receiver and message
- state protocol calls
- parameter-to-state assignment facts
- generic topology edges
- language capability flags

The shared layer should preserve stable spans and names so downstream gems do
not need to special-case parser coordinates.

## Compatibility Strategy

Ruby should remain compatible with existing Espalier and Nil-Kill evidence while
the generalized path lands.

Implemented compatibility behavior:

- Ruby now uses the same Tree-sitter-backed structural extractor as the other
  supported languages.
- Load Nil-Kill v2 static evidence when present.
- Fall back to legacy Nil-Kill Ruby evidence keys when v2 keys are absent.
- Preserve current `architecture.yml` fields where practical.
- Add `language` and `span` fields rather than replacing existing `file` and
  `line` fields.
- Keep report section names stable unless a section truly cannot apply outside
  Ruby.

## Implementation Sequence

1. Extend the shared Tree-sitter syntax layer with owner definitions, function
   signatures, call sites, state protocol calls, and param-to-state assignment
   facts.
2. Add `NilKill::StaticEvidence` or `NilKill::TreeSitterEvidence` that emits
   schema v2 static evidence from those facts.
3. Update Espalier's Nil-Kill evidence loader to prefer v2 `state_*` facts and
   fall back to legacy `ivar_*` facts.
4. Replace or wrap `Espalier::AstExtractor` with a Tree-sitter-backed extractor
   that emits the current manifest concepts for all supported languages.
5. Add a generic topology pass and move Espalier off
   `Decomplex::RubyTopology.scan(files)` for non-Ruby files.
6. Generalize CLI file discovery and report overlap parsing to all supported
   extensions.
7. Add fixtures for Ruby, Python, JavaScript, TypeScript, Go, Rust, and Zig.
8. Run Espalier against checked-in `zig/` sources and spot-check that owners,
   state fields, delegations, and quality-overlap rows are plausible.

## Test Plan

Add focused fixture tests for each supported language:

- owner extraction
- method/function extraction
- state read/write extraction
- param-to-state origin extraction
- state protocol extraction
- delegation extraction
- manifest shape
- report generation

Add integration tests that verify:

- Ruby legacy Nil-Kill evidence still loads.
- v2 static evidence loads for non-Ruby files.
- mixed-language runs do not crash.
- unsupported or unavailable facts produce empty evidence, not invented
  evidence.
- report overlap parsing works for every supported extension.

Use `zig/` as an end-to-end smoke test because it is checked in and exercises a
non-Ruby language that already works with Decomplex, SlopCop, and Boobytrap.

## Risks

The largest risk is over-normalizing language semantics too early. Espalier
should accept sparse evidence and rank review candidates from what is known,
rather than pretending every language has Ruby-like classes, ivars, visibility,
and dynamic dispatch.

The second risk is creating two parser facades. Nil-Kill, Espalier, Decomplex,
SlopCop, and Boobytrap should converge on one Tree-sitter fact layer. If
Decomplex is not the long-term home for that layer, the right move is extraction
to a shared syntax-facts library, not reimplementation inside Nil-Kill or
Espalier.

The third risk is breaking existing Ruby reports. Ruby compatibility should be
protected with fixture output tests before disabling the Prism-backed path.
