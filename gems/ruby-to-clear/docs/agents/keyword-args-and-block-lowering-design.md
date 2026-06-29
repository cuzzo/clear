# Ruby-to-CLEAR Keyword Args And Block Lowering Design

Audit date: 2026-06-29.

Primary command:

```text
ruby gems/ruby-to-clear/exe/ruby-to-clear-audit --glob 'src/**/*.rb' --markdown --top 60
```

This document scopes the next high-coverage transpiler work after basic
structure preservation. It assumes CLEAR can provide the required stdlib
primitives and that larger language-design decisions, such as classes, modules,
and mixins, are handled separately. The transpiler should still fail closed when
a Ruby construct needs a design decision that CLEAR has not explicitly made.

## Audit Pressure

### Keyword Arguments And Parameters

Whole-AST signal:

| shape | count |
| --- | ---: |
| `KeywordHashNode` | 7,500 |
| `ParametersNode` | 6,518 |
| `OptionalKeywordParameterNode` | 470 |
| `RequiredKeywordParameterNode` | 310 |
| calls shaped `args=1+kw` | 5,730 |
| calls shaped `args=3+kw` | 1,043 |
| calls shaped `args=2+kw` | 563 |

Current unsupported-output signal:

| unsupported output node | count |
| --- | ---: |
| `KeywordHashNode` | 439 |
| `ParametersNode` | 121 |

This blocks constructors, diagnostics, Sorbet `params`, `const`, `prop`, and a
large fraction of helper APIs. The current `check_arguments!` and
`check_parameters!` approach rejects too much structure before the caller has a
chance to handle safe shapes.

### Blocks

Whole-AST signal:

| shape | count |
| --- | ---: |
| literal blocks | 9,021 |
| block args (`&foo`) | 262 |
| block bodies with one statement | 7,837 |
| block bodies with 2-3 statements | 637 |
| block bodies with 4-8 statements | 417 |
| block bodies with 9+ statements | 129 |

Top block callees after Sorbet declaration blocks:

| callee | count |
| --- | ---: |
| `each` | 925 |
| `map` | 338 |
| `new` | 319 |
| `any?` | 126 |
| `each_with_index` | 73 |
| `filter_map` | 64 |
| `select` | 55 |
| `flat_map` | 52 |
| `each_value` | 49 |
| `find` | 46 |
| `reject` | 44 |
| `lambda` | 39 |
| `each_with_object` | 36 |
| `sort_by` | 31 |
| `each_pair` | 25 |
| `loop` | 20 |
| `map!` | 20 |
| `reverse_each` | 17 |
| `sum` | 16 |
| `each_key` | 15 |

The transpiler already has partial expression-only support for several
pipeline blocks. The missing coverage is mostly multi-statement blocks,
implicit block return, block-local renaming, mutation, and safe rewrites such as
`reverse_each` into `reverse |> EACH`.

## Design Principles

- Prefer direct CLEAR constructs, pipelines, and UFCS-style calls over Ruby
  compatibility helpers.
- Keep each handler shape-specific. Reject keyword splats, forwarding, nonlocal
  block flow, and dynamic block arguments unless the lowering is exact.
- Preserve useful outer structure even when one argument or block statement is
  unsupported.
- Add config-driven rewrites where Ruby call shapes map mechanically to CLEAR
  pipeline stages or host helpers.
- Do not let the transpiler decide new CLEAR semantics. If a lowering requires
  a compiler or language change, record that as an explicit prerequisite.

## Keyword Args And Keyword Params

### Required Transpiler Work

1. Replace early rejection with shape-aware argument lowering.
2. Teach `visit_arguments_node` to return both positional and keyword
   arguments, not only a comma-joined string.
3. Add `visit_required_keyword_parameter_node` and
   `visit_optional_keyword_parameter_node`.
4. Extend `visit_parameters_node` to preserve required, optional, rest, post,
   keyword, keyword-rest, and block parameter categories.
