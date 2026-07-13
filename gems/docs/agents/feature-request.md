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

## T1 Metrics

### FR-T1-01: Boundary Type Erosion and Recovery Debt

**Problem.** A helper receives or constructs a value with a precise shape, but
its declared output erases that shape. Callers immediately recover the lost
fact with a cast, assertion, destructuring assumption, or dynamic check. This
identified the parser's broad token-value and generic sequence boundaries.

```ruby
sig { params(token: Token).returns(T.any(String, Integer)) }
def identifier_value(token)
  token.value
end

sig { params(token: Token).returns(Symbol) }
def parse_name(token)
  T.cast(identifier_value(token), String).to_sym
end
```

**Finding.** `identifier_value` introduces a wider type than its consumer can
accept, and `parse_name` recovers `String` immediately. Recommend a checked
`Token#identifier_value` boundary rather than propagating the broad union.

**Metrics.** Lost normalized type facts; union-width increase; unknown/untyped
leaves introduced; number and distance of recovery operations; callers that
recover the same subtype.

**Existing-tool gap.** Type checkers enforce assignability and linters can count
casts, but they do not normally report that one API erased a fact which its
callers systematically reconstruct.

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
identified generic parser sequence helpers and MIR one-or-many results.

```ruby
sig { returns(T::Array[T.untyped]) }
def parsed_name
  ["name", current_token]
end

name, token = parsed_name
T.cast(name, String).upcase
```

**Finding.** A stable two-slot result is declared as an arbitrary array, and a
consumer immediately assumes the first slot is `String`.

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

```ruby
sig { params(names: T.nilable(T::Array[String])).returns(Integer) }
def name_count(names)
  (names || []).length
end
```

**Finding.** Within the complete method flow, `nil` and `[]` converge before
any observable use. Recommend a non-nil collection parameter with `[]` as the
absence representation.

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

```ruby
sig { params(other: NodeId).returns(T::Boolean) }
def ==(other)
  return false unless other.is_a?(NodeId)

  other.value == value
end
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

```ruby
class EmitPhase
  def run(node)
    emit(node.resolved_type)
  end
end

EmitPhase.new.run(node)
node.resolved_type = resolve(node)
```

**Finding.** `resolved_type` is read before its first reachable write. In a
declared phase pipeline, also report a producer phase that fails to initialize
the annotation on all exits.

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

**Problem.** Code saves mutable mode state, changes it temporarily, and exits a
path before restoring it. This directly addresses implicit parser modes.

```ruby
old = @mode
@mode = :type
return parse_type if ready?
@mode = old
```

**Finding.** The early-return path leaves `@mode` changed. Recommend an `ensure`
or a typed scoped-mode helper.

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

```ruby
def dynamic_name(node)
  T.unsafe(node).name
end

def register(node)
  @table[dynamic_name(node)] = node
end
```

**Finding.** An unsafe value crosses into a registry key without a checked
boundary. Merely counting `T.unsafe` is insufficient; the metric follows the
value to typed or architectural sinks.

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

```ruby
def metadata(token)
  {name: token.value, token: token}
end

metadata(token)[:name].upcase
```

**Finding.** The same fixed keys travel together and are accessed as named
fields. Recommend a typed record only after enough stable evidence exists.

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

```ruby
module NameParsing
  def parse_name
    current_token.value
  end
end

class Parser
  include NameParsing
  # many unrelated public methods and state fields
end
```

**Finding.** `NameParsing` needs one token capability, not the entire `Parser`
surface.

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

```ruby
class ResolvePhase
  def initialize(host)
    @host = host
  end

  def run(node)
    node.type = @host.scope.resolve(node.name)
    @host.errors << node unless node.type
  end
end
```

**Finding.** The phase both resolves through global scope and mutates global
diagnostics, with neither dependency represented in its API.

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

```ruby
class ResolvePhase
  def run(node)
    node.type = resolve(node)
  end
end

class CoercePhase
  def run(node)
    node.type = coerced(node)
  end
end
```

**Finding.** `node.type` has two phase writers. Require an explicit refinement
contract or split raw/resolved/coerced annotations.

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

```ruby
def visit(node)
  type = resolve(node.name)
  @errors << node unless type
  node.type = type
  @registry[node.name] = node
end
```

**Finding.** One decision drives diagnostics plus multiple semantic mutations.
Recommend producing a typed decision record and applying it separately.

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

```ruby
sig { params(value: T.nilable(T.any(String, Integer, Token))).void }
def emit(value)
  return unless value
  puts value.is_a?(Token) ? value.value : value.to_s
end
```

**Finding.** Report when union width/nilability/casts converge with decision,
state, or fan-in pressure. A wide union alone is not enough.

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

```ruby
Declaration = T.type_alias { T.any(VarDecl, BindExpr) }

sig { params(node: T.any(VarDecl, BindExpr)).void }
def validate(node); end
```

**Finding.** The signature is structurally equivalent to `Declaration` but
bypasses the domain name.

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

```ruby
Value = T.type_alias { T.any(String, Token, Diagnostic, Integer) }

def handle(value)
  case value
  when Token then parse(value)
  when Diagnostic then report(value)
  else format(value)
  end
end
```

**Finding.** Variants cluster into unrelated operations with little shared
behavior. Recommend review, never an automatic split.

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

```ruby
@gradual = true
@ownership = false
@suppress_literal = true

parse if @gradual && !@ownership
```

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

```ruby
module Helpers
  def resolve(node); scope.lookup(node.name); end
  def diagnose(node); errors << node; end
  def register(node); registry[node.name] = node; end
end
```

**Finding.** The methods form three capability components with little shared
data or collaboration. This extends ordinary LCOM to implicit host
capabilities.

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

```ruby
type = resolve(node)
node.type = type
node.owned = owned?(type)
errors << node unless valid?(type)
```

**Finding.** One derived value fans out into several semantic outputs. Review
whether a typed `ResolutionDecision` should be constructed and applied.

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

```ruby
class Pass
  attr_reader :facts

  def run
    @facts = build_facts
  end
end

# Read by a frontend file outside the analyzed directory.
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
3. Implement FR-T1-01 through FR-T1-04 using exact FactMine profile oracles.
4. Add phase/annotation/host-capability facts.
5. Implement FR-T1-05 through FR-T1-07.
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
