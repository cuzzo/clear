# Puck V6

V6 branches from V5 and adds the minimum needed for an Oberon-shaped module:

- `MODULE name;`
- `BEGIN`
- final `END.` (the trailing `.` is the only thing distinguishing module end from `END;` for blocks)
- `AstNode(:Module, name, { declarations:, body: })` — the parser separates the declaration block from the executable body
- the demo's "declaration block" is the `PROCEDURE` definition; later versions can put more kinds of declarations there

The README focuses on the parser/compiler boundary because `MODULE` adds source structure, not a new VM opcode. `vm.rb` is byte-identical to V5.

The module's `name` is parsed and stored on the AST node, but V6's compiler doesn't reference it — it's parsed-but-unused. A later version could use it for namespacing or as a bytecode label.
