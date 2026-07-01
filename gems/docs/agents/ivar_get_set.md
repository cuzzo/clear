# `instance_variable_get/set` Architecture Audit

Date: 2026-06-30

Scope:

```sh
rg -n "instance_variable_(get|set)" src
```

Baseline production `src/` count before remediation: **95 sites**.
Current production `src/` count after remediation: **0 sites**.

This audit excludes specs and other gems. The question is whether these sites
are legitimate encapsulation, privacy bypasses, or hidden compiler facts that
should become explicit architecture before self-hosting.

## Summary

The `instance_variable_get/set` usage is **not mostly callers avoiding private
methods that should be public**. The dominant pattern is worse for self-hosting:
compiler facts are stored as dynamic side-channel ivars on AST/MIR nodes instead
of being modeled as explicit fields, typed fact records, or phase-owned side
tables.

There are also straightforward privacy bypasses:

- `src/mir/rewriters/pipeline_rewriter.rb` writes `@var_used` directly even
  though `AST::Locatable#var_used=` exists.
- `src/ast/source_error.rb` reaches into host `@source_code` from a mixin
  instead of using a declared diagnostic-source protocol.
- `src/ast/scope.rb` reaches into host `@scope_stack` from a mixin.
- `src/mir/control_flow.rb` reaches into `OwnershipDataflow#@cfg`.
- `src/ast/symbol_entry.rb` reaches into another `SymbolEntry`'s `@flow`.

Those should be fixed by **keeping fields private** and adding narrow accessors
or protocol methods, not by making broad mutable state public.

## Count By File

| file | sites | primary diagnosis |
| --- | ---: | --- |
| `src/ast/ast.rb` | 43 | Dynamic AST metadata/accessor backing; some hidden facts |
| `src/mir/rewriters/pipeline_rewriter.rb` | 15 | Direct bypass of existing `var_used=` accessor |
| `src/mir/mir.rb` | 15 | Dynamic MIR side facts on `Struct.new` nodes |
| `src/annotator/domains/member_access.rb` | 5 | Hidden AST side-channel facts |
| `src/mir/control_flow.rb` | 4 | Missing CFG/fallibility fields/accessors |
| `src/ast/parser.rb` | 4 | Hidden collection-constructor metadata |
| `src/ast/source_error.rb` | 3 | Mixin reach-in to host source text |
| `src/ast/symbol_entry.rb` | 1 | Private field copy bypass |
| `src/ast/scope.rb` | 1 | Mixin reach-in to host scope stack |
| `src/annotator/phases/expression_domains.rb` | 1 | Temporary call-argument side channel |
| `src/annotator/helpers/auto_inference.rb` | 1 | Hidden collection-constructor metadata read |
| `src/annotator/domains/variables.rb` | 1 | Duplicate borrowed-field side-channel read |
| `src/annotator/domains/errors.rb` | 1 | Hidden collection-constructor metadata read |

## Findings

### 1. Direct Bypass Of Existing Public Metadata Accessors

Severity: **Red/yellow**, because it is easy to fix and creates needless
transpiler blockers.

Representative sites:

- `src/mir/rewriters/pipeline_rewriter.rb:338`
- `src/mir/rewriters/pipeline_rewriter.rb:370`
- `src/mir/rewriters/pipeline_rewriter.rb:411`
- `src/mir/rewriters/pipeline_rewriter.rb:690`

The pipeline rewriter marks synthetic declarations and loops as used with:

```ruby
decl.instance_variable_set(:@var_used, true)
```

But `AST::Locatable` already exposes:

```ruby
def var_used
def var_used=(val)
```

This is just bad code. It is not preserving privacy, and it is not a necessary
dynamic-language technique. Replace every direct write with:

```ruby
decl.var_used = true
```

Recommendation:

- P0 cleanup.
- Add an architecture invariant forbidding `instance_variable_set(:@var_used`
  outside `src/ast/ast.rb`.

### 2. Hidden Collection Constructor Metadata

Severity: **Yellow/red**, because this is real hidden AST state that affects
typing, storage, and collection semantics.

Representative sites:

- `src/ast/parser.rb:2749`
- `src/ast/parser.rb:2750`
- `src/ast/parser.rb:2751`
- `src/annotator/domains/member_access.rb:449`
- `src/annotator/domains/member_access.rb:453`
- `src/annotator/domains/member_access.rb:454`
- `src/annotator/helpers/auto_inference.rb:394`
- `src/annotator/domains/errors.rb:689`
- `src/ast/ast.rb:512`

The parser turns `List[]`, `Pool[]`, and `Set[]` into `AST::ListLit` and then
stamps extra ivars:

```ruby
@constructor_collection
@constructor_soa
@constructor_shard_count
```

Later phases read those ivars to decide whether an empty literal is a plain
auto list or a user-selected collection constructor.

This is not primarily a privacy issue. It is an AST modeling issue: `ListLit`
has semantic state that is not part of its declared shape.

Recommendation:

- Add a typed `AST::CollectionConstructorFact` or
  `AST::ListLit#constructor_options`.
