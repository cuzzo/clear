# MAL Interpreter Bug Notes

This file tracks issues surfaced while wiring `examples/mal` to the upstream
Make-a-Lisp step tests. CLEAR is intended to be memory safe; source-level CLEAR
that leaks under the debug allocator is a language/runtime/compiler bug unless
the program explicitly uses an unsafe/raw escape hatch.

## CLEAR Bugs To Reduce

### `@indirect` recursive-union closure body ownership

The original `Value.Lambda { params: Value[], body: Value @indirect, envId }`
shape was not stable once closures were copied through env maps and returned
from eval. The practical symptom was allocator/double-free style failure around
lambda bodies. The step4 workaround stores lambda metadata in an environment and
re-parses the body text on invocation, which avoids the problematic owned AST
copy path but is not the right long-term representation.

Why this matters: step5 TCO should store and tail-call the parsed body AST. If
`@indirect` recursive union payloads cannot be safely copied/stored in maps, MAL
and similar interpreters need either a compiler/runtime fix or a documented
ownership pattern.

Next step: reduce to a small test that stores a union variant with an
`@indirect` recursive payload inside `HashMap<Value>` or `@pool`, copies it out,
and then lets both containers clean up.

Repro: `transpile-tests/520_mal_indirect_lambda_body_cleanup.clear`

Current status: fixed by marking inline-struct union `@indirect` fields as
heap/runtime-using during annotation, and by deep-copying cleanup-needing union
values read from containers before assigning them into owned locals.

### `COPY` in HashMap key assignment can leak temporary keys

Assignments like `env.vars[COPY name] = value` leaked when used with
`HashMap<Value>`. The generated map `put` path already duplicates string keys, so
the explicit `COPY` allocates an extra temporary key that is not retained by the
map. The step4 fix uses `env.vars[name] = ...` for dynamic keys.

Why this matters: this is an easy ownership trap and may indicate missing
temporary cleanup for `COPY` expressions in special lowered assignment forms.

Next step: reduce to a minimal `HashMap<Int64>` test using `map[COPY key] = 1`
under the debug allocator. Decide whether the fix is compiler cleanup,
diagnostics, or documentation that map keys are borrowed at the source level.

Repro: `transpile-tests/518_mal_hashmap_copy_key_cleanup.clear`

Current status: fixed by hoisting allocating string-map key expressions before
`put`, giving the temporary a visible MIR cleanup path.

### Consumed/stored values can leak when wrapper APIs copy again

The MAL output capture path initially built an owned `Value.Str` and passed it
to `envSet!`, which then copied the `Value` again before storing it in the map.
That source-level pattern leaked the first owned string. The workaround changed
`envSet!` to `TAKES val` and stores the consumed value directly.

Why this matters: even if `TAKES` is the preferred API shape, the borrowed-param
plus internal-copy version must not leak silently in safe CLEAR. The compiler
should either clean the temporary, reject the ownership pattern, or require a
source form that makes the transfer explicit.

Next step: reduce to a minimal function that accepts a borrowed union/string,
stores `COPY val` into a `HashMap`, and is called with a freshly allocated union
payload.

Repro: `transpile-tests/519_mal_borrowed_param_copy_store_cleanup.clear`

Current status: fixed by hoisting cleanup-needing union literal arguments into
owned MIR temporaries when they are passed to borrowed parameters.

## Not Memory-Safety Bugs

- `prn`/`display` output capture: interpreter test harness work, not a language
  bug.
- Replacing exhaustive `MATCH` with `PARTIAL MATCH`: expected current syntax
  requirement for these union matches.
- Switching `--` comments to `#`: source syntax cleanup.
