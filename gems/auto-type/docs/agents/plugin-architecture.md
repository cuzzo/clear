# Auto-Type Plugin Architecture

Auto-type should grow multi-language rewrite support without turning Nil-kill back into a code mutator and without making unsupported languages look safer than they are.

## Current Assessment

The original direction was right: Auto-type needs provider dispatch so Python, TypeScript, Lua, and Ruby can use different rewrite machinery.

The risky parts of the earlier design were:

- `apply(lines, action)` is too weak as a provider contract. It cannot represent multi-file edits, digest checks, dry-run behavior, rollback, formatter needs, or diagnostics.
- A generic LLM fallback is not safe for automatic source mutation. LLMs may be useful for advisory plan generation later, but not as an implicit provider for unsupported languages.
- Template injection without CST/span validation is too fragile for Python, TypeScript, or Lua.
- Nil-kill evidence priority and Auto-type rewrite support are separate concepts. A Python action can be high-evidence even when Auto-type cannot rewrite it yet.

## Target Boundary

Nil-kill owns:

- evidence collection
- inference
- pressure/action ranking
- report generation

Auto-type owns:

- language/provider dispatch
- rewrite planning
- digest/span-checked file edits
- snapshot/restore
- verifier execution and bisection

Nil-kill may be an input adapter for Auto-type, but provider code should not rely on Nil-kill as the architectural source of truth.

## Core Types

### `AutoType::Workspace`

Workspace owns filesystem interaction:

- root-relative path resolution
- file reads and writes
- snapshots and restore
- digest calculation
- applying non-overlapping text edits

Providers should plan edits. The workspace should perform mutation.

### `AutoType::TextEdit`

Text edits are byte-span replacements:

- path
- start offset
- end offset
- replacement text

This keeps provider output explicit and verifier-friendly.

### `AutoType::RewritePlan`

A rewrite plan is the unit Auto-type can execute:

- provider/language
- support status
- diagnostics
- text edits
- legacy Ruby actions during migration
- risk level
- whether a verifier is required

Unsupported languages should return an unsupported plan with diagnostics, not a fake low-priority action.

### `AutoType::Providers::Base`

Providers should implement:

- `language`
- `capabilities`
- `supports?(action)`
- `plan(action, workspace:)`

Providers should not directly mutate project files.

### `AutoType::Providers::Registry`

The registry should be explicit and boring:

- register Ruby
- return `NullProvider` for unsupported languages
- preserve unsupported diagnostics

This is enough to make future Python/TS/Lua support additive.

## Recommended Implementation Order

1. Add `Workspace`, `TextEdit`, `RewritePlan`, `Providers::Base`, and `Providers::Registry`.
2. Route existing Ruby `apply` through provider planning while keeping the current Ruby rewrite implementation behavior-identical.
3. Isolate Nil-kill constants and evidence reads behind a small adapter surface.
4. Move Ruby action families from the legacy applier into `Providers::Ruby` one at a time.
5. Add future providers only when they can produce explicit plans:
   - Python: start with Python `ast` span extraction for annotation-only fixes; move to LibCST or a typed CST layer before body rewrites/import edits.
   - TypeScript: TypeScript compiler API or ts-morph.
   - Lua: Tree-sitter edits only when span validation is reliable.

## Python First Slice

The first Python provider should intentionally support only `add_nullability` and should write modern PEP 604 annotations:

```python
def name(fallback: str) -> str:
    ...
```

becomes:

```python
def name(fallback: str | None) -> str:
    ...
```

The provider should:

- use Python `ast` spans to locate params, returns, and annotated fields
- validate the located annotation against Nil-kill's `declared_type`
- emit `TextEdit` plans only
- skip already-nullable, string-literal, missing, ambiguous, or changed annotations with diagnostics

It should not introduce `typing.Optional`, manage imports, infer concrete types, or rewrite function bodies. Those require stronger CST/typechecker integration and should come later.

## What Not To Do

- Do not add `GenericLLMProvider` as an automatic fallback.
- Do not mutate files from providers.
- Do not template-inject code into unsupported languages without CST/span validation.
- Do not downgrade non-Ruby evidence priority just because Auto-type cannot rewrite it.
- Do not big-bang move the entire Ruby applier; preserve behavior while moving action families in small reviewed steps.

## First Slice Acceptance

- `auto-type apply` still works for Ruby actions.
- Unsupported language actions are skipped with diagnostics.
- Ruby provider planning returns a `RewritePlan`.
- Core has a tested workspace/text-edit path available for future providers.
- Python `add_nullability` actions produce PEP 604 `TextEdit` plans for unambiguous existing annotations.
- Nil-kill docs and reports continue to distinguish evidence priority from rewrite support.
