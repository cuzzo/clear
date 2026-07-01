Nil-Kill action oracle fixtures live here because they are consumed only by
Nil-Kill Ruby and Rust tests.

Each scenario directory contains:

- `input.json`: the minimal serialized state needed by the Rust action builder.
- `output.json`: the expected actions for that state.

Keep scenario names descriptive. Do not add hash-only fixture directories or
raw runtime dumps. If a fixture needs real path strings, use stable repo-relative
fixture paths instead of machine-local temp paths.
