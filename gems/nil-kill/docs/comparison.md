# Comparison to Other Type Inference Systems that Already Exist

## On Nilability:

| Ecosystem | Tool | What it can do | Does it identify “this return/instantiation is causing nilability”? |
|---|---|---|---|
| Ruby | Sorbet | Tracks T.nilable, flow-sensitive narrowing, reports nil-use errors. | Mostly no. It tells you where nilability hurts, not usually where it originated. |
| Ruby | RBS / Steep | Static checking against signatures/RBS | Mostly no. Same issue: enforcement/checking, not pressure attribution. |
| Python | mypy | Strong Optional/None checking, return/Any diagnostics. | Partial. It flags incompatible Optional flows, but does not build a “nil pressure graph.” |
| Python | Pyright / Pylance | Very good optional diagnostics such as optional member access. | Partial. Better local diagnostics, but still mostly points to use-sites. |
| Python | MonkeyType | Runtime traces argument and return types; can generate annotations. | Partial. It can reveal “this function returned None in practice,” but not necessarily rank pressure through the codebase. |
| JS/TS | TypeScript | Great control-flow narrowing and union/undefined/null diagnostics | Partial. It shows where unions hurt, not generally which producer polluted the type. |
| Lua | Luau | Flow typing, table shapes, nil tracking | Partial. Similar: good checking, limited source-pressure attribution. |

> NOTE: Rubocop can flag when you use `nil` in place of `[]` or `{}` or `""`
> This is one of the easiest solutions to resolve unintended optionality / nilability in the type system.
> Rubocop does not, however, surface which particular `nil`s are the most problematic to help you prioritize your time.

## On Type Inference:

`*` means the ecosystem has partial support when the shape is declared or locally obvious; it does not mean the tool recovers latent record schemas across an untyped codebase.

| # | System | Ruby | Other |
|---|---|---|---|
| 1 | Local Static Type Inference | Sorbet, RBS/Steep | Pyright, mypy, TypeScript, Flow, Luau |
| 2 | Flow-Sensitive / Control-Flow Typing | Sorbet | Pyright, mypy, TypeScript, Flow, Luau |
| 3 | Structural / Shape Typing | Declared only: Sorbet, RBS/Steep | TypeScript, Flow, Pyright (Protocols), mypy (Protocols), Luau |
| 4 | HashMap / Dict / Table Shape Recovery | Declared only: Sorbet, RBS/Steep | TypeScript, Pyright (TypedDict), mypy (TypedDict), Luau |
| 5 | Runtime-Assisted Type Collection | *Sorbet | MonkeyType, Pyre Infer, runtime tracing systems |
| 6 | Runtime Structural Shape Recovery | nil-kill | *MonkeyType, *Pydantic ecosystem, *TypeScript tooling |
| 7 | Automatic Interface Synthesis | N/A | *TypeScript (anonymous structural inference), *Luau |
| 8 | Ambiguity Surfacing UX | N/A | N/A |
| 9 | Probabilistic / Observational Typing | N/A | *MonkeyType |
| 10 | Latent Schema Recovery | nil-kill | *TypeScript, *Pyright, *Luau |

### On Void:

Languages like Ruby with *implicit return* have a particular problem:

```ruby
def foo():
  doX()
```

Is this function supposed to return the value of `doX()`, or is that merely the last line, never expected to be used?

Nil-kill surfaces this problem as evidence and action candidates. Auto-type owns verified source rewriting.

### On Fallibility:

We are investingating the same *nil pressure* for downstream fallibility: mark falible function with `!!`, and call them accordingly, otherwise, nil-kill will show you which sources of failures have the most downstream / fan-out pressure throughout your codebase.

> NOTE: This is not yet available and still being planned.
