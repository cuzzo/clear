<!-- GENERATED FILE. Source: tools/stdlib_docs.rb. -->

# Testing And Diagnostics

> [!WARNING]
> This is the current **planned** CLEAR stdlib design. Full stdlib
> implementation and stabilization are not planned until v0.3. Treat these
> pages as design direction, not as a compatibility promise.


Status: `prototype`, `self-host required`.

`pkg:testing` exists today as a package-resolution smoke test. The real
package should support compiler and stdlib oracle testing before broad
self-host work depends on it.

## Planned Testing API

| API | Status | Notes |
| --- | --- | --- |
| `ASSERT` | `planned` | Core assertion. |
| `assertEqual(expected, actual)` | `self-host required` | Equality with useful diffs. |
| `assertClose(expected, actual, tolerance)` | `planned` | Approximate float assertions. |
| `expectError` | `self-host required` | Compile/runtime error assertions. |
| Fixtures | `self-host required` | Test data files and temp dirs. |
| Golden/oracle helpers | `self-host required` | Compiler output and transpiler tests. |
| Test filtering | `planned` | CLI runner support. |
| Leak/profile hooks | `planned` | Runtime integration. |

```ruby clear illustrative
TEST "translates simple pipeline" ->
    clear = rubyToClear("list.map { |x| x + 1 }");
    assertEqual("list |> MAP { (_ + 1) };", clear);
END
```

## Diagnostics

Diagnostics should share formatting, source-span, and diff helpers with
tests. Compiler output needs stable ordering and deterministic rendering.

## Decisions

- Test declaration syntax: compiler syntax, library calls, or mixed.
- How expected compiler errors are represented.
- Golden file update workflow.
- How much leak/profile machinery belongs in `pkg:testing`.
