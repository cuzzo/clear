# CLEAR VM (Obsolete)

This directory contains the original bytecode VM for the toy implementation of CLEAR. It is **not used** by the current compiler, which targets Zig directly.

The VM is planned to be revived to enable rapid profile-guided development — running code in the VM is faster than a full recompile cycle, making it useful for interactive development, REPL experimentation, and collecting runtime profiles that feed back into the compiler's optimization passes.

## Contents

- `compiler/` — Ruby bytecode compiler (lexer → parser → bytecode)
- `compiler_spec/` — RSpec tests for the bytecode compiler
- `examples/` — Sample `.cht` programs written for the VM
