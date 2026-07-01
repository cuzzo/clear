# Ruby-to-CLEAR Work Unlocked By Value Blocks And `pkg:fs`

Date: 2026-06-29.

This spec lists the ruby-to-clear gem work that is now practical because CLEAR
can parse and lower source value blocks:

```clear
items |> SELECT { tmp = _ + 1_i64; tmp * 2_i64 }
```

and because ruby-to-clear can emit package requirements plus fallible calls:

```clear
REQUIRE "pkg:fs"

FN read_names(path: String) RETURNS !String[] ->
  RETURN (readLines(path) OR RAISE) |> SELECT _.trim();
END
```

The goal is still efficient migration output. The gem should translate exact
static Ruby shapes into direct CLEAR and emit localized TODOs for the rest. It
should not introduce a Ruby compatibility runtime or decide new CLEAR language,
stdlib, namespace, class, module, or trait semantics.

## New Capabilities To Exploit

### Multi-Statement Value Blocks

The transpiler can now emit a block body where earlier versions had to reject
or flatten the entire surrounding call:

```ruby
items.map do |item|
  normalized = item.strip
  normalized.upcase
end
```

```clear
items |> SELECT {
  normalized = _.trim();
  normalized.upper()
}
```

This unlocks safe lowering for enumerable blocks whose Ruby value is the last
expression in the block. It does not unlock nonlocal Ruby block flow such as
`return`, `break`, `yield`, `super`, or rescue/ensure semantics.

### Fallible Package Calls

The transpiler can now require a package and mark the enclosing function
fallible when a Ruby stdlib call can raise:

```ruby
def read(path)
  File.readlines(path).map { |line| line.strip }
end
```

```clear
REQUIRE "pkg:fs"

FN read(path: Auto) RETURNS !Auto ->
  RETURN (readLines(path) OR RAISE) |> SELECT _.trim();
END
```

This makes fs/path/stdin-style mappings useful without hiding errors or
inventing Ruby exception compatibility.

## Implementation Queue

### 1. Replace String-Only Block Rendering With `BlockLowering`

Status: partially implemented in `MethodRegistry.render_block_value`.

Work:

- Add a small typed block result object inside the gem, not just a rendered
  string.
- Capture block parameter names, generated CLEAR parameter aliases, rendered
  prefix statements, rendered result expression, and unsafe-node diagnostics.
- Preserve source location for every rejected block so unsupported output is a
  one-line TODO inside the surrounding translation.
- Reuse it from every registry handler instead of duplicating block checks.

Acceptance:

- Existing `map`, `select`, `reject`, `filter_map`, `flat_map`, `sort_by`,
  `find`, `any?`, `all?`, and `reduce` handlers call one common block lowering
  path.
- Multi-statement happy paths have oracle tests.
- Sad paths cover destructured params, block splats, `return`, `break`, `next`,
  `yield`, `super`, `rescue`, and `ensure`.

Why this is now unlocked:

- CLEAR value blocks give the gem a direct target for multi-statement blocks
  with implicit final expression values.

### 2. Expand Enumerable Pipeline Handlers

Status: expression and some multi-statement forms are supported.

Work:

- Ensure these handlers support single-expression and multi-statement blocks:
  `map`, `map!`, `select`, `reject`, `filter_map`, `flat_map`, `sort_by`,
  `sum`, `find`, `any?`, `all?`, and simple `reduce`.
- Add handler-local rewrites for receiver transforms:
  - `reverse_each { ... }` -> `receiver.reverse() |> EACH { ... }`
  - `each_key { |k| ... }` -> `receiver.keys() |> EACH { ... }`
  - `each_value { |v| ... }` -> `receiver.values() |> EACH { ... }`
  - `each_pair { |k, v| ... }` -> TODO until tuple/pair binding shape is
    explicit.
- For `each`, emit side-effect `EACH { ... }` and allow statement-only block
  bodies.
- For value-producing stages, reject blocks whose final statement is not a
  usable expression.

Acceptance:

- Add oracle tests for happy-path and sad-path Ruby snippets for each handler.
- Add CLEAR compile smoke tests for generated pipeline output.
- The audit tool reports lower block TODO counts for top callees without
  increasing broad unsupported regions.

Why this is now unlocked:

- `map`/`select`/`sort_by` no longer have to collapse when the block needs a
  temporary local before the final value.

### 3. Normalize Fallible Stdlib Mapping Around `pkg:fs`

Status: `File.read`, `File.readlines`, `File.foreach`, `File.write`,
`File.binwrite`, and `File.size` can emit `REQUIRE "pkg:fs"` and `OR RAISE`.

Work:

- Move remaining fs-like mappings from legacy helper names to package calls
  once the CLEAR stdlib name is approved:
  - `File.exist?`, `File.exists?`
  - `File.file?`
  - `File.directory?` / `Dir.exist?`
  - `File.delete`
  - `File.mtime`
  - `File.readlink`
  - `File.symlink`
  - `File.symlink?`
- Keep path-only transforms separate if they belong in `pkg:path`:
  - `File.join`
  - `File.expand_path`
  - `File.basename`
  - `File.dirname`
  - `Dir.glob`
- Mark only genuinely fallible functions as `RETURNS !T`.
- Wrap fallible pipeline sources in parentheses before adding pipeline stages.

Acceptance:

- Every fallible fs mapping emits one `REQUIRE "pkg:fs"` and marks the enclosing
  function fallible.
- Nonfallible predicates and pure path helpers do not force `!T`.
- The gem has paired tests for top-level expression output and function-body
  fallibility.

Why this is now unlocked:

