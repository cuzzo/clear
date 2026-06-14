# Auto-type

Auto-type is the code-repair half of the Nil-kill workflow.

Nil-kill collects evidence, infers pressure, and emits action plans. Auto-type consumes those actions and performs verified source rewrites. Keeping those responsibilities separate lets Nil-kill stay an analyzer and lets Auto-type grow into a general repair engine.

## Status

Auto-type currently supports Ruby/Sorbet rewrites:

- signature insertion and narrowing
- `T.let` insertion and narrowing
- dead nil-check/safe-navigation cleanup
- nil-default rewrites
- hash-record promotion helpers
- verified loop application with rollback/bisection
- guarded Sorbet autocorrect cleanup

The provider API is intentionally language-oriented. Ruby is the first provider, but the CLI and plan boundary are designed so Python, JavaScript/TypeScript, Lua, or other languages can add providers later without changing Nil-kill's analyzer.

## Usage

Generate Nil-kill evidence first:

```sh
bundle exec nil-kill collect -- <test-or-replay-command>
bundle exec nil-kill infer
```

Then apply high-confidence actions:

```sh
bundle exec auto-type apply --dry-run
bundle exec auto-type apply
```

For review actions, use the verified loop with a real behavioral test command:

```sh
bundle exec auto-type loop --signature-backflow --return-backflow -- bundle exec prspec
```

`auto-type loop` snapshots touched files, applies candidate actions, runs the verifier, and rolls back or bisects failing batches. Review actions should not be applied raw unless you are debugging with `NIL_KILL_UNSAFE_APPLY_ALL=1`.
