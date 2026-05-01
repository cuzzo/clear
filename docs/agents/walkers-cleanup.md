# Walker Cleanup Notes

## Problem

The AST/MIR traversal logic is currently spread across multiple hand-written
walkers. The main examples are in `src/ast/ast.rb`:

- `AST.walk_body`
- `AST.each_bg_block`
- `AST.each_bg_block_in_stmt`
- `AST.each_capture_analysis`

There are also ad hoc walkers in analysis and lowering code, including escape
analysis, promotion planning, control-flow analysis, effect inference, and MIR
lowering/checking.

This creates a recurring failure mode: a new node or a new child position gets
added, but only some walkers learn how to descend into it. Some walkers only
walk statement bodies. Some also need expression positions like `FuncCall.args`
and `MethodCall.object`. Some must stop at BG bodies, while others must descend
through them. That distinction is real, but it should not be re-encoded by hand
in every pass.

## Recommendation

Add declarative traversal metadata for AST and MIR nodes, then build the
existing public walkers on top of that shared traversal engine.

The goal is not one blind recursive `each_pair` walk. That is too broad: it can
walk tokens, type objects, symbol metadata, schemas, cached analysis results,
and other implementation details. The traversal should be explicit about which
fields are semantic children and what role each child plays.

Example shape:

```ruby
module AST
  NodeSpec = Struct.new(:children, :attrs, keyword_init: true)

  TRAVERSAL = {
    Program => NodeSpec.new(children: [
      [:statements, :many, :stmt_body],
    ]),

    FunctionDef => NodeSpec.new(children: [
      [:params, :many, :param],
      [:body, :many, :scope_body],
      [:catch_clauses, :many_hash_body, :catch_body],
      [:default_catch, :many, :catch_body],
    ]),

    IfStatement => NodeSpec.new(children: [
      [:condition, :one, :expr],
      [:then_branch, :many, :stmt_body],
      [:else_branch, :many, :stmt_body],
    ]),

    VarDecl => NodeSpec.new(children: [
      [:value, :one, :expr],
    ]),

    FuncCall => NodeSpec.new(children: [
      [:args, :many, :expr],
    ]),

    MethodCall => NodeSpec.new(children: [
      [:object, :one, :receiver],
      [:args, :many, :expr],
    ]),

    BgBlock => NodeSpec.new(children: [
      [:body, :many, :bg_body],
    ]),
  }
end
```

Exact names are flexible. The important part is that each node declares:

- which fields contain semantic child nodes
- whether each field is a single node, an array, a hash of bodies, etc.
- the role of the child: `:expr`, `:stmt_body`, `:scope_body`, `:bg_body`,
  `:catch_body`, `:pipeline_body`, `:binding_expr`, etc.
- whether the child crosses a semantic boundary such as function scope, BG
  lifetime scope, DO branch, or catch body

## Traversal Modes

Build one generic traversal engine that can expose multiple views:

```ruby
AST.each_descendant(root, mode: :all)
AST.each_descendant(root, mode: :statements)
AST.each_descendant(root, mode: :expressions)
AST.each_descendant(root, mode: :bg_blocks, descend_into_bg: false)
AST.each_descendant(root, mode: :capture_contexts)
```

The mode decides which roles to yield and which boundaries to cross. That keeps
the special treatment centralized instead of repeated in each pass.

Useful options:

- `descend_into_bg: true/false`
- `descend_into_functions: true/false`
- `include_exprs: true/false`
- `include_statements: true/false`
- `preorder: true/false`
- `visited: Set.new` to avoid object cycles or shared subtrees

## Special Treatment To Preserve

Some traversal differences are semantically meaningful and should remain
available as modes/options:

| Case | Suggested Role |
| --- | --- |
| Function body introduces function scope | `:scope_body` |
| BG body introduces concurrency/lifetime boundary | `:bg_body` |
| BG stream body also has yield/stream semantics | `:bg_stream_body` |
| DO branch has capture analysis and fiber-like semantics | `:fiber_body` |
| `IF x AS y` has binding expressions and bodies | `:binding_expr`, `:stmt_body` |
| Match cases contain patterns plus executable bodies | walk body by default; pattern only in pattern-aware mode |
| `FuncCall.args` can contain BG blocks | `:expr` |
| `MethodCall.object` and args both walk | `:receiver`, `:expr` |
| Pipeline op expressions use placeholder scope | `:pipeline_expr` |
| Pipeline op bodies introduce implicit item bindings | `:pipeline_body` |
| Test/benchmark bodies are executable bodies | `:stmt_body` |
| Tokens/types/schemas/analysis caches are metadata | omit from children |

## MIR

MIR should get the same treatment, likely with a separate `MIR::TRAVERSAL`.
MIR is more regular than AST, so the metadata should be simpler.

Examples:

- `MIR::FnDef`: `params`, `body`
- `MIR::IfStmt`: `cond`, `then_body`, `else_body`
- `MIR::WhileStmt`: `cond`, `body`, `update`
- `MIR::ForStmt`: `iter`, `body`
- `MIR::Call`: `args`
- `MIR::MethodCall`: `receiver`, `args`
- `MIR::BgBlock`: `run_body`
- `MIR::CatchWrapper`: `clause_bodies`
- `MIR::DoBlock`: `branch_bodies`
- `MIR::RawZig` / `MIR::InlineZig`: no visible children unless the node carries
  structured verification bodies/contracts

For raw escape-hatch nodes, this also clarifies checker visibility: if a raw
node has no declared children, then passes should assume they cannot see inside
it except through explicit ownership/effect metadata.

## Migration Plan

1. Add `AST::TRAVERSAL` and a generic child enumerator without changing
   existing callers.
2. Add guard tests proving every AST node has a traversal spec.
3. Reimplement `AST.walk_body` on top of the shared engine.
4. Reimplement `AST.each_bg_block`, `AST.each_bg_block_in_stmt`, and
   `AST.each_capture_analysis` as modes/options over the shared engine.
5. Convert ad hoc walkers in escape analysis, promotion planning, control-flow,
   and effect inference one at a time.
6. Add `MIR::TRAVERSAL` and apply the same pattern to MIR checker/lowering
   audits.
7. Once callers are migrated, remove duplicated hand-written recursive logic.

This should be incremental. The first step should preserve public helper names
so call sites do not need to change immediately.

## Guard Tests

Add tests that fail when a new node is introduced without traversal metadata.

Example:

```ruby
it "has traversal specs for every AST node" do
  ast_nodes = AST.constants
    .map { |c| AST.const_get(c) }
    .select { |v| v.is_a?(Class) && v < Struct && v.include?(AST::Locatable) }

  expect(AST::TRAVERSAL.keys).to include(*ast_nodes)
end
```

Also test that every declared child field exists:

```ruby
AST::TRAVERSAL.each do |klass, spec|
  spec.children.each do |field, _cardinality, _role|
    expect(klass.members).to include(field)
  end
end
```

Do the same for MIR nodes that include `MIR::Stmt`, `MIR::Expr`, or
`MIR::Emittable`.

Additional useful tests:

- A synthetic AST containing nested `IF`, `MATCH`, `WHILE`, `WITH`, `DO`, BG,
  function calls, method calls, and pipeline nodes yields the expected BG blocks.
- Shallow BG traversal finds BG blocks embedded in a statement but does not
  descend into their bodies.
- Deep BG traversal finds nested BG blocks inside control flow and expression
  arguments.
- Statement-only traversal does not yield expression children unless requested.
- Expression traversal includes `FuncCall.args`, `MethodCall.object`, and
  `MethodCall.args`.

## Expected Benefits

- Reduces pass complexity by removing per-pass recursive case statements.
- Reduces the chance of forgetting a new AST/MIR node in one walker.
- Makes semantic traversal boundaries explicit and testable.
- Improves future features like MVCC, atomic capabilities, streaming, BG
  lifetimes, and VM lowering, all of which depend on consistently finding
  nested bodies and expression subtrees.
- Provides a better foundation for analysis tooling: coverage audits, effect
  propagation, capture classification, cleanup planning, and MIR visibility
  checks can all share the same traversal facts.