5. Let registry handlers inspect keyword arguments before choosing a lowering.
6. Add caller-specific adapters for high-frequency Sorbet declaration forms:
   `params`, `const`, `prop`, and `error!`.
7. Fail closed on keyword splats and forwarding until there is an exact target
   representation.

### Internal API Shape

String-only argument rendering is too weak for this work. Add an internal
argument result:

```ruby
ArgumentList = Struct.new(
  :positionals,
  :keywords,
  :splat,
  :keyword_splat,
  :forwarding,
  keyword_init: true
)
```

`positionals` should hold translated expressions in order. `keywords` should
hold ordered `[name, translated_value]` pairs. The visitor should preserve
source order for comments/TODOs, but handler decisions should receive the
structured shape.

### Safe Call Lowerings

Ruby:

```ruby
error!(:type_mismatch, node, expected: expected, actual: actual)
```

Target if CLEAR has named arguments:

```clear
error!(.type_mismatch, node, expected: expected, actual: actual)
```

Target if the callee is configured for an options record:

```clear
error!(.type_mismatch, node, ErrorOptions{ expected: expected, actual: actual })
```

The transpiler should not globally choose between these forms. It should support
both as explicit handler/config choices:

```ruby
register_call("error!", keyword_mode: :named)
register_call("Diagnostic.new", keyword_mode: :record, record_type: "Diagnostic")
```

### Safe Parameter Lowerings

Ruby:

```ruby
def diagnostic(kind, message:, severity: :error)
  Diagnostic.new(kind: kind, message: message, severity: severity)
end
```

CLEAR-shaped target:

```clear
FN diagnostic(kind: Auto, message: Auto, severity: Auto = .error) RETURNS !Auto ->
  RETURN Diagnostic{ kind: kind, message: message, severity: severity };
END
```

This is safe when every keyword parameter has a static name and default values
are normal expressions.

### Sorbet Declaration Lowerings

Ruby:

```ruby
sig { params(name: String, fields: T::Hash[Symbol, Type]).returns(Type) }
```

Target behavior:

- Extract `name: String` and `fields: HashMap<String@symbol, Type>`.
- Do not emit runtime code for `sig`, `params`, or `returns`.
- Preserve a localized TODO only for unsupported type expressions.

Ruby:

```ruby
const :name, String, default: "unknown"
prop :children, T::Array[Node], factory: -> { [] }
```

Target behavior:

- Add struct field metadata for static `const` and `prop`.
- Translate simple `default:` expressions.
- Leave `factory:` lambdas as TODOs until lambda lowering is exact.

### Unsupported Or TODO Cases

Ruby:

```ruby
foo(a, **kwargs)
```

Reason to reject: keyword splat changes the call shape dynamically.

Ruby:

```ruby
def foo(**kwargs)
  bar(**kwargs)
end
```

Reason to reject: keyword-rest forwarding needs either a map-like dynamic call
ABI or a closed target shape. The transpiler should emit a TODO unless a handler
declares the exact keyword set.

Ruby:

```ruby
send(name, value: x)
```

Reason to reject: keyword lowering does not make dynamic dispatch safe.

### Work Estimate

This is a medium-sized transpiler change:

- 2-3 days to add structured argument/parameter objects and retrofit existing
  call rendering.
- 1-2 days for Sorbet/declaration keyword adapters.
- 1-2 days for oracle tests and negative fixtures.

Expected risk is moderate because many existing handlers assume `visit(args)`
returns a string. Convert handlers incrementally, with compatibility helpers
such as `render_arguments(argument_list)`.

## Block Lowering

### Current Partial Support

The registry already supports several expression-only block forms:

- `map`
- `select`
- `reject`
- `any?`
- `all?`
- `find` / `detect`
- `filter_map`
- `flat_map`
- `sort_by`
- `reduce` / `inject`
- `each`

