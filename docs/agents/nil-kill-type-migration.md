# nil-kill: typed: strict Migration

## Task

Promote every file in `src/` from `# typed: true` to `# typed: strict` (Sorbet strict mode).
After each batch, verify `bundle exec srb tc` (zero errors) and `bundle exec prspec spec/`
(zero failures), then commit.

This is Track C from the broader nil-kill plan (`/home/yahn/.claude/plans/majestic-drifting-raven.md`).

---

## Tools Used

- `bundle exec srb tc` - Sorbet type checker; the authoritative error list
- `bundle exec prspec spec/` - parallel RSpec suite; must stay at zero failures after every batch
- `sed -i 's/# typed: true/# typed: strict/'` - batch flip files
- Bulk Ruby one-liner to replace bare generics in sig lines:
  ```ruby
  ruby -i -e '
  content = $stdin.read
  lines = content.lines
  lines.map! do |line|
    if line =~ /^\s*sig\s*\{/
      line = line.gsub(/(?<![:\[T])(?<!T::)(?<!\w)Array(?!\[|\w)/, "T::Array[T.untyped]")
      line = line.gsub(/(?<![:\[T])(?<!T::)(?<!\w)Hash(?!\[|\w)/,  "T::Hash[T.untyped, T.untyped]")
      line = line.gsub(/(?<![:\[T])(?<!T::)(?<!\w)Set(?!\[|\w)/,   "T::Set[T.untyped]")
    end
    line
  end
  print lines.join
  ' < FILE > /tmp/fixed.rb && mv /tmp/fixed.rb FILE
  ```
- Edit tool for individual targeted fixes (constants, ivar T.let declarations, missing sigs)

---

## Recurring Fix Patterns

| Error type | Fix |
|---|---|
| Bare `Array`/`Hash`/`Set`/`Class` in sig lines | Bulk script above |
| Bare `T::Array[Hash]` or `T::Hash[Array, ...]` (inside brackets) | Second-pass `gsub` |
| `Constants must have type annotations` | `CONST = T.let(value, Type)` |
| `instance variable must be declared using T.let` (assignment in init) | `@ivar = T.let(expr, T.untyped)` |
| `Use of undeclared variable @ivar` (mixin module method) | `@ivar = T.let(@ivar, T.untyped)` at method top |
| Missing `sig` on method | Add `sig { params(...).returns(...) }` |
| `Data.define(:a, :b)` accessor sigs | Add `do...end` block with `extend T::Sig` + sigs |
| `T::Hash[Symbol, Integer]` indexing returns nilable | Wrap with `T.must(...)` |

---

## Files Migrated (typed: strict)

76 files are now at `# typed: strict`. The migration happened across ~10 commit batches
on the `nil-kill` branch, starting from `ec05c645` (scope, lexer, symbol_entry) through
the current in-progress batch. Recent commits:

| Commit | Files |
|---|---|
| `a1c28bc9` | function_signature, auto_inference, capabilities, test_lowering, recursive_splitter |
| `ac968765` | fixable_helpers, fsm_wrapper_emitter, promotion_plan, segments |
| `60c8f13a` | 6 more files |
| `247a5c11` | fsm_transform, escape_analysis, with_match_check, reentrance, fsm_lowering, liveness |
| earlier | all lsp/, tools/, mir/ leaf files, ast/ leaf files |

**Not yet committed (in progress this session):**
- `src/annotator-helpers/effects.rb` - fixed, 0 errors
- `src/mir/mir_pass.rb` - fixed, 0 errors
- `src/annotator-helpers/lock_helper.rb` - partially fixed (residual bare `Hash` inside brackets + ivar T.let declarations remain)
- `src/mir/control_flow.rb` - flipped, not yet fixed (~54 errors)

---

## Remaining at typed: true (7 files)

These are the hardest files - large, many ivars, many complex types:

| File | Est. errors | Notes |
|---|---|---|
| `src/annotator-helpers/lock_helper.rb` | ~40 | In progress this session; residual Hash-in-brackets + mixin ivars |
| `src/mir/control_flow.rb` | ~54 | Flipped this session; not yet fixed |
| `src/annotator.rb` | ~96 | Largest mixin module; many T.bind rescue nil patterns |
| `src/backends/pipeline_host.rb` | ~100 | |
| `src/backends/pipeline_generator.rb` | ~122 | |
| `src/mir/mir_lowering.rb` | ~190 | |
| `src/ast/type.rb` | ~207 | Central type class; very wide |
| `src/ast/parser.rb` | ~51 | |
| `src/ast/ast.rb` | ~363 | Largest file; many struct/node classes |

---

## Track D (Planned, Not Yet Started)

The nil-kill plan referenced a "Track D" task: after all files reach `typed: strict`, add
CI enforcement so no file can regress:

1. Add a `.typed-strict-registry` file checked into git listing every file at strict level.
2. Add to CI (or a git pre-push hook):
   ```bash
   # No file may downgrade below typed: true
   grep -rn "# typed: false" src/ && exit 1
   # No file may downgrade from strict once promoted
   # (tracked via .typed-strict-registry)
   ```
3. Any PR that removes a file from the registry or downgrades its header fails CI.

This is Track C3 from the plan (`typed-strict-registry` + CI enforcement gate).

---

## Verification Protocol (per batch)

```bash
bundle exec srb tc                 # must be 0 errors
bundle exec prspec spec/           # must be 0 failures
# then commit
git add src/...
git commit -m "chore(nil-kill): promote N files to typed: strict"
```