- Expose narrow readers:
  - `collection_constructor?`
  - `constructor_collection`
  - `constructor_soa?`
  - `constructor_shard_count`
- Update parser and annotator code to use the accessors.
- Add an invariant forbidding raw reads/writes of
  `@constructor_collection`, `@constructor_soa`, and
  `@constructor_shard_count`.

No language decision is needed. This is implementation cleanup.

### 3. Temporary Struct Literal Call-Argument State

Severity: **Yellow**, because this is mutable context leaking through AST nodes.

Representative sites:

- `src/annotator/phases/expression_domains.rb:20`
- `src/annotator/domains/member_access.rb:398`

`visit_FuncCall` stamps struct literal arguments with `@is_call_arg` so
`visit_StructLit` can skip wrapping rodata strings in `CopyNode` for temporary
call arguments.

This is hidden control context, not stable AST metadata. The AST node can now
behave differently based on who visited it first and whether that transient
flag was left behind.

Recommendation:

- Prefer passing an explicit call-argument context into argument annotation.
- If the visitor architecture makes that awkward, introduce a small
  `StructLiteralOwnershipContext` stack on the annotator and enter it while
  visiting call args.
- Do not make `is_call_arg` a broad public AST property unless it is a real
  semantic fact after annotation. Today it is a visitor context flag.

This is moderate work because it touches annotator traversal, but it does not
require a language decision.

### 4. Duplicate Borrowed-Field Side Channel

Severity: **Yellow**, with a simple likely fix.

Representative sites:

- `src/annotator/domains/member_access.rb:420`
- `src/annotator/domains/variables.rb:332`

`AST::StructLit` already has:

```ruby
attr_accessor :borrowed_field_names
```

But `visit_StructLit` also stamps `@has_borrowed_fields`, and variable
annotation later reads that hidden flag.

This is duplicate state. It can drift from `borrowed_field_names`.

Recommendation:

- Delete `@has_borrowed_fields`.
- Replace reads with:

```ruby
node.value.borrowed_field_names&.any?
```

- Add a small helper if the nil checks become noisy:

```ruby
def borrowed_fields?
```

No language decision is needed.

### 5. Mixin Reach-In To Host State

Severity: **Yellow**, because the architecture is hiding required host
interfaces behind ivar names.

Representative sites:

- `src/ast/source_error.rb:62`
- `src/ast/source_error.rb:168`
- `src/ast/source_error.rb:183`
- `src/ast/scope.rb:445`

`ErrorHelper` reads `@source_code` from whatever class includes it. Both major
hosts already conceptually own source text:

- `ClearParser` initializes `@source_code`.
- `SemanticAnnotator` exposes `attr_accessor :source_code`.

`ScopeHelper` similarly reads `@scope_stack` from its host.

This is a privacy bypass caused by mixins that assume host ivar names. It is
not a reason to make those fields broadly public. It is a reason to declare the
host protocol.

Recommendation:

- Add `ClearParser#source_code` or `diagnostic_source_code`.
- Have `ErrorHelper` call a narrow method:

```ruby
def diagnostic_source_code
  respond_to?(:source_code) ? source_code : nil
end
```

or require including classes to define it.

- For scopes, have host classes provide a private/protected `scope_stack`
  method or an explicit `ScopeStackOwner` helper contract. The helper should
  call the method, not the ivar.

No language decision is needed.

### 6. Same-Domain Private Field Bypass

Severity: **Yellow/low**, because the fix is narrow and improves readability.

Representative sites:

- `src/ast/symbol_entry.rb:432`
- `src/mir/control_flow.rb:115`
- `src/mir/control_flow.rb:259`
- `src/mir/control_flow.rb:260`
- `src/mir/control_flow.rb:1314`

`SymbolEntry#initialize_copy` reaches into `original.@flow`. The class already
has protected/private flow helpers nearby. It should copy through a protected
method or `flow_snapshot`.

`FunctionCFG.build` writes `@can_fail_fns` after construction and `build_body`
reads it by raw ivar. This should be a declared constructor field or attr reader
on `FunctionCFG`.

`UseAfterMoveChecker` reads `@dataflow.@cfg`. This should be
`OwnershipDataflow#cfg` or a narrower `#blocks` query.

Recommendation:

- Keep the fields private.
- Add narrow readers/writers where the same domain legitimately needs the
  state.
- Prefer immutable constructor fields for `FunctionCFG#can_fail_fns`.

No language decision is needed.

### 7. Dynamic Metadata Backing Public AST Accessors

Severity: **Yellow**, because this is mostly encapsulated but still hides a lot
of compiler state on every AST node.

Representative sites:

- `src/ast/ast.rb:921`
- `src/ast/ast.rb:931`
- `src/ast/ast.rb:945`
- `src/ast/ast.rb:990`
- `src/ast/ast.rb:1015`

`AST::Locatable` exposes many public metadata accessors, but backs them with
dynamic ivars:

- type/coercion facts
- Zig/stdlib matching facts
- ownership/move flags
- collection return facts
- error-union facts
- symbol binding facts