The main limitation is `simple_block_expression?`: multi-statement blocks are
rejected even when the final Ruby expression is a direct block result.

### Required Transpiler Work

1. Add a structured `BlockLowering` result with parameters, body statements,
   final expression, local writes, captured reads, and control-flow flags.
2. Implement implicit return for pipeline blocks: the final expression in a
   block is the value of `map`, `select`, `reject`, `flat_map`, `sort_by`,
   `sum`, and similar stages.
3. Distinguish side-effect blocks from value blocks.
4. Add a config table for block handlers so each Ruby method declares arity,
   result mode, supported control flow, and optional receiver prelude.
5. Support pipeline rewrites that expand into multiple CLEAR stages, such as
   `reverse_each` to `reverse |> EACH`.
6. Keep nonlocal `return`, unsafe `break`, `yield`, `super`, `rescue`, and
   `ensure` localized as TODOs unless a handler explicitly supports them.

### Proposed Handler Config

```ruby
BlockHandler = Struct.new(
  :ruby_name,
  :arity,
  :mode,
  :implicit_return,
  :receiver_transform,
  :clear_stage,
  :allows_next,
  :allows_break,
  :mutates_receiver,
  keyword_init: true
)
```

Examples:

| Ruby | mode | receiver transform | CLEAR stage |
| --- | --- | --- | --- |
| `each` | side_effect | none | `EACH` |
| `map` | value | none | `SELECT` |
| `select` | predicate | none | `WHERE` |
| `reject` | predicate | none | `WHERE !` |
| `any?` | predicate_terminal | none | `ANY` |
| `all?` | predicate_terminal | none | `ALL` |
| `find` | predicate_terminal | none | `FIND` |
| `filter_map` | value | none | `SELECT |> WHERE _ != NIL` |
| `flat_map` | value | none | `UNNEST` |
| `sort_by` | value | none | `ORDER_BY` |
| `sum` | value | none | `SUM_BY` or `SELECT |> SUM` |
| `map!` | mutation | none | explicit mutable update |
| `reverse_each` | side_effect | `reverse` | `EACH` |
| `each_key` | side_effect | `keys` | `EACH` |
| `each_value` | side_effect | `values` | `EACH` |
| `each_pair` | side_effect | `pairs` | `EACH` |
| `each_with_index` | side_effect | `withIndex` | `EACH` |
| `each_with_object` | accumulator | explicit accumulator | `EACH` |

### Minimal CLEAR/Compiler Prerequisites

The supportable block set should not require a major language feature. The
small prerequisites are:

- pipeline stages can accept a statement block whose final expression is the
  value for value/predicate stages,
- stage composition can insert simple receiver transforms such as `reverse`,
  `keys`, `values`, `pairs`, and `withIndex`,
- terminal stages such as `ANY`, `ALL`, `FIND`, and `SUM` can consume those
  value/predicate blocks,
- mutable receiver replacement is explicit for `map!`, or `map!` remains a TODO
  where aliasing would make replacement incorrect.

### Implicit Return For Multi-Statement Pipeline Blocks

Ruby:

```ruby
nodes.map do |node|
  name = node.name.to_s
  normalize(name)
end
```

Target shape:

```clear
nodes |> SELECT {
  MUTABLE name = node.name.toString();
  normalize(name)
}
```

The final expression is the block value. The transpiler should not require a
Ruby `return`, and it should not emit one inside the pipeline block. This needs
one of two CLEAR-side capabilities:

- pipeline stages accept statement blocks whose last expression is the stage
  value, or
- the transpiler can lower the block into a generated local helper function.

The first option is the minimal compiler/language addition. The second avoids a
pipeline-block language change but creates more generated declarations and
capture plumbing.

### Safe Block Examples

Ruby:

```ruby
items.select do |item|
  type = item.type
  type != :unknown
end
```

Target:

