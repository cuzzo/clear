# Separating Autofix Into Auto-type

Nil-kill has two responsibilities that should stay separate:

- Evidence and inference: collect runtime/static facts, infer pressure, rank action candidates, and report.
- Repair: mutate source files, run a verifier, roll back bad edits, and manage language-specific rewrite details.

The second responsibility now belongs to `gems/auto-type`.

## Boundary

Nil-kill owns:

- `collect`, `infer`, `static`, `collect-runtime`, `normalize`, `analyze`, `report`
- action generation in `evidence.json`
- pressure reports for nilability, type ambiguity, fallibility, hidden enums, and downstream architecture consumers

Auto-type owns:

- `apply`
- `review`
- `loop`
- `guarded-autocorrect`
- language/provider-specific rewrite machinery

## Provider Model

Auto-type currently supports Ruby/Sorbet only. The provider boundary is intentionally language-oriented:

- provider decides whether an action is supported
- provider normalizes the action into a rewrite plan
- provider applies the plan against a workspace
- verified-loop orchestration handles snapshot, verifier execution, rollback, and bisection

Future providers can support Python, JavaScript/TypeScript, Lua, or other languages by implementing those hooks. Nil-kill should not grow language-specific repair logic again.

## Action Contract

The v0.1 input is Nil-kill's existing action shape inside `evidence.json`:

```json
{
  "kind": "fix_sig_param",
  "confidence": "high",
  "path": "src/example.rb",
  "line": 12,
  "message": "param user has concrete evidence",
  "data": { "name": "user", "type": "User" }
}
```

A future `auto-type-plan/v1` wrapper can generalize this for other analyzers, but the immediate extraction should not block on a schema migration. The important rule is ownership: analyzers may emit actions; Auto-type mutates code.

## Safety Rules

- Review-grade actions must go through `auto-type loop` with a behavioral verifier.
- Raw bulk application of review actions remains debug-only.
- Hidden enum automated repair is intentionally out of scope until report quality is proven.
- Nil-kill may use Auto-type internally for temporary Sorbet prevalidation when available, but that is a validation implementation detail, not a public repair API.
