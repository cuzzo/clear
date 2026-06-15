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

Auto-type also has a narrow Python provider for `add_nullability` actions on existing annotations. It writes modern `T | None` annotations for unambiguous params, returns, and annotated fields. It intentionally does not manage `typing.Optional` imports or rewrite Python function bodies yet.

The provider API is intentionally language-oriented. Ruby is the mature provider, and the CLI and plan boundary are designed so Python, JavaScript/TypeScript, Lua, or other languages can add more actions without changing Nil-kill's analyzer.

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

> [!WARNING]
> The verifier command for `auto-type loop` must include your host
> project's behavioral test suite. Running with `srb tc` alone is not
> enough: Sorbet typecheck cannot see runtime call paths that flow
> through `||` fallthrough, `T.unsafe`, or dynamic dispatch. A narrowing
> derived from static evidence can be accepted by Sorbet while still
> violating the runtime contract on those paths. If the loop verifier
> does not exercise the code, the fix can pass typecheck and still break
> callers.

`auto-type loop` snapshots touched files, applies candidate actions, runs the verifier, and rolls back or bisects failing batches. Review actions should not be applied raw unless you are debugging with `NIL_KILL_UNSAFE_APPLY_ALL=1`.
