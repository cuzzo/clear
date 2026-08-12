# Translator Defects Found During the 2026-07-20 Golden-Suite Migration

The golden suite (`spec/transpiler_spec.rb`) was migrated from legacy CLEAR
expectations to current-language output (332 failing examples at the start).
Every example whose failure was purely retired syntax was rewritten to the
current translator output. The examples below were deliberately LEFT FAILING
because the current output drops semantics the example targets. They are
translator defects, not expectation debt: fix the translator (or, where
noted, decide the intended lowering), then update the example from fresh
output. Line numbers are from the migration runs and drift with edits; find
each example by its `it` description.

## Optionality and narrowing

- FIXED (2026-07-21): `T::Array[T.nilable(T)]` now lowers as `[]?T` and is
  distinct from `T.nilable(T::Array[String])` (`?[]String`). Root causes:
  `expand_generic_type_aliases` hoisted the element `?` onto the collection
  during alias expansion, and `inline_collection_type` rendered internal
  `?T[]` (element-optional by convention) as `?[]T`.
- FIXED (2026-07-21): with the element type correctly optional, fetch/index
  locals are tracked as optionals and the existing guard-exit machinery
  emits `IF x EXISTS AS x_value` narrowing; narrowed payloads are passed to
  non-optional parameters (`keep(vt_value)`). Compound `a && opt` narrowing
  now also applies inside tail-lifted (returning) ifs
  (`render_returning_simple_if` gained the `optional_truthies_in_and`
  path), emitting `(token?).line`-style unwraps; `method_receiver_code` no
  longer strips the parens off `(name?)` receivers.

## Reflection folding

- FIXED (2026-07-21): `respond_to?` no longer folds to constant `FALSE`
  when the receiver is unknown. Shape folding now runs first (Array/Hash/
  String receivers fold TRUE/FALSE from `SHAPE_METHODS`),
  `static_respond_to_result` returns nil (undecided) instead of false
  unless the receiver is a collected user class, and undecided receivers
  emit the dynamic `respondsTo?(receiver, "name")` helper.

## Collections

- FIXED (2026-07-21): `each` with two block params on a statically
  array-like receiver now iterates elements with tuple destructuring
  (`FOR _ IN pairs DO table[_._0] = COPY _._1; END`); hash semantics are
  kept for hash-like and unknown receivers. `each_pair` on a receiver that
  is not statically hash-typed is rejected with "each_pair requires a
  statically known hash receiver".
- Aggregate receiver materialization: `slots[key].sources << value` emits
  `((UNWRAP (slots[key])).sources).append(COPY value);` - append through an
  unwrapped temporary, no `&` borrow, so the mutation does not persist into
  the map entry. STILL OPEN (2026-07-21): the fix needs a materialize +
  mutate + write-back transform (`MUTABLE tmp = UNWRAP (slots[key]); ...;
  slots[key] = tmp;`) whose ownership semantics (move-out vs COPY of a
  heap-owning struct) need a deliberate design against the typed-IR
  storage/ownership model; not forced here.

## Unions and type distinctions

- FIXED (2026-07-21): `T.any(Symbol, String)` (and subset aliases of it) no
  longer collapse to `String@symbol`; they emit a real two-member `UNION`
  with `PARTIAL MATCH` cast helpers, and `is_a?(Symbol)/is_a?(String)`
  narrowing emits real `IS_A` tests. The collapse is retained only for hash
  KEY positions (`T::Hash[T.any(String, Symbol), V]` stays
  `{String@symbol}V`) and for contexts with no derivable union name.

## Exceptions

- FIXED (2026-07-21): `rescue ParseError` (typed rescue) is now rejected
  ("Complex exception handling (rescue) is not supported") instead of
  silently widening to the catch-all CATCH list. Only `StandardError` /
  `Exception` rescues lower to `CATCH Transient, Input, System, NotFound,
  Permission, Canceled` (`static_exception_name?` checks the constant
  name).

## Declarations

- FIXED (2026-07-21): a static string-set constant is only erased into
  equality-chain folds when every reference is `include?` with a dynamic
  argument (`static_string_set_fold_only_uses?`). Any other use - bare
  reads, iteration, `include?` on a literal (which would degenerate to
  `("A" == "A")`) - keeps the named binding (`MUTABLE keywords: [Set]String
  = [...]`) and membership lowers as `keywords.contains?(...)`.
- FIXED (2026-07-21): prelude reachability in
  `HelperConfig#prelude_lines_for` is now transitive: an `EXTERN STRUCT`
  referenced from a kept `EXTERN FN` signature is kept too; unused
  declarations are still dropped.
- FIXED (2026-07-21): `Param#takes` emits as field access. The namespace
  metadata walk (`metadata_source_ancestor_dirs`) stopped two directories
  above the source when no `ruby` root marker exists, so `ast/ast.rb` was
  never scanned from `annotator/helpers/*.rb`; the walk now reaches the
  grandparent.

## Unions and type distinctions (continued)

- FIXED (2026-07-21): Module type aliases of `String|Symbol` now emit their
  `UNION` under the flattened reference name (aliases declared directly in a
  Ruby module drop the module prefix; class-owned aliases stay prefixed),
  and `is_a?` narrowing on them is real (`emits module type aliases with
  their flattened reference names`, `expands required mixins and emits their
  signature unions`, `captures narrowed union payloads in returning
  ternaries`). Note: module-alias flattening renamed `MIRBody` -> `Body` in
  the interface-union goldens.
- FIXED (2026-07-21): with imported module aliases registering under their
  flattened names, a local anonymous return union that would shadow an
  imported `ReturnValue` alias is disambiguated to `LocalReturnValue`
  (`references an imported AST Node union without redeclaring it`).

## Strings

- FIXED (2026-07-21): the line-continuation concat no longer escapes the
  interpolation. Prism nests the interpolated literal one level down
  (`InterpolatedStringNode` inside `InterpolatedStringNode`), so the "no
  embedded statements" fast path re-escaped the already-rendered `${...}`;
  `visit_interpolated_string_node` now detects embedded statements
  recursively.

## Struct semantics

- A custom method overriding a Struct member (`def name; self[:name].to_s;
  end`) is dropped; raw field access `identifier.name` is emitted instead of
  the prefixed method call (`uses prefixed calls for duplicate imported
  Struct.new methods`).

## Needs a decision (not clearly a defect)

- DECIDED (2026-07-21): the PARTIAL MATCH value-block lowering for
  statementful case-expression arms parses as valid current CLEAR (verified
  against the compiler parser), so the example was rewritten as a positive
  test (`lowers statementful case expression arms to value blocks in lax
  mode`). Caveat accepted for lax mode: locals assigned inside the arm are
  block-scoped in the output while Ruby leaks them to the enclosing scope.

## Cosmetic (fix in method registry)

- FIXED (2026-07-21): simple string/number literal receivers are no longer
  parenthesized (`"abc".byteLen();`); `method_receiver_code` recognizes
  bare literals. The one golden that had baked in the parenthesized form
  (`(("abc").length() == 0)`) was updated.
