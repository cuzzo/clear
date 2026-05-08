# Driving the String/Symbol normalization with Sorbet

## What's installed

- `gem 'sorbet'` — static checker (`bundle exec srb tc`)
- `gem 'sorbet-runtime'` — `T::Sig` API for inline signatures
- `gem 'tapioca'` — RBI generation (currently broken on Ruby 3.2 + tapioca 0.19; init crashes in `coerce_and_check_module_types`. Workaround: hand-write minimal RBI stubs in `sorbet/rbi/clear-stubs.rbi` for now.)
- `sorbet/config` — points Sorbet at `.` and ignores `vendor/`, `zig*/`, `spec/`, `transpile-tests/`, `examples/`, `benchmarks/`, `tmp/`, `docs/`.
- `sorbet/rbi/clear-stubs.rbi` — hand-written stubs for project classes that Sorbet's name resolver cannot find at `# typed: false`.

Status: **`bundle exec srb tc` reports no errors** at default `# typed: false` across all of `src/`.

## The String/Symbol problem today

67 sites in `src/` mix `String` and `Symbol` for what should be one type. Examples:

```ruby
# src/backends/importer.rb:93
struct_schemas[stmt.name.to_sym] = stmt.fields
```

`stmt.name` is a `String` here but the schema map uses `Symbol` keys. Every read/write of the schema map needs `.to_sym` or `.to_s` glue. Two existing 2-arm checks make the polymorphism explicit:

```ruby
# src/mir/fsm_transform/liveness.rb:232
return if node.is_a?(Symbol) || node.is_a?(String) || ...

# src/backends/pipeline_host.rb:159
return false if node.is_a?(String) || node.is_a?(Symbol) || ...
```

## How Sorbet drives the fix

The cycle for one method:

1. **Pick a method** that currently accepts either type. Add `# typed: true` to the file.

2. **Declare the truth**:
   ```ruby
   sig { params(name: T.any(String, Symbol)).returns(T.untyped) }
   def lookup_struct(name)
     @struct_schemas[name.to_sym]
   end
   ```
   `srb tc` should still pass — this just makes the union explicit.

3. **Pick the target type** (project rule: `Symbol` for identifiers, `String` for user-facing text and paths). Tighten the sig:
   ```ruby
   sig { params(name: Symbol).returns(T.untyped) }
   def lookup_struct(name)
     @struct_schemas[name]   # ← drop the .to_sym, it's already a Symbol now
   end
   ```

4. **Run `bundle exec srb tc`**. Sorbet flags every call site that still passes a `String`:
   ```
   src/some/caller.rb:42: Expected `Symbol` but found `String("foo")` for argument `name`
       lookup_struct("foo")
                    ^^^^^^
   ```

5. **Fix each call site** — either upstream (so the caller produces a `Symbol`) or with an explicit `.to_sym` at the boundary. The end state is one normalised type all the way through.

6. **Repeat** for the next method until the type signature unions across the codebase converge.

The win vs. grep: Sorbet finds **every** caller, including dynamically-dispatched ones the compiler can resolve, in one pass. The dataflow becomes a worklist instead of a hunt.

## Per-file rollout protocol

A file's typed level moves through three states as the cleanup work lands:

| State | Meaning | Sorbet enforcement |
|---|---|---|
| (no comment, default `# typed: false`) | File has not been touched yet | Name resolution only; Sorbet ignores sigs and bodies |
| `# typed: true` | Sigs are checked; bodies use Sorbet inference | Catches type mismatches in sigged methods |
| `# typed: strict` | Every method has a sig; every constant has a type | Self-host-ready gate |

The TODO.md "Self-host preparation" P1 task #10 tracks the rollout. The per-file gate (task #20) requires `# typed: strict` plus zero `is_a?(Hash)`, `respond_to?`, and unguarded `.nil?` checks.

## Useful one-liners

```bash
# Run the static checker
bundle exec srb tc

# Run on one file (still type-checks the whole project, but useful for focus)
bundle exec srb tc src/backends/importer.rb

# Auto-generate sigs from runtime observation (after tapioca is fixed)
# bundle exec tapioca dsl --only=ActiveSupport::TaggedLogging::Formatter

# Suggest types based on usage
bundle exec srb suggest-typed
```

## Known issues

- **tapioca 0.19 + Ruby 3.2**: `tapioca init` crashes with `Invalid value for type constraint. Got a NilClass.` This blocks auto-RBI generation for our gems. Until upstream fix lands, hand-write minimal stubs in `sorbet/rbi/clear-stubs.rbi`. The bigger Sorbet workflow is not affected.
- **Default-typed name resolution**: at `# typed: false`, Sorbet still tries to resolve constant references and may suggest unrelated stdlib names (e.g., `Token` → `Socket`). Stubs in `sorbet/rbi/clear-stubs.rbi` silence these. Generated RBI files would too.