This is not a privacy bypass by callers. Callers mostly use public methods.
The issue is that `Locatable` has become a universal optional-fact bag.

Recommendation:

- Do not simply make these fields public.
- Split them by phase:
  - `TypeFacts`
  - `CallResolutionFacts`
  - `OwnershipFacts`
  - `ErrorFacts`
- Either attach one typed `node.semantic_facts` object or move facts to
  phase-owned side tables keyed by node identity/stable node id.
- Keep compatibility accessors while migrating, but forbid new raw ivar access.

This is larger architectural work. It is not required before the next
ruby-to-CLEAR transpiler wins, but it matters for self-host quality.

### 8. Pipeline Metadata Copy By Ivar List

Severity: **Yellow**, because it copies hidden facts structurally but the facts
are not modeled as a record.

Representative site:

- `src/ast/ast.rb:97`

`AST.copy_pipeline_rewrite_metadata!` copies a fixed list of metadata ivars from
one AST node to another. This is better than scattered raw copies, but the
metadata is still name-shaped state.

Recommendation:

- Introduce a typed `PipelineRewriteMetadata` record.
- Copy the record, not individual ivars.
- Keep the helper as the single migration point until the broader Locatable
  fact split is done.

### 9. Dynamic MIR Side Facts On Struct Nodes

Severity: **Yellow**, because this is hidden MIR state but mostly encapsulated
behind public accessors.

Representative sites:

- `src/mir/mir.rb:1910`
- `src/mir/mir.rb:1925`
- `src/mir/mir.rb:1940`
- `src/mir/mir.rb:1966`
- `src/mir/mir.rb:2734`

`MIR::FsmStructure` and `MIR::DoBlock` attach fact arrays after construction:

- `required_move_guards`
- `move_guard_writes`
- `ownership_facts`
- `destroy_actions`
- `boundary_facts`

This is similar to the AST metadata issue, but smaller and more localized.

Recommendation:

- Add these as explicit constructor fields, or wrap the group in typed fact
  records:
  - `FsmStructureFacts`
  - `ExecutionBoundaryFacts`
- Prefer immutable fact records where possible.
- Avoid lazy mutable arrays unless there is a measured construction cost.

No language decision is needed.

## Remediation Completed

The production `src/` burndown replaced all direct
`instance_variable_get/set` usage with explicit APIs:

- `AST::ListLit` now carries typed `CollectionConstructorFact` metadata.
- Struct-literal call-argument handling now uses an annotator context instead
  of mutating AST nodes with `@is_call_arg`.
- Borrowed-field propagation reads `StructLit#borrowed_fields?` instead of a
  duplicate `@has_borrowed_fields` side channel.
- Pipeline synthetic nodes use `var_used=` rather than writing `@var_used`.
- Diagnostic and scope helpers use narrow host protocol methods instead of
  reaching into host ivars.
- `FunctionCFG` and `OwnershipDataflow` expose typed query methods for the
  state their same-domain collaborators need.
- `MIR::FsmStructure` and `MIR::DoBlock` store side facts in explicit typed
  fields/records rather than lazy dynamic ivars.

## Recommended Work Order

### P0: Mechanical Cleanup, No Design Debate

1. Replace pipeline rewriter `@var_used` writes with `var_used = true`.
2. Replace `@has_borrowed_fields` with `borrowed_field_names&.any?`.
3. Add `OwnershipDataflow#cfg` or `#blocks` and remove the checker reach-in.
4. Add declared `FunctionCFG#can_fail_fns` state.
5. Replace `SymbolEntry#initialize_copy` private ivar read with protected
   `flow_facts`/`flow_snapshot` usage.

These are small, testable, and should reduce ruby-to-CLEAR dynamic blocker
sites immediately.

### P1: Explicit AST Metadata

1. Add typed collection-constructor metadata to `AST::ListLit`.
2. Replace all raw constructor metadata reads/writes.
3. Replace `ErrorHelper` and `ScopeHelper` host-ivar assumptions with narrow
   protocol methods.
4. Replace `@is_call_arg` with explicit annotator context.

These keep fields private while making compiler contracts visible.

### P2: Fact Model Cleanup

1. Split `AST::Locatable` optional metadata into typed phase fact records.
2. Replace pipeline metadata ivar-copy lists with a `PipelineRewriteMetadata`
   record.
3. Make MIR FSM/DO side facts explicit constructor fields or typed fact records.

This is the larger self-host architecture cleanup. It is not just about Ruby
privacy; it is about making the compiler state model translatable and auditable.

## Conclusion

The current ivar usage is a mix of:

- **plain bad code** that bypasses existing public methods;
- **mixin protocol gaps** where helper modules assume host ivar names;
- **same-domain private access** that needs narrow readers;
- **hidden compiler facts** attached to AST/MIR nodes because the data model did
  not have a declared place for them.

The most important architectural conclusion is that we should not solve this by
making every field public. CLEAR wants explicit data and typed phase boundaries.
The right fix is to keep private state private, expose narrow fact/query
methods where needed, and move dynamic AST/MIR metadata into typed records or
phase-owned side tables.
