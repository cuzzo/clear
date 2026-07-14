# Cross-Gem Structural Type and Phase Metrics

## Purpose

This document proposes metrics that would have identified the source-design
problems found while assessing the CLEAR parser and annotator for
Ruby-to-CLEAR translation. They are not Ruby-to-CLEAR checks. They describe
general ways that a program can retain enough type information to pass its
native checks while losing the explicit contracts needed by humans, static
analysis, or another compiler.

The proposals deliberately preserve the existing gem boundaries:

- **FactMine** parses language syntax and emits normalized facts. Any knowledge
  of Sorbet spelling, Ruby mixins, properties, decorators, or equivalent
  language constructs belongs in a language adapter or language type-semantics
  module.
- **Decomplex** consumes normalized facts and ranks local or structural
  complexity pressure. It must not parse language syntax or infer types.
- **Nil-kill** owns contradictions involving optionality, type declarations,
  runtime protocol domains, and flow evidence.
- **Espalier** aggregates owner, phase, state, capability, and dependency facts
  into architecture-level findings.
- **Lineage** may display and correlate the resulting SARIF/fact records, but it
  must not rederive them.

The motivating inventories are:

- `docs/agents/parser-type-slop.md`
- `docs/agents/annotator-type-slop.md`
- `docs/agents/mir-type-slop.md`