```clear
items |> WHERE {
  MUTABLE type = item.type;
  type != .unknown
}
```

Ruby:

```ruby
items.reject do |item|
  item.nil?
end
```

Target:

```clear
items |> WHERE !(item == NIL)
```

Ruby:

```ruby
items.reverse_each do |item|
  consume(item)
end
```

Target:

```clear
items |> reverse |> EACH {
  consume(item);
}
```

Ruby:

```ruby
items.each_with_index do |item, index|
  emit(index, item)
end
```

Target:

```clear
items |> withIndex |> EACH {
  emit(_.index, _.value);
}
```

This requires config support for parameter destructuring or generated names.

### More Complex But Supportable Blocks

Ruby:

```ruby
items.each_with_object(Set.new) do |item, seen|
  seen << item.name
end
```

Possible target:

```clear
MUTABLE seen = Set[];
items |> EACH {
  seen.append(item.name);
}
```

This is supportable, but it is no longer a pure expression pipeline. The
handler needs to allocate the accumulator before the stage and return it after.

Ruby:

```ruby
items.map! do |item|
  normalize(item)
end
```

Possible target:

```clear
items = items |> SELECT normalize(item);
```

This is safe only when receiver mutation can be represented as replacing the
binding. If aliasing semantics matter, emit a TODO.

### Unsupported Or TODO Block Cases

Ruby:

```ruby
items.map do |item|
  return item if item.ready?
  item.name
end
```

Reason to reject: Ruby `return` exits the enclosing method, not just the block.

Ruby:

```ruby
items.each do |item|
  break if item.stop?
  consume(item)
end
```

Reason to reject unless CLEAR pipeline stages support early termination with
matching semantics.

Ruby:

```ruby
items.map(&method(:normalize))
```

Reason to reject initially: block arguments require first-class callable shape
tracking. Support only simple `&:to_s`-style symbols if the lowering is direct.

### Work Estimate

This is the largest implementation item after keyword args:

- 2-3 days for `BlockLowering` analysis and implicit return.
- 2-4 days for handler config and core handlers:
  `each`, `map`, `select`, `reject`, `flat_map`, `sort_by`, `sum`, `map!`.
- 2-3 days for expanded handlers:
  `any?`, `each_with_index`, `each_with_object`, `each_key`, `loop`,
  `reverse_each`, `each_value`, `each_pair`.
- 2-3 days for block control-flow detection and negative fixtures.

The compiler/language work is probably small if pipeline stages can accept
multi-statement blocks with implicit final-expression values. Without that,
the transpiler needs generated helper functions and capture analysis, which is
substantially more invasive.

## Receiver-Aware Translation And Comptime Decision

`CallNode` is huge: 89,412 calls and 5,958 unique method names. Most calls are
not currently marked unsupported, but many are likely naive method-call output.
The most concerning Ruby predicates are `is_a?` and `respond_to?`.

### Preferred Path

After proper transpilation, most `is_a?` and `respond_to?` calls should
disappear because the source shape has become explicit:

- tagged unions or enums for closed variants,
- explicit optional values instead of runtime nil/type checks,
- generated field access for static records,
- closed dispatch tables for formerly dynamic method sets,
- source refactors where Ruby was probing object capabilities dynamically.

### Zig Comptime Option

It is possible to support some of this with Zig comptime-backed CLEAR helpers,
and that may be the right fallback for hosting/compiler code. Example intent:

```clear
hasField?(T, "name")
isVariant?(value, .FunctionDef)
hasMethod?(T, "emit")
```

This should be treated as a separate design decision, not an automatic Ruby
compatibility layer.

### When To Use Comptime

Use comptime/metaprogramming only when all of these are true:

- the receiver type is statically known,
- the queried member/type is a literal symbol/string/constant,
- the result can compile away,
- the helper expresses a CLEAR concept, not a Ruby object-model behavior.

### When To Reject

Ruby:

