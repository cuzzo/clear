# Runner patches

These patches are intentionally separate from Test Miser's adapters. Test Miser
only reads completed mutation data; it does not own or run a language's mutation
engine.

| Patch | Based on | Purpose | Upstream disposition |
|---|---|---|---|
| `mutmut-run-to-complete.patch` | mutmut `32f0b426` | Adds `--test-miser-output`, disables pytest fail-fast for mutant trials, inventories tests, and emits complete native facts. | Propose upstream. |
| `gremlins-test-miser.patch` | Gremlins `b48a4aad` | Adds `--test-miser-output`, removes `-failfast`, consumes `go test -json`, and emits native facts. | Propose upstream. |
| `infection-run-to-complete.patch` | Infection `4dfdc7f9` | Adds opt-in run-to-completion and records every PHPUnit failure in MTE. | Propose upstream after replacing the proof-of-concept environment toggle with a CLI/config option. |
| `muter-linux-attribution-fixes.patch` | Muter `99624ecf` | Fixes Linux compilation, mutation environment propagation, and re-parsed SwiftSyntax mapping. Existing per-mutant logs then contain complete XCTest failures. | Propose upstream; all three are general correctness fixes. |

Zig is maintained in this repository, so its `--test-miser` implementation is
applied directly to `gems/zig-mutants`. JavaScript, TypeScript, C#, Java, and
Kotlin need configuration rather than runner patches. C/C++ uses Mull's existing
SQLite output plus a GoogleTest adapter, so no Mull fork is required.