The competitive comparison assumes the documented scope of common tool
families: Sorbet provides local control-flow-sensitive typing but little general
dataflow analysis; RuboCop's built-in metrics cover conventional size, ABC,
nesting, and cyclomatic complexity; CodeQL and Semgrep provide programmable
dataflow/taint foundations but not these first-class product metrics. Relevant
references are [Sorbet flow-sensitive typing](https://sorbet.org/docs/flow-sensitive),
[Sorbet `T.untyped`](https://sorbet.org/docs/untyped),
[RuboCop metrics](https://docs.rubocop.org/rubocop/cops_metrics.html),
[CodeQL flow state](https://codeql.github.com/docs/codeql-language-guides/using-flow-labels-for-precise-data-flow-analysis/),
and [Semgrep's dataflow glossary](https://semgrep.dev/docs/writing-rules/glossary).

"Existing-tool gap" therefore means that the diagnostic is not normally
shipped as a first-class cross-language metric. It does not mean a sufficiently
custom CodeQL, Semgrep, compiler-plugin, or framework-specific rule could never
be written.

## Tier Semantics

The tiers follow Decomplex report semantics, where tier 1 is the highest
signal and lowest expected false-positive rate.

| Tier | Meaning | Appropriate use |
|---|---|---|
| **T1** | A direct contradiction or strongly evidenced loss of an explicit contract. | Primary triage, SARIF warning/error, and possibly autofix when the proof is closed. |
| **T2** | Credible architectural or design pressure whose correctness depends on domain context. | Review warning and strong input to cross-detector convergence. |
| **T3** | High-recall exploratory evidence. The pattern is useful for finding candidates but noisy in isolation. | Report/SARIF note only; never a CI gate by itself. |

Tier is signal confidence, not implementation priority or severity. A T3 metric
may describe expensive design debt, while a T1 metric may identify a tiny
contract error.

## Estimation Rules

The LoC estimates are rough changed-line ranges and include:

- FactMine schema/extraction work;
- consumer detector or aggregation work;
- JSON/SARIF/report projection;
- integration fixtures and exact oracles;
- focused unit tests where normalized fact behavior needs isolation;
- brief user-facing documentation.

They do not include implementing equivalent syntax extraction for every
language. When a feature requires syntax-specific extraction, expect roughly
**40-120 LoC per additional language**, plus a representative integration
fixture. Features operating only on normalized types, CFG/DFG, calls, or state
facts should need little or no per-language consumer work.

The estimates overlap because several features share the same foundational
facts. They must not be summed as if each were implemented independently.

## Source-Traceability Rule

Every example below is a faithful excerpt from the current Parser or Annotator
source (or from a direct consumer when the problem is the boundary between
them). The path, method, and current line span are named explicitly. Formatting
is occasionally condensed and `# ...` marks omitted statements; declarations,
types, and relevant operations are not synthetic. A feature motivated by a
risky protocol rather than a demonstrated bug is labelled as such. This
distinction matters: an analyzer request is not evidence that the motivating
production code is already wrong.

| Feature | Exact primary trigger | Evidence in current source |
|---|---|---|
| FR-T1-01 | `Lexer::Token#value` into `ClearParser#parse_lit` field pairs | **Confirmed erosion/translation blocker.** Token-kind/value correlation is lost. |
| FR-T1-02 | `process_pattern` into `dispatch_*_pattern_action` | **Confirmed shape loss.** Rule-specific capture positions become one union array. |
| FR-T1-03 | `parse_union_def` converting `method_reqs.empty?` to nil | **Review candidate only.** No proof yet that nil and empty are equivalent to all consumers. |
| FR-T1-04 | `AutoSlotId#eql?` | **Confirmed contract contradiction.** The declared domain makes the required protocol guard statically impossible. |
| FR-T1-05 | `SemanticAnnotator#semantic_index` lifecycle | **Contract gap, not a found bypass.** Completion is nilability plus `T.must`; current frontend ordering is correct. |
| FR-T1-06 | `@suppress_struct_lit` toggles in both match parsers | **Scoped-state risk, not a found continuing leak.** The previous early-return example was false. |
| FR-T1-07 | `ErrorHelper#error!` / `diagnostic_token` | **Confirmed escape boundary.** DFG is still needed to distinguish containment from propagation. |
| FR-T2-01 | Parser metadata aliases at `parser.rb:55-64` | **Confirmed record-shaped hashes.** Per-key value types are erased. |
| FR-T2-02 | `FunctionAnalysis` requiring `SemanticAnnotator` | **Confirmed whole-host dependency.** Sorbet declares it, but only at maximum capability. |
| FR-T2-03 | `run_whole_program_semantics!` | **Confirmed implicit phase inputs/outputs.** Whether to split them is architectural judgment. |
| FR-T2-04 | `matched_signature` writers/readers | **Confirmed multiple writers.** Writer overlap or invalid bypass is not yet proven. |
| FR-T2-05 | `FunctionAnalysis#resolve_call` | **Confirmed decision/application fusion.** |
| FR-T2-06 | `PatternCapture` and comptime refinement result | **Confirmed type-pressure convergence.** |
| FR-T2-07 | `DeclarationNode` versus raw lifetime unions | **Confirmed normalized type duplication.** Alias adoption remains a coupling judgment. |
| FR-T3-01 | `PatternCapture` roles | **Exploratory cohesion evidence.** |
| FR-T3-02 | Parser global/instance/temporary modes | **Exploratory state-space evidence.** The fields must not automatically be treated as one machine. |
| FR-T3-03 | `PipeAnalysis` capability clusters | **Exploratory cohesion evidence.** |
| FR-T3-04 | `resolve_call` semantic fan-out | **Exploratory record opportunity.** Smaller decision records already exist nearby. |
| FR-T3-05 | `semantic_index` readers outside the annotator corpus | **Confirmed analyzer-confidence defect case.** |

## T1 Metrics

### FR-T1-01: Boundary Type Erosion and Recovery Debt

**Problem.** A producer, storage slot, or helper has a value whose precise
shape is known from construction or a discriminator, but its exposed type
erases that fact. Callers immediately recover the lost fact with a cast,
assertion, destructuring assumption, or dynamic check. This identified the
parser's broad token-value boundary.

**Exact Parser trigger.** `Lexer::Token#value` is an untyped slot in
`compiler/ruby/ast/lexer.rb:10`. A struct-literal parser then relies on the
token kind to mean that the value is a field-name string, but carries the raw
slot into a nested pair in `ClearParser#parse_lit`
(`compiler/ruby/ast/parser.rb:3080-3086`):

```ruby
Token = Struct.new(:type, :value, :line, :column)

_, fields = parse_comma_seq(:CHAR, '{', '}') do
  name_tok = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
  consume(:CHAR, ':'); v = parse_expression
  [[T.must(name_tok).value, v], name_tok]
end
lit = AST::StructLit.new(type_token, name, fields.map(&:first).to_h, storage, type_args)
```

This is the exact source of the unreadable nested CLEAR cast reported during
the parser translation. The lexer is allowed to store strings, numbers, and
nil in different token kinds; the erosion occurs because the token kind/value
correlation is absent from the boundary. The correct recommendation is a
checked textual-token accessor or a typed token variant, not a claim that
`Token#value` always returns `String`.

**Finding.** Report T1 only when the producer flow proves a strict subtype of
the declared result. “All resolved consumers cast the result to the same
subtype” is corroborating evidence, not proof, and must be T2 when producer
flow or call-graph closure is incomplete.

**Metrics.** Lost normalized type facts; union-width increase; unknown/untyped
leaves introduced; number and distance of recovery operations; callers that
recover the same subtype.

**Existing-tool gap.** Type checkers enforce assignability and linters can count
casts, but they do not normally report that one API erased a fact which its
callers systematically reconstruct.

Sorbet will accept a body whose actual result is narrower than its declared
return type because the result is assignable to that type; it does not require
every member of a declared union to be reachable. See Sorbet's
[method-signature](https://sorbet.org/docs/sigs) and
[union-type](https://sorbet.org/docs/union-types) semantics. CodeQL can cheaply
find the Ruby-specific syntactic candidate “all resolved uses flow into
`T.cast(..., B)`,” using its Ruby
[call](https://codeql.github.com/docs/codeql-language-guides/codeql-library-for-ruby/)
and [data-flow](https://codeql.github.com/docs/codeql-language-guides/analyzing-data-flow-in-ruby/)
libraries, but that is not one query that runs unchanged across languages and
it is not proof of the producer's result type. The official Ruby library docs
describe Ruby AST/call/data-flow extraction and custom library modeling, but I
found no built-in Sorbet signature model; absent such a model, `sig` and
`T.cast` must be recognized as Sorbet DSL calls by the custom query/model.
FactMine already normalizes Sorbet declarations, so it is the better product
foundation; a CodeQL query is useful as a Ruby audit/oracle.

**CodeQL effort.** A Ruby-only candidate query is small-to-medium rather than
trivial: approximately 150-300 QL LoC plus 100-200 LoC of Sorbet modeling and
query tests. It can require that every resolved use of a method result flows
immediately into the same `T.cast` target and that no other resolved use
escapes. Each additional CodeQL language needs its own declaration, cast/
assertion, call-target, and type-relation adapter/query work; only the concept
and result schema are shared. Proving the producer's narrower return flow is a
larger analysis and should reuse FactMine's normalized types/CFG/DFG instead of
being rebuilt independently in every CodeQL language library.

**Products.** FactMine emits normalized producer/consumer type and recovery
facts; Decomplex ranks local recovery debt; Espalier aggregates erosion across
owner boundaries; Lineage displays paths.

**Estimated implementation.** FactMine 300-450 LoC; Decomplex 140-220 LoC;
Espalier/reporting/oracles 160-280 LoC; **total 600-950 LoC**.

**Risk profile.** Implementation bug risk: **medium-high**, because generic
instantiation, aliases, and overloads can make declaration comparison subtle.
False positives: **low** for an immediate cast to the same repeated subtype,
**medium** for distant consumers. False negatives: **medium-high** when dynamic
dispatch or reflection hides the recovery operation.

### FR-T1-02: Result-Shape Correlation Loss

**Problem.** A producer returns a fixed tuple, pair, or typed sequence but the
boundary exposes only an untyped array or one-or-many union. Consumers rely on
positional relationships that no longer exist in the declared type. This
identified the parser-rule capture boundary. The current generic
`parse_comma_seq` signature preserves its element type and is not itself an
example of this defect.

**Exact Parser trigger.** The parser-rule DSL knows which action produced each
capture, but `process_pattern` collapses every position into
`T::Array[PatternCapture]`; the positional consumers in
`dispatch_stmt_pattern_action` then use `args[0]` and `args[1]` without a
correlated tuple contract (`compiler/ruby/ast/parser.rb:52,715-749` and
`:385-393`):

```ruby
PatternCapture = T.type_alias do
  T.nilable(T.any(AST::Node, Type, String, Symbol, Integer, Float, T::Boolean))
end

sig { params(pattern: Pattern).returns(T::Array[PatternCapture]) }
def process_pattern(pattern)
  captures = T.let([], T::Array[PatternCapture])
  # each PatternStep action determines the real type appended here
  captures
end

sig { params(action: Symbol, token: Lexer::Token, args: T::Array[PatternCapture]).returns(AST::Node) }
def dispatch_stmt_pattern_action(action, token, args)
  case action
  when :build_assert then AST::Assert.new(token, args[0], args[1])
  # ...
  end
end
```

**Finding.** The stable relationship is between `ParserRule#pattern` and the
capture positions it produces, but the boundary retains only “array of any
capture variant.” `parse_comma_seq` itself is no longer the defect: its current
generic signature preserves `[Lexer::Token, T::Array[Elem]]`. The requested
metric must therefore identify correlation lost by the rule/capture boundary,
not flag generic sequence helpers indiscriminately.

**Metrics.** Stable arity; per-slot inferred type stability; correlated
destructuring count; downstream slot casts; one-or-many normalization count;
collection nesting introduced at a boundary.

**Existing-tool gap.** Tuple-aware type checkers can reject a bad access when a
tuple is declared. They do not generally infer and rank the boundary where a
stable tuple relationship was unnecessarily converted into a generic array.

**Products.** FactMine owns tuple/sequence and destructuring facts; Decomplex
reports shape erasure and repeated normalization; Espalier aggregates erased
shapes used across multiple phases.

**Estimated implementation.** FactMine 280-450 LoC; Decomplex 150-230 LoC;
Espalier/oracles 140-220 LoC; **total 570-900 LoC**.

**Risk profile.** Implementation bug risk: **medium**. False positives:
**low-medium** because variadic arrays can legitimately have stable examples.
Require multiple compatible producers or an explicit fixed-arity return to
reach T1. False negatives: **medium** for values constructed through mutation.

### FR-T1-03: Locally Redundant Optional Collection

**Problem.** A nilable collection is immediately normalized to an empty
collection and nil is never distinguished afterward. The API encodes two
states with identical semantics. This identified suspicious optional arrays in
the parser and annotator.

**Exact Parser trigger.** `ClearParser#parse_union_def` constructs a normal
array, then converts the empty case to nil immediately before constructing the
AST (`compiler/ruby/ast/parser.rb:1530-1532`):

```ruby
methods = T.let(nil, T.nilable(T::Array[AST::UnionMethodRequirement]))
methods = method_reqs unless method_reqs.empty?
AST::UnionDef.new(tok, name, variants, visibility, type_params, methods)
```

**Exact Annotator corroboration.** `comptime_is_a_type_param_refinement`
returns a nilable untyped array even though its success value is always a
two-slot `[Symbol, Type]` pair (`compiler/ruby/annotator/domains/control_flow.rb:393-414`):

```ruby
sig { params(condition: AST::Node).returns(T.nilable(T::Array[T.untyped])) }
def comptime_is_a_type_param_refinement(condition)
  # ...
  narrowed_type ? [type_param, narrowed_type] : nil
end
```

**Finding.** The parser site is a review candidate, not yet proof that nil and
empty are equivalent: downstream `AST::UnionDef#methods` consumers may attach
meaning to nil. The annotator site primarily proves result-shape erosion, not
redundant optional collection. Promote a finding to T1 only after complete
flow proves that nil and empty converge before every observable use.

**Metrics.** Nil-distinguishing branch count; convergence point; operations
performed before convergence; nil/empty return equivalence; number of callers
that pass nil versus empty.

**Existing-tool gap.** Nullability checkers track whether nil is legal. They do
not ordinarily prove that nil and an empty collection are observationally
equivalent throughout an API and recommend removing one state.

**Products.** FactMine supplies normalized types and CFG/DFG convergence;
Nil-kill owns the contradiction and recommendation; Decomplex may use it as
decision-pressure evidence.

**Estimated implementation.** FactMine 180-280 LoC; Nil-kill 180-300 LoC;
oracles/reporting 120-180 LoC; **total 480-760 LoC**.

**Risk profile.** Implementation bug risk: **medium**, especially around
mutation and identity. False positives: **low** only for local closed proofs;
promote whole-program or partial-corpus results to T2. False negatives:
**medium-high** when nil meaning escapes through a call.

### FR-T1-04: Runtime Protocol Domain Mismatch

**Problem.** A method implementing a language/runtime protocol declares a
narrower parameter than the protocol permits and then defensively checks that
same type. This identified the incorrect equality signatures in annotator and
MIR identifiers.

**Exact Annotator trigger.** `AutoSlotId#eql?` narrows its Sorbet input to
`AutoSlotId` and then performs the runtime class guard required by Ruby's hash
equality protocol (`compiler/ruby/annotator/helpers/auto_inference.rb:89-103`):

```ruby
sig { params(other: AutoSlotId).returns(T::Boolean) }
def eql?(other)
  return false unless other.is_a?(AutoSlotId)
  @kind == other.kind &&
    @fn_name == other.fn_name &&
    @index == other.index &&
    @decl_id == other.decl_id
end

alias == eql?
```

**Finding.** Ruby equality accepts arbitrary objects, while the signature says
the class check can never fail. Recommend the normalized protocol input domain.

**Metrics.** Declared-domain versus protocol-domain coverage; guards impossible
under the declaration; legal runtime inputs excluded; override-domain
contravariance.

**Existing-tool gap.** Static override checking catches some nominal interface
violations, but dynamic runtime protocols and the combination of a too-narrow
signature with its now-impossible defensive guard are rarely reported as one
diagnostic.

**Products.** Language adapters emit normalized protocol roles and required
domains in FactMine; Nil-kill reports the contradiction; Decomplex consumes the
impossible guard as decision pressure.

**Estimated implementation.** Ruby protocol adapter 100-170 LoC; shared
FactMine facts 100-160 LoC; Nil-kill/oracles 130-220 LoC; **total 330-550 LoC**.

**Risk profile.** Implementation bug risk: **low-medium** when protocol tables
are explicit. False positives: **low** for built-in protocols. False negatives:
**high** for framework protocols that have not been registered. Each additional
language needs a small, explicit protocol table rather than shared name checks.

### FR-T1-05: Phase Read-Before-Write and Annotation Completeness

**Problem.** A later phase reads an annotation before every path through its
producer phase initializes it. Dynamic AST stamping currently makes this hard
to prove in the annotator.

**Exact Annotator trigger.** `SemanticAnnotator#semantic_index` is optional
during construction/reset, is populated only at the end of `annotate!`, and is
recovered with `T.must` by the compiler frontend
(`compiler/ruby/annotator/annotator.rb:578-623` and
`compiler/ruby/compiler/compiler_frontend.rb:76-85`):

```ruby
@semantic_index = T.let(nil, T.nilable(SemanticIndex))

def annotate!(node)
  # ... body analysis and whole-program phases ...
  @semantic_index = T.let(SemanticIndex.new(
    program: node,
    root_scope: semantic_root_scope,
    function_registry: semantic_function_registry,
    id_index: semantic_id_index_from_body_summaries,
  ), T.nilable(SemanticIndex))
  mark_annotation_complete!(node)
end

body_summaries: T.must(annotator.semantic_index).body_summaries
```

**Finding.** No current read-before-write bug is asserted here: the frontend
calls `annotate!` first. The exact design problem is that phase completion is
represented as a nilable field plus a caller assertion rather than a result
whose type proves completion. A T1 diagnostic requires a reachable read that
bypasses the writer, or a producer exit that omits a required annotation.

**Metrics.** Definite assignment by phase exit; read-before-write paths;
producer coverage; required annotation completeness; bypass edges around the
producer phase.

**Existing-tool gap.** Definite-assignment analysis usually covers declared
locals or fields. It does not infer application phases and prove completeness
for progressively stamped AST annotations across phase objects.

**Products.** FactMine emits normalized annotation accesses, CFG/DFG, and phase
call order; Espalier owns the phase matrix and architecture finding; SlopCop may
later correlate an uncovered producer path but must not rederive the fact.

**Estimated implementation.** FactMine 350-550 LoC; Espalier 220-350 LoC;
SlopCop/Lineage projection and oracles 140-240 LoC; **total 710-1,140 LoC**.

**Risk profile.** Implementation bug risk: **high** because aliasing, dynamic
properties, and callbacks obscure writes. False positives: **low** for a direct
pipeline and definite CFG proof, **medium-high** for inferred phases. False
negatives: **high** around reflective writes unless adapters expose them.

### FR-T1-06: Scoped State Restoration Leak

**Problem.** Code changes mutable mode state temporarily and a reachable exit
can bypass restoration. This directly addresses implicit parser modes.

**Exact Parser trigger.** Both match-expression paths manually toggle
`@suppress_struct_lit` around calls that can raise, with no scoped helper
(`compiler/ruby/ast/parser.rb:2660-2671` and `:2761-2775`):

```ruby
@suppress_struct_lit = true
first_pattern = parse_expression
@suppress_struct_lit = false

# repeated in the same method for each extra pattern
@suppress_struct_lit = true
extra_patterns << parse_expression
@suppress_struct_lit = false
```

**Finding.** The previous invented early return was not present in the parser
and overstated the evidence. The current source has a duplicated unprotected
temporary-state protocol. Parser errors currently abort parsing, so an
exception-only exit is not automatically a user-visible state leak. Report T1
only when CFG proves execution can continue after an un-restored exit;
otherwise report scoped-state risk at T2 and recommend an `ensure`-backed
helper.

**Metrics.** Save/mutate/restore triples; exits between mutation and restore;
exception edges without restoration; nested scope depth; restored field set
versus mutated field set.

**Existing-tool gap.** Resource linters understand registered close/lock
protocols, but arbitrary save/mutate/restore mode protocols are generally
invisible unless a project authors a custom query for each one.

**Products.** FactMine supplies CFG, state reads/writes, and def-use facts;
Decomplex reports restoration leaks; SlopCop can prioritize untested leaking
paths; Lineage displays the path.

**Estimated implementation.** FactMine protocol facts 180-280 LoC; Decomplex
180-280 LoC; SlopCop/SARIF/oracles 120-200 LoC; **total 480-760 LoC**.

**Risk profile.** Implementation bug risk: **medium**. False positives:
**low** for a proven un-restored exit; assignment to an intentionally changed
mode must be distinguished from a saved temporary mode. False negatives:
**medium-high** when restoration occurs in an opaque helper.

### FR-T1-07: Escape-Hatch Containment Failure

**Problem.** An untyped/reflection escape hatch is legitimate at an adapter
boundary but its value propagates into ordinary core logic instead of being
validated and retyped immediately. This identified dynamic token, diagnostic,
and AST-property leakage.

**Exact Parser-boundary trigger.** The shared parser/annotator diagnostic
helper accepts `T.untyped`, uses reflective token detection, casts through a
union containing `Object`, and forwards the result into compiler error/fix
construction (`compiler/ruby/ast/source_error.rb:9,26-48` and `:170-181`):

```ruby
DiagnosticToken = T.type_alias { T.nilable(T.any(Lexer::Token, Struct, Object)) }

sig { params(node_or_token: T.untyped, code_or_message: T.any(String, Symbol), args: String, kwargs: T.untyped).returns(T.noreturn) }
def error!(node_or_token, code_or_message, *args, **kwargs)
  token = diagnostic_token(node_or_token)
  # ...
  raise err_class.new(source_error_token(token), T.unsafe(message), diagnostic_source_code)
end

def diagnostic_token(node_or_token)
  token = node_or_token.respond_to?(:token) ? node_or_token.token : node_or_token
  T.cast(token, DiagnosticToken)
end
```

**Finding.** A value entering through `T.untyped` is widened to a token union
containing `Object`, then reaches error/fix construction through reflection and
`T.unsafe`. Merely counting `T.unsafe` is insufficient; the metric should show
whether the value is contained and normalized at this diagnostic adapter or
propagates onward into typed parser/annotator state.

**Metrics.** Propagation depth; owner boundaries crossed; state/return/call
sinks reached; percentage contained within one method; first recovery or
validation site.

**Existing-tool gap.** Taint/dataflow engines can be configured to follow a
chosen escape hatch. They do not ship an architectural containment metric that
ranks how far loss of type safety spreads from adapters into core owners.

**Products.** Language adapters identify escape-hatch constructs in FactMine;
shared DFG carries normalized unknown provenance; Espalier aggregates boundary
crossings; Decomplex uses local propagation as false-simplicity evidence.

**Estimated implementation.** FactMine 300-480 LoC; Espalier 180-280 LoC;
Decomplex/reporting/oracles 150-250 LoC; **total 630-1,010 LoC**.

**Risk profile.** Implementation bug risk: **high** because this is lightweight
taint analysis with sanitizers. False positives: **low-medium** when the sink is
typed state or a key; false negatives: **high** through unknown calls, aliases,
or metaprogramming.

## T2 Metrics

### FR-T2-01: Record-Shaped Hash Candidate

**Problem.** A stable heterogeneous hash acts as a record whose required keys
and value types are implicit. This identified parser metadata hashes.

**Exact Parser trigger.** The parser declares several heterogeneous hashes
whose keys are a closed schema and whose value union is widened to cover every
key (`compiler/ruby/ast/parser.rb:55-64`):

```ruby
EffectMetadataValue = T.type_alias do
  T.nilable(T.any(Lexer::Token, Integer, T::Boolean))
end
EffectMetadata = T.type_alias { T::Hash[Symbol, EffectMetadataValue] }
ElementCapability = T.type_alias { T::Hash[Symbol, T.nilable(Symbol)] }
WithMatchArmValue = T.type_alias do
  T.nilable(T.any(Symbol, Lexer::Token, AST::RawBody, T::Array[AST::ErrorClause]))
end
WithMatchArm = T.type_alias { T::Hash[Symbol, WithMatchArmValue] }
CapDims = T.type_alias { T::Hash[Symbol, T.nilable(T.any(Symbol, Integer))] }
```

For example, `parse_effects_decl` constructs `EffectMetadata` with stable keys
such as `:start_tok`, `:end_tok`, and `:tight`
(`compiler/ruby/ast/parser.rb:1950-1970`). The exact problem is that the type of
each value depends on its key, but the hash contract forgets that correlation.

**Finding.** Recommend a typed record only after the observed construction and
access sites establish stable required/optional keys. Do not flag ordinary
homogeneous lookup tables.

**Metrics.** Key stability; heterogeneous value-type score; required versus
optional keys; construction/access site count; cross-method and cross-phase
reuse; key typo alternatives.

**Existing-tool gap.** Type systems can validate an explicitly declared record
or shape. General linters do not usually infer a record-design candidate from
stable heterogeneous key flow across several methods and phases.

**Products.** FactMine emits normalized hash-shape and flow facts; Decomplex
ranks record candidates; Espalier reports records shared across phases;
Nil-kill may propose a language-specific typed representation.

**Estimated implementation.** FactMine 220-350 LoC; Decomplex 150-250 LoC;
Espalier/Nil-kill/oracles 180-300 LoC; **total 550-900 LoC**.

**Risk profile.** Implementation bug risk: **medium-high** because hash shape
merging is subtle. False positives: **medium** for option bags and serialization
payloads. False negatives: **high** for hashes built incrementally or via
splats.

### FR-T2-02: Implicit Host Capability Amplification

**Problem.** A mixin or helper is bound to a huge host type even though it uses
only a tiny subset of that host. This identified annotator and MIR mixins whose
real interface is implicit.

**Exact Annotator trigger.** `FunctionAnalysis` explicitly requires the whole
`SemanticAnnotator` ancestor, and its methods bind `self` to that 36-public-
method/11-state-slot host even for bounded operations
(`compiler/ruby/annotator/helpers/function_analysis.rb:5-15` and `:91-100`):

```ruby
module FunctionAnalysis
  extend T::Helpers
  requires_ancestor { SemanticAnnotator }

  sig do
    params(node: RoutineNode, body: RoutineBody,
      declared_return: DeclaredReturn, is_implicit: T::Boolean)
      .returns(T.nilable(Symbol))
  end
  def analyze_routine(node, body, declared_return, is_implicit)
    T.bind(self, SemanticAnnotator) rescue nil
    verify_captures!(node)
    # ... scope, visit, return, diagnostic, and ownership host calls ...
  end
end
```

**Finding.** The original example understated an important fact: this mixin is
not completely undeclared—Sorbet sees `requires_ancestor`. The problem is
capability amplification: the smallest usable contract is still the entire
mutable `SemanticAnnotator`, not the subset needed by a method or operation
family.

**Metrics.** Host public surface divided by capabilities used; hidden self-call
count; host state domains touched; number of modules sharing the universal
host; smallest inferred capability set.

**Existing-tool gap.** Architecture tools report fan-out and dependency cycles,
while cohesion tools measure shared fields. They do not normally infer a
minimal host capability interface for a mixin and compare it with the host's
full exposed surface.

**Products.** Language adapters identify inclusion/extension constructs;
FactMine emits normalized host-capability calls; Espalier owns amplification
and capability-cluster reports; Decomplex consumes extreme ratios for
convergence.

**Estimated implementation.** FactMine 250-400 LoC; Espalier 220-350 LoC;
Decomplex/oracles/reporting 140-220 LoC; **total 610-970 LoC**.

**Risk profile.** Implementation bug risk: **medium**. False positives:
**medium**, because framework mixins deliberately depend on large hosts. False
negatives: **medium-high** for dynamically sent host calls.

### FR-T2-03: Phase Impurity and Service-Locator Pressure

**Problem.** A named phase receives the whole annotator/parser and reaches into
unrelated registries, diagnostics, scopes, and mutable context instead of
having explicit inputs and outputs.

**Exact Annotator trigger.** `WholeProgramSemantics#run_whole_program_semantics!`
is named as a phase but obtains function nodes, body summaries, schema lookup,
diagnostics, root scope, program policy, signatures, and lock ranks through the
full host (`compiler/ruby/annotator/phases/whole_program_semantics.rb:19-81`):

```ruby
def run_whole_program_semantics!
  T.bind(self, SemanticAnnotator)
  fn_nodes = whole_program_fn_nodes
  body_summaries = function_body_summaries
  EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries)
  # ... mutates function plans and capture facts ...
  error_handler = lambda { |node, message|
    error!(node, :EFFECT_INFERENCE_VIOLATION, detail: message)
  }
  root_scope = whole_program_root_scope
  signature_lookup = lambda { |name| root_scope.resolve_entry(name)&.type }
  # ... effects, WITH checks, signature restamping, concurrency checks ...
end
```

**Finding.** The phase's real inputs and outputs are not represented in its
signature. This is architectural pressure, not proof that its coordination is
incorrect; hence T2.

**Metrics.** Host domains touched; mutable services used; explicit input/output
count versus implicit host accesses; transitive host dependence; phase-local
state versus host state.

**Existing-tool gap.** Dependency-injection linters can enforce framework
conventions, but there is no common cross-language metric for inferred phase
purity versus implicit service-locator dependence.

**Products.** FactMine provides calls/state/capability facts; Espalier owns the
phase-purity and service-locator view; Decomplex uses it in coordinator
convergence.

**Estimated implementation.** Mostly shared with FR-T2-02. Incremental
FactMine 100-180 LoC; Espalier 200-320 LoC; reporting/oracles 120-180 LoC;
**incremental total 420-680 LoC**.

**Risk profile.** Implementation bug risk: **medium**. False positives:
**medium**, because orchestration phases may legitimately coordinate services.
False negatives: **medium** where dependencies are passed through generic
contexts.

### FR-T2-04: Annotation Multi-Writer and Phase Bypass

**Problem.** Multiple phases write the same annotation or a helper writes it
outside the intended producer phase. The update may be a legitimate refinement
or an accidental second source of truth.

**Exact Annotator trigger.** `matched_signature` is stamped by multiple
resolution paths and read by later body analysis:

```ruby
# compiler/ruby/annotator/phases/expression_domains.rb:141-145
node.matched_stdlib_def = method_def
node.matched_signature = method_def if node.respond_to?(:matched_signature=)

# compiler/ruby/annotator/helpers/function_analysis.rb:481-487
verify_function_signature!(node, substituted, args)
T.unsafe(node).matched_signature = substituted if node.respond_to?(:matched_signature=)
# ... or ...
T.unsafe(node).matched_signature = signature if node.respond_to?(:matched_signature=)

# compiler/ruby/annotator/phases/body_analysis.rb:473-481
sig = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
```

**Finding.** These writers may be mutually exclusive and therefore are not,
by themselves, a bug. The exact missing capability is an ownership/refinement
matrix able to prove whether writers overlap, whether one intentionally refines
another, and whether any reader bypasses all valid writers.

**Metrics.** Writers per annotation; writer phase ordering; overwrite without
read; divergent value provenance; helper writes outside owner phase; final
writer stability.

**Existing-tool gap.** Dataflow tools can enumerate writes, but they do not
normally assign semantic ownership to inferred phases or distinguish declared
refinement from an accidental second writer.

**Products.** FactMine emits normalized annotation writes and phase identity;
Espalier owns the annotation-ownership matrix; Decomplex treats unexplained
multi-writer state as decision/state pressure.

**Estimated implementation.** Mostly shared with FR-T1-05. Incremental
FactMine 100-160 LoC; Espalier 160-260 LoC; Decomplex/oracles 100-170 LoC;
**incremental total 360-590 LoC**.

**Risk profile.** Implementation bug risk: **medium-high** around aliases.
False positives: **medium-high** because progressive refinement is common.
False negatives: **high** for reflective setters.

### FR-T2-05: Decision/Application Fusion

**Problem.** A visitor or coordinator resolves a semantic decision, validates
it, emits diagnostics, mutates nodes, and updates registries in one method.
Traditional complexity metrics count branches but do not identify this role
mixture.

**Exact Annotator trigger.** `FunctionAnalysis#resolve_call`
(`compiler/ruby/annotator/helpers/function_analysis.rb:396-530`) performs name
lookup, typo diagnostics, intrinsic/user/fn-variable dispatch, extern-effect
recording, generic substitution, argument verification, annotation stamping,
and result-type rewriting in one method. A minimal exact slice is:

```ruby
scope = lookup_scope_for(func_name)
unless scope
  emit_typo_suggestion!(node.token, func_name, function_node_map.keys,
    "Undefined function '#{func_name}'", "closest declared function")
  return
end

# ... choose intrinsic, static function, generic function, or fn variable ...
substituted = substitute_type_params(signature, subst)
verify_function_signature!(node, substituted, args)
T.unsafe(node).matched_signature = substituted if node.respond_to?(:matched_signature=)
stamp_type!(node, substituted.return_type)

call_type = node.full_type!(context: "function call result")
if call_type.respond_to?(:error_union?) && call_type.error_union?
  T.unsafe(node).error_union_type = call_type if node.respond_to?(:error_union_type=)
  stamp_type!(node, call_type.success_type)
end
```

**Finding.** One resolution decision drives diagnostics, effects, several AST
annotations, and type mutation. Recommend producing and then applying a typed
call-resolution decision; do not recommend merely extracting private methods.

**Metrics.** Semantic role count; mutation-target count; diagnostic emissions;
registry/state domains written; decision value fan-out; resolve/validate/apply
stage separation.

**Existing-tool gap.** Cyclomatic complexity, ABC, and LCOM measure structural
size or cohesion. They do not classify the semantic fusion of resolution,
validation, diagnostics, registry updates, and AST mutation.

**Products.** FactMine supplies calls, state writes, return origins, and
diagnostic facts; Decomplex owns local fusion; Espalier aggregates fused
coordinators by owner and phase.

**Estimated implementation.** FactMine 180-300 LoC; Decomplex 200-320 LoC;
Espalier/oracles 140-230 LoC; **total 520-850 LoC**.

**Risk profile.** Implementation bug risk: **medium-high** because call roles
need semantic classification. False positives: **medium** for intentionally
small transactions. False negatives: **high** when mutations occur in helpers.

### FR-T2-06: Declared Type-Pressure Convergence

**Problem.** Type shape itself drives complexity, but current Decomplex fat
union analysis focuses on dispatch behavior rather than normalized declaration
pressure. Parser and annotator hotspots combine wide unions, nilability, casts,
and branch/state pressure.

**Exact Parser trigger.** The parser's rule boundary combines a seven-variant
union plus nilability with positional dispatch and recovery operations
(`compiler/ruby/ast/parser.rb:51-54`, `:385-388`, and `:715-749`):

```ruby
PatternCapture = T.type_alias do
  T.nilable(T.any(AST::Node, Type, String, Symbol, Integer, Float, T::Boolean))
end

sig do
  params(action: Symbol, token: Lexer::Token,
    args: T::Array[PatternCapture]).returns(AST::Node)
end
def dispatch_stmt_pattern_action(action, token, args)
  case action
  when :build_assert then AST::Assert.new(token, args[0], args[1])
  # ...
  end
end
```

**Exact Annotator corroboration.** The successful result of
`comptime_is_a_type_param_refinement` is a fixed `[Symbol, Type]`, but the
declaration is `T.nilable(T::Array[T.untyped])` and its caller casts both slots
(`compiler/ruby/annotator/domains/control_flow.rb:393-414`).

**Finding.** Report only when union width, unknown leaves, casts, positional
assumptions, and decision/state pressure converge. A wide closed union alone is
not a smell.

**Metrics.** Union and nested-union width; untyped leaves; collection nesting;
cast/assertion count; variant branches; convergence score with existing
Decomplex detectors.

**Existing-tool gap.** Type checkers understand union legality and complexity
tools understand branches, but neither normally ranks the convergence of type
imprecision with state, control-flow, and cast pressure.

**Products.** FactMine emits declaration-pressure facts from normalized
`TypeExpr`; Decomplex owns the convergence section; Espalier may aggregate
pressure crossing owner boundaries.

**Estimated implementation.** FactMine 180-300 LoC; Decomplex 180-280 LoC;
Espalier/oracles 100-170 LoC; **total 460-750 LoC**.

**Risk profile.** Implementation bug risk: **low-medium** once types are
normalized. False positives: **medium** because some closed unions are good
design. False negatives: **medium** where declarations are absent or untyped.

### FR-T2-07: Alias Adoption Drift

**Problem.** A domain alias exists, but equivalent raw unions or collections
continue to be repeated across nearby APIs. This identified annotator aliases
that should already have been reused.

**Exact Annotator trigger.** `GenericAnalysis` declares a domain alias, while
three lifetime helpers repeat the same normalized union
(`compiler/ruby/annotator/helpers/generic_analysis.rb:21` and
`compiler/ruby/annotator/domains/lifetimes.rb:886-900,1128-1129`):

```ruby
# helpers/generic_analysis.rb
DeclarationNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }

# domains/lifetimes.rb
sig { params(decl_node: T.any(AST::VarDecl, AST::BindExpr)).void }
def stamp_bg_handle_lifetime!(decl_node)
  # ...
end

sig { params(decl_node: T.any(AST::VarDecl, AST::BindExpr)).void }
def stamp_init_contents_heap!(decl_node)
  # ...
end

sig do
  params(node: T.any(AST::VarDecl, AST::BindExpr)).returns(T.nilable(Symbol))
end
def set_cleanup_alloc!(node)
  # ...
end
```

**Finding.** The signatures are structurally equivalent to `DeclarationNode`
but bypass the domain name.

**Metrics.** Normalized type-expression equivalence; existing alias matches;
raw repetitions; owner/directory distance; inconsistent partial variants.

**Existing-tool gap.** Duplicate-code tools compare implementation syntax and
type checkers expand aliases for compatibility. They rarely report semantic
type-expression duplication that bypasses an already available domain name.

**Products.** FactMine owns alias expansion and normalized equality; Nil-kill
emits adoption actions; Decomplex treats repeated raw shapes as missing-domain
abstraction evidence.

**Estimated implementation.** FactMine 100-180 LoC; Nil-kill 130-220 LoC;
Decomplex/oracles 90-150 LoC; **total 320-550 LoC**.

**Risk profile.** Implementation bug risk: **low-medium**. False positives:
**medium**, because a local spelling may intentionally avoid coupling to a
public alias. False negatives: **medium** for aliases involving generics or
subtyping rather than exact normalized equality.

## T3 Metrics

### FR-T3-01: Union Role Incoherence

**Problem.** A union combines values that participate in unrelated workflows,
suggesting several result types or a tagged state machine rather than one
domain sum.

**Exact Parser trigger.** `PatternCapture` combines AST nodes, types, token
text, symbols, numeric literals, booleans, and absence because one pattern DSL
array carries the outputs of every action (`compiler/ruby/ast/parser.rb:51-54`
and `:740-749`):

```ruby
PatternCapture = T.type_alias do
  T.nilable(T.any(AST::Node, Type, String, Symbol, Integer, Float, T::Boolean))
end

sig { params(item: Symbol).returns(PatternCapture) }
def run_action(item)
  return T.must(consume(item)).value if item == item.upcase
  return parse_expression if item == :expression
  return parse_expression(1) if item == :pipe_expression
  return parse_type_annotation if item == :type_annotation
  error!(current, :PARSER_EXPECTED, expected: "known pattern action", got: item.to_s,
    type: current.type, line: current.line)
end
```

**Finding.** This exact union has weak shared behavior because it represents
several capture roles rather than one semantic sum. Recommend review or a
typed capture/result family, never an automatic split.

**Metrics.** Variant behavioral clusters; shared member/call ratio; dispatch
destination divergence; variant-specific state domains; unrelated return
roles.

**Existing-tool gap.** Exhaustiveness and union-width checks do not determine
whether variants form one coherent domain. This proposal clusters their actual
behavior, which is not a standard shipped metric.

**Products.** FactMine supplies normalized types and per-branch calls/state;
Decomplex owns role-incoherence candidates; Espalier may show destination
owner clusters.

**Estimated implementation.** FactMine 180-300 LoC; Decomplex 220-360 LoC;
Espalier/oracles 120-220 LoC; **total 520-880 LoC**.

**Risk profile.** Implementation bug risk: **high** because behavioral
clustering is heuristic. False positives: **high** for legitimate sum types and
visitors. False negatives: **medium-high** when behavior is delegated.

### FR-T3-02: Mode State-Space Explosion

**Problem.** Several booleans or enum flags create a large implicit parser or
annotator state machine whose valid combinations are undocumented.

**Exact Parser trigger.** `ClearParser` combines process-global mode defaults,
an instance language-mode choice, and a temporary parse-disambiguation flag
(`compiler/ruby/ast/parser.rb:71-72,100-119,126-159`):

```ruby
@gradual_mode = T.let(false, T.nilable(T::Boolean))
@ownership_mode = T.let(:default, T.nilable(Symbol))

def initialize(tokens, source_code = "", gradual: nil)
  # ...
  @suppress_struct_lit = T.let(false, T::Boolean)
  @gradual = T.let(gradual.nil? ? self.class.gradual_mode : gradual, T::Boolean)
end

program.language_mode = @gradual ? :easy : self.class.ownership_mode
```

`@suppress_struct_lit` is then toggled manually in both match parsers. These
states do not all form one coherent state machine, which is exactly why a T3
metric must first infer co-use and reachable combinations instead of simply
multiplying every field's cardinality.

**Finding.** Rank owners by reachable mode combinations and by branches that
depend on combinations of independently written flags.

**Metrics.** Reachable flag combinations; combination coverage; writers per
flag; pairwise co-use; invalid/unobserved states; transitions without named
operations.

**Existing-tool gap.** Model checkers can explore a state machine after one has
been specified. Conventional linters do not infer a bounded state machine from
ordinary flags and rank undocumented or untested combinations.

**Products.** FactMine emits state writes, branch predicates, and CFG
transitions; Decomplex owns local mode pressure; Espalier aggregates owner
state-machine pressure; SlopCop may show untested combinations.

**Estimated implementation.** FactMine 220-350 LoC; Decomplex 220-350 LoC;
Espalier/SlopCop/oracles 180-300 LoC; **total 620-1,000 LoC**.

**Risk profile.** Implementation bug risk: **high** due to path explosion.
False positives: **high**, because independent flags can be legitimate. False
negatives: **high** unless bounded symbolic exploration or good transition
summaries are used.

### FR-T3-03: Capability Cohesion and Mixin Fragmentation

**Problem.** Methods grouped in one module or helper use unrelated host
capability clusters, suggesting the module is an organizational bucket rather
than one abstraction.

**Exact Annotator trigger.** `PipeAnalysis` contains ordinary pipeline
dispatch, window time parsing, scope/type stamping, sharded-access tree
walking, ownership mutation, and concurrent option validation in one host
mixin. Representative exact methods are
`visit_Smooth` (`compiler/ruby/annotator/helpers/pipe_analysis.rb:65-89`),
`parse_batch_window_time_ns` (`:419-425`), `walk_for_sharded_access`
(`:1269-1276`), and `analyze_concurrent_op` (`:1424-1468`):

```ruby
def visit_Smooth(node)
  T.bind(self, SemanticAnnotator) rescue nil
  with_smooth_context do
    visit(node.left)
    # ...
  end
end

def parse_batch_window_time_ns(str)
  T.bind(self, SemanticAnnotator) rescue nil
  m = BATCH_WINDOW_TIME_RE.match(str)
  return nil unless m
  (m[1].to_f * T.must(BATCH_WINDOW_TIME_NS[T.must(m[2])])).to_i
end

def analyze_concurrent_op(node)
  T.bind(self, SemanticAnnotator) rescue nil
  # ...
end
```

**Finding.** The source justifies measuring capability components; it does not
prove these methods belong in separate modules. This extends ordinary LCOM to
the host services and state implicitly borrowed by a mixin.

**Metrics.** Capability-based connected components; shared host calls/state;
bridge methods; component fragmentation; inferred minimal module partition.

**Existing-tool gap.** Existing LCOM variants use fields or direct calls. They
do not generally compute cohesion over capabilities implicitly borrowed from a
mixin host.

**Products.** FactMine emits host capability calls; Espalier owns architectural
capability cohesion; Decomplex may add the finding to convergence rather than
duplicate the metric.

**Estimated implementation.** Mostly shared with FR-T2-02. Incremental
Espalier 180-300 LoC; Decomplex/reporting/oracles 100-180 LoC;
**incremental total 280-480 LoC**.

**Risk profile.** Implementation bug risk: **medium**. False positives:
**high** for intentional façade or utility modules. False negatives:
**medium-high** through delegation and dynamic calls.

### FR-T3-04: Decision-Record Opportunity

**Problem.** A derived value is used to stamp multiple fields, choose ownership
or behavior, and emit diagnostics, but the decision has no named immutable
representation. The metric suggests where a decision record might remove
repeated inference.

**Exact Annotator trigger.** The direct-call branch in
`FunctionAnalysis#resolve_call` derives `signature`/`substituted` and uses that
decision to verify arguments, stamp `generic_type_args`, `matched_signature`,
the main type, `error_union_type`, extern effects, allocator use, and function
context (`compiler/ruby/annotator/helpers/function_analysis.rb:428-507`):

```ruby
substituted = substitute_type_params(signature, subst)
verify_function_signature!(node, substituted, args)
T.unsafe(node).matched_signature = substituted if node.respond_to?(:matched_signature=)
stamp_type!(node, substituted.return_type)

call_type = node.full_type!(context: "function call result")
if call_type.respond_to?(:error_union?) && call_type.error_union?
  T.unsafe(node).error_union_type = call_type if node.respond_to?(:error_union_type=)
  stamp_type!(node, call_type.success_type)
end
```

**Finding.** Review whether a typed `CallResolutionDecision` should capture
those outputs before application. The file already contains smaller records
such as `CallSignatureSite` and `CallArgumentFacts`, so this request is to
complete an existing direction, not introduce record objects indiscriminately.

**Metrics.** Derived-value semantic fan-out; number of fields/registries/
diagnostics affected; repeated recomputation in later phases; decision inputs
re-read after application.

**Existing-tool gap.** Data-clump and long-method smells do not identify a
semantic decision that should become an immutable result because the same
derived fact drives several downstream effects.

**Products.** FactMine supplies def-use and semantic sink facts; Decomplex owns
local opportunity ranking; Espalier aggregates repeated decision derivation
across phases.

**Estimated implementation.** FactMine 160-260 LoC; Decomplex 180-300 LoC;
Espalier/oracles 120-200 LoC; **total 460-760 LoC**.

**Risk profile.** Implementation bug risk: **medium-high**. False positives:
**high**, because a short transactional method may already be clearer than a
record. False negatives: **high** when applications occur through helpers.

### FR-T3-05: Partial-Corpus State Confidence

**Problem.** A state field appears unread when analyzing a subsystem, but its
consumer lives outside the selected files. Calling it dead state overstates
the proof and produced misleading parser/annotator/MIR findings.

**Exact Annotator trigger.** The annotator-only corpus writes and exposes
`@semantic_index`, but its concrete readers are outside that corpus in the
compiler frontend and module importer
(`compiler/ruby/annotator/annotator.rb:213-214,617-623`,
`compiler/ruby/compiler/compiler_frontend.rb:81-85`, and
`compiler/ruby/compiler/module_importer.rb:189-197`):

```ruby
# annotator/annotator.rb
sig { returns(T.nilable(SemanticIndex)) }
attr_reader :semantic_index

@semantic_index = T.let(SemanticIndex.new(
  program: node,
  root_scope: semantic_root_scope,
  function_registry: semantic_function_registry,
  id_index: semantic_id_index_from_body_summaries,
), T.nilable(SemanticIndex))

# compiler/compiler_frontend.rb (outside the analyzed annotator corpus)
body_summaries: T.must(annotator.semantic_index).body_summaries
```

**Finding.** Report `unread_in_corpus`, not `dead_state`, unless the input is a
declared closed world or whole-project symbol evidence proves no readers.

**Metrics.** Corpus closure; public/accessor exposure; unresolved external
calls; analyzed caller coverage; confidence downgrade reason.

**Existing-tool gap.** Whole-program analyzers may know whether their world is
closed, but partial-directory smell reports commonly present absence of a read
as a finding without making corpus closure and unresolved external edges part
of the result's confidence model.

**Products.** FactMine emits public accessor/export facts and corpus metadata;
Decomplex owns state-finding confidence; Espalier supplies project-wide readers
when available.

**Estimated implementation.** FactMine 100-180 LoC; Decomplex 100-180 LoC;
Espalier/oracles 80-140 LoC; **total 280-500 LoC**.

**Risk profile.** Implementation bug risk: **low-medium**. False positives:
**low** because this downgrades claims rather than adding them. False negatives:
**high** for reflective consumers; those should lower confidence further.

## Shared Foundations

The feature estimates overlap around four foundational workstreams.

### 1. Stable binding and place identity

FactMine currently needs stable lexical binding/place IDs throughout local
flow, CFG, and DFG facts. Bare variable spelling cannot distinguish identical
block parameter names in independent scopes. This is necessary for reliable
shape flow, restoration protocols, and derived-value fan-out.

- **Estimated work:** 500-900 LoC plus 40-100 LoC per language adapter.
- **Risk:** high implementation risk; low user-facing FP once correct.

### 2. Normalized declaration-pressure facts

Extend normalized `TypeExpr` evidence with union width, nested width, unknown
leaves, collection depth, nilable-collection shape, alias identity, and
boundary type deltas.

- **Estimated work:** 350-600 LoC shared; little per-language work after type
  parsing is available.
- **Risk:** medium implementation risk, mostly alias/generic normalization.

### 3. Phase, annotation, and host-capability facts

Language adapters identify phase declarations/invocations, property/annotation
access, and mixin/trait inclusion. Shared FactMine facts expose only normalized
phase IDs, annotation IDs, calls, and accesses.

- **Estimated work:** 600-1,000 LoC for Ruby proof plus shared schema; 60-140
  LoC per additional language with comparable constructs.
- **Risk:** high, because inferred phase identity is inherently contextual.

### 4. Closed-world and provenance metadata

Every state/type/phase finding should know whether the corpus is closed, which
fact producer supplied the evidence, and which unresolved edges weaken the
proof.

- **Estimated work:** 200-350 LoC across FactMine, Decomplex, Espalier, and
  SARIF projection.
- **Risk:** low-medium; mostly schema compatibility and reporting.

## Recommended Delivery Order

1. Add stable binding/place IDs and closed-world/provenance metadata.
2. Add normalized declaration-pressure and boundary-recovery facts.
3. Implement the currently evidenced T1 contracts—FR-T1-01, FR-T1-02, and
   FR-T1-04—using exact FactMine profile oracles. Keep FR-T1-03 at review
   confidence until nil/empty equivalence can be proved over a closed corpus.
4. Add phase/annotation/host-capability facts.
5. Implement FR-T1-05 and FR-T1-07 proof paths. Emit FR-T1-06 as T1 only for a
   proven continuing un-restored exit; otherwise surface it with the T2 scoped-
   state risk described above.
6. Implement T2 metrics as consumers of the same facts, prioritizing host
   amplification, phase impurity, and multi-writer annotations.
7. Add T3 metrics only after representative parser, annotator, and non-compiler
   corpora establish useful thresholds.

For every new source-language example, prefer FactMine's integration/profile
oracle path over embedding language snippets in low-level Rust tests. Unit
tests should operate on normalized fact objects when the parser itself is not
under test.

## Aggregate Work Estimate

Implemented independently, the feature ranges total roughly 9,000-15,000 LoC.
With the shared foundations and reused reporting/oracle infrastructure, the
more realistic program estimate is:

| Work | Estimated changed LoC |
|---|---:|
| Shared foundations | 1,650-2,850 |
| T1 consumers and reports | 1,800-2,900 |
| T2 consumers and reports | 1,500-2,500 |
| T3 consumers and reports | 1,100-1,900 |
| **Total** | **6,050-10,150** |

This is a multi-gem feature program, not one Decomplex detector. The highest
return first slice is boundary type erosion plus recovery debt: it directly
identifies the unreadable casts that blocked parser translation and provides
facts reused by optionality, alias, shape, and architectural propagation
metrics.