```ruby
node.respond_to?(method_name)
node.is_a?(klass)
```

Reject when the queried name/type is dynamic. The correct repair is usually a
closed enum/union/table or a source refactor.

## Block Control Flow And Nonlocal Flow

Audit signal inside blocks:

| node | count |
| --- | ---: |
| `NextNode` | 697 |
| `ReturnNode` | 67 |
| `BreakNode` | 44 |
| `SuperNode` | 35 |
| `RescueModifierNode` | 31 |
| `ForwardingSuperNode` | 20 |
| `YieldNode` | 14 |
| `EnsureNode` | 4 |
| `RescueNode` | 3 |

### Supportable Cases

Ruby:

```ruby
items.filter_map do |item|
  next if item.skip?
  item.value
end
```

Target if the handler supports `next` as nil for `filter_map`:

```clear
items |> SELECT {
  IF item.skip?() THEN
    NIL
  ELSE
    item.value
  END
} |> WHERE _ != NIL
```

Ruby:

```ruby
items.each do |item|
  next if item.skip?
  consume(item)
end
```

Target:

```clear
items |> EACH {
  IF !(item.skip?()) THEN
    consume(item);
  END
}
```

Ruby:

```ruby
loop do
  token = next_token
  break if token.nil?
  consume(token)
end
```

Target if CLEAR has a direct loop/break shape:

```clear
WHILE TRUE DO
  MUTABLE token = nextToken();
  IF token == NIL THEN
    BREAK;
  END
  consume(token);
END
```

### Unsupported Cases

Ruby:

```ruby
items.map do |item|
  return item if item.ready?
  item.value
end
```

Reject: `return` exits the enclosing Ruby method. Translating it inside a
pipeline stage would be wrong unless CLEAR gets explicit nonlocal return
semantics, which is not desirable for this migration path.

Ruby:

```ruby
items.each do |item|
  super(item)
end
```

Reject: `super` and forwarding `super` require class/inheritance semantics.

Ruby:

```ruby
items.map do |item|
  risky(item) rescue fallback
end
```

Reject until CLEAR exception/error handling shape is explicit for this source
region. Ruby rescue modifiers hide control flow and error typing.

### Detection Requirements

For every block, compute flags before lowering:

- `has_next`
- `has_break`
- `has_return`
- `has_yield`
- `has_super`
- `has_rescue`
- `has_ensure`
- `has_retry_or_redo` if those nodes appear later

Handlers should declare which flags are supported. Unsupported flags should
emit a TODO around the smallest enclosing block or statement, not the whole
method.

## Interpolation, Regex, And Scanner Lowering

Audit signal:

| shape | count |
| --- | ---: |
| `EmbeddedStatementsNode` | 3,005 |
| `InterpolatedStringNode` | 1,812 |
| `RegularExpressionNode` | 183 |

Current hard failure:

```text
NoMethodError: undefined method `statements' for Prism::InterpolatedStringNode
```

### Required Transpiler Work

1. Fix interpolated string traversal for all Prism part shapes.
2. Treat embedded statements as expression contexts. Multi-statement embedded
   Ruby should be rejected unless only the final expression is used safely.
3. Translate simple interpolation to CLEAR string interpolation or string
   builder calls.
4. Preserve regex literal source exactly when the regex cannot be lowered.
5. Use explicit match-result variables for regex matching; do not rely on Ruby
   global match state.
6. Lower `StringScanner.new` and scanner operations only to a compiler-lexing
   scanner API, not broad Ruby `StringScanner` compatibility.

### Examples

Ruby:

```ruby
"expected #{expected}, got #{actual}"
```

Target:

```clear
"expected ${expected}, got ${actual}"
```

Ruby:

```ruby
Regexp.last_match(1)
```

Reject: this depends on implicit Ruby match state. Require an explicit match
result.

Ruby:

```ruby
if (match = pattern.match(source))
  match[1]