- The package-require/fallibility path exists, so stdlib mappings no longer
  need placeholder helper names that hide error behavior.

### 4. Add Receiver-Aware Call Shape Support For Pipeline Sources

Status: registry lookup has receiver kind/name, but it is still mostly string
  translation.

Work:

- Track enough local shape information to distinguish arrays, hashes, sets,
  strings, files/path values, and unknown receivers.
- Prefer handler-specific exact lowerings over generic method-call output.
- Add receiver-aware translations for high-frequency calls:
  - collection: `empty?`, `length`, `size`, `include?`
  - string: `strip`, `split`, `start_with?`, `end_with?`, `delete_prefix`
  - nil/type checks: `nil?`, `is_a?`, `respond_to?`
- For `is_a?` and `respond_to?`, prefer deleting them through static type
  evidence. Emit comptime/metaprogramming TODOs only when they survive after
  static lowering.

Acceptance:

- A call lowering can say "known array length" or "known string length" without
  requiring a Ruby runtime helper.
- Ambiguous overloaded names produce localized TODOs, not confident wrong code.
- Tests include same method name on different receiver shapes.

Why this is now unlocked:

- Pipeline lowering quality now depends more on receiver shape than on block
  syntax. The value-block support removes a major syntax blocker, exposing
  overloaded call names as the next quality bottleneck.

### 5. Strengthen Function Fallibility Propagation

Status: a fallible registry call can mark the current function fallible.

Work:

- Track fallibility through nested translated blocks and helper-generated code.
- Keep top-level expression output legal by emitting `OR RAISE` only where
  CLEAR accepts it.
- Ensure Sorbet `sig` return extraction and generated `RETURNS !T` do not fight
  each other.
- Add sad-path tests for fallible calls in unsupported method bodies, class
  bodies, and nested blocks.

Acceptance:

- Functions with any translated fallible fs call emit exactly one fallible
  return type.
- Functions without fallible calls remain nonfallible.
- Unsupported fallible shapes produce TODO comments instead of partially
  fallible wrong output.

Why this is now unlocked:

- Fs mappings now need reliable propagation, otherwise generated output will
  compile only in expression contexts and fail inside real methods.

### 6. Improve Audit Guidance For New Capabilities

Status: audit reports node, call, stdlib, and block pressure.

Work:

- Add a "now-unlocked" audit section that separates:
  - block TODOs that value blocks can handle now,
  - block TODOs blocked by nonlocal Ruby control flow,
  - fs/path calls that can be mapped once a stdlib name exists,
  - receiver-shape calls that need local type evidence.
- Include sample snippets for each bucket.
- Add a flag to focus on changed files or a subtree, for example:

```text
ruby gems/ruby-to-clear/exe/ruby-to-clear-audit --glob 'src/mir/**/*.rb' --unlocked
```

Acceptance:

- The tool can rank the next gem-only handler by expected reclaimed LoC.
- The report tells whether the blocker is block lowering, stdlib mapping,
  receiver shape, keyword args, or an unavoidable Ruby semantic.

Why this is now unlocked:

- The audit can stop treating multi-statement enumerable blocks as a compiler
  prerequisite and can identify them as implementable gem work.

## Tests To Add By Category

### Oracle Translation Tests

Primary coverage should be in ruby-to-clear oracle tests that compare Ruby
input to exact CLEAR output:

- multi-statement `map`, `select`, `reject`, `filter_map`, `flat_map`,
  `sort_by`, `sum`, and `find`;
- `File.readlines(...).map { ... }` and `File.foreach(...) { ... }`;
- fallible fs calls inside methods with Sorbet signatures;
- receiver-aware overloaded calls on arrays, strings, hashes, and unknowns.

### Sad-Path Transpiler Tests

Each newly accepted handler needs paired rejection cases:

- destructured block parameters;
- keyword/block/rest params inside blocks;
- nonlocal `return`, `break`, `yield`, `super`;
- `next` where the target pipeline stage cannot represent it exactly;
- fallible calls in contexts where `OR RAISE` cannot be emitted correctly;
- unknown receiver shapes for overloaded methods.

### CLEAR Compile Smoke Tests

For generated output that uses source value blocks, add compile smoke tests so
the gem cannot emit syntax that the CLEAR compiler rejects:

- value block with a local bind and final expression;
- fallible `readLines(path) OR RAISE` piped into `SELECT`;
- `ORDER_BY { key = ...; key }`;
- `EACH { ... }` side-effect block.

## Non-Goals

- Do not emulate Ruby enumerators when a block is absent.
- Do not support arbitrary `&block` forwarding yet.
- Do not implement Ruby exception semantics; use CLEAR `!T` and `OR RAISE`.
- Do not invent traits/interfaces or dynamic reflection to support
  `respond_to?`/`is_a?`.
- Do not decide whether modules/classes become namespaces; preserve structure
  and emit TODOs where needed.

## Suggested Commit Order

1. Add `BlockLowering` result object and migrate existing pipeline handlers.
2. Expand multi-statement handlers for `map`, `select`, `reject`,
   `filter_map`, `flat_map`, `sort_by`, and `find`.
3. Add side-effect/receiver-transform handlers for `each`, `reverse_each`,
   `each_key`, and `each_value`.
4. Normalize remaining `File`/`Dir` mappings to package-aware fallible helpers.
5. Add local receiver-shape tracking for overloaded string/collection calls.
6. Extend the audit tool with "now-unlocked" roadmap buckets.

Each commit should include oracle tests, sad-path tests, and at least one CLEAR
compile smoke test when generated source value blocks are involved.