end
```

Possible target:

```clear
MUTABLE match = pattern.match(source);
IF match != NIL THEN
  match.groups[1];
END
```

### Work Estimate

- Less than 1 day for the hard interpolated-string crash.
- 1-2 days for string interpolation oracle coverage.
- 2-4 days for regex/scanner safe subset once the CLEAR stdlib shape exists.

## Assignment, Update, And Destructuring Forms

Audit signal from current unsupported output:

| node | count |
| --- | ---: |
| `MultiWriteNode` | 20 |
| `CallOperatorWriteNode` | 12 |
| `IndexOrWriteNode` | 10 |
| `SplatNode` | 8 |
| `CallOrWriteNode` | 2 |
| `InstanceVariableOrWriteNode` | 3 |

Whole-AST signal is larger for some shapes, so these will become more visible
after module, keyword, and block support expose more inner code.

### Supportable Cases

Ruby:

```ruby
a, b = b, a
```

Target:

```clear
MUTABLE __tmp_multi_0 = b;
MUTABLE __tmp_multi_1 = a;
a = __tmp_multi_0;
b = __tmp_multi_1;
```

Ruby:

```ruby
counts[key] ||= 0
counts[key] += 1
```

Target:

```clear
IF counts[key] == NIL THEN
  counts[key] = 0;
END
counts[key] = counts[key] + 1;
```

Ruby:

```ruby
node.value ||= default
```

Target:

```clear
IF node.value == NIL THEN
  node.value = default;
END
```

Ruby:

```ruby
values << item
```

Already supportable as append-style mutation, provided receiver shape is a
known mutable collection.

### Unsupported Or TODO Cases

Ruby:

```ruby
head, *tail = values
```

Reject initially: rest destructuring needs slice allocation and shape checks.

Ruby:

```ruby
foo.bar += value
```

Reject unless `foo.bar` is a known assignable field and repeated receiver
evaluation is safe. Otherwise the transpiler may duplicate side effects.

Ruby:

```ruby
object[index()] ||= value
```

Reject unless the index expression can be evaluated once into a temporary.
Support is possible, but the handler must avoid changing evaluation order.

### Work Estimate

This is comparatively small:

- 1 day for simple or-write/operator-write handlers on locals and instance
  fields.
- 1-2 days for index or-write/operator-write with temporary evaluation.
- 1 day for literal multi-write and swap forms.
- Rest destructuring and splat forwarding should remain TODOs until audit data
  proves they matter.

## Implementation Order

1. Add structured argument and parameter objects.
2. Add keyword parameter visitors and safe keyword call rendering.
3. Add Sorbet/declaration keyword adapters.
4. Add `BlockLowering` analysis with final-expression detection.
5. Add implicit-return pipeline block support for `map`, `select`, `reject`,
   `flat_map`, `sort_by`, `sum`, and `map!`.
6. Add side-effect and receiver-transform block handlers for `each`,
   `reverse_each`, `each_key`, `each_value`, `each_pair`, `each_with_index`,
   `loop`, and `each_with_object`.
7. Add block control-flow flags and negative fixtures.
8. Fix interpolated string traversal and add interpolation fixtures.
9. Add assignment/update/destructuring handlers.
10. Re-run audit and use line-impact data to choose the next handler.

## Testing Strategy

- Add oracle tests for each accepted Ruby snippet and exact CLEAR output.
- Add negative tests for every rejected shape, asserting localized TODO output.
- Add corpus tests using real snippets from `src/annotator`, `src/ast`,
  `src/mir`, and `src/tools`.
- Track audit before/after:

  ```text
  ruby gems/ruby-to-clear/exe/ruby-to-clear-audit --glob 'src/**/*.rb' --markdown --top 60
  ```

Success for this phase is not "accept every Ruby block." Success is that common
keyword and block shapes translate directly, while dynamic or nonlocal Ruby
semantics remain explicit TODOs.
