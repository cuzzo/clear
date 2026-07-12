# Function and State Architecture View

## Status

Proposed design. This view should be implemented only after Espalier graph facts
have stable identities and can be ingested without reconstructing relationships
from SARIF messages.

## Product Decision

Lineage should provide an architecture view centered on one class, module,
function, or state member. It should not attempt to render the repository's
complete function graph.

The primary workflow is:

1. open a source file and select a class or module;
2. see its functions and state members, with architectural pressure highlighted;
3. select one function to see the calls, state effects, and architecture evidence
   directly related to it;
4. select one state member to see every known reader and writer;
5. follow any node back to source or make it the new focus.

This is an explanation and navigation tool. It should answer "why is this unit
architecturally difficult?" rather than merely show that many edges exist.

## Goals

- Make architecturally complex functions visible before the user selects one.
- Explain a function through a bounded caller, callee, delegation, and state
  neighborhood.
- Explain a state member through all known readers and writers.
- Join Espalier structure with Lineage complexity, hazards, history, coverage,
  mutation, and test exposure.
- Keep every graph readable on large repositories through focus and progressive
  disclosure.
- Preserve links to exact source spans and stable logical units.
- Show extraction uncertainty instead of presenting incomplete static analysis
  as complete.

## Non-Goals

- A repository-wide raw call graph.
- A full-program data-flow or alias-analysis proof.
- Runtime object graphs.
- Exact dynamic-dispatch resolution in languages where static facts cannot prove
  a target.
- A replacement for the source view, Architecture Risks queue, or Espalier
  report.
- Automatic claims that a highly connected function is incorrectly designed.

## Entry Points

### Source view

The source outline should add an `Architecture` action for each class/module,
function, and recognized state member. Selecting a function in source may open
the architecture panel with that function already focused.

Architecturally complex functions should receive a small pressure badge in the
outline. Use a compact heat scale rather than an alarm icon:

- no badge: insufficient evidence or ordinary pressure;
- amber ring: elevated pressure;
- orange ring: high pressure;
- red ring: exceptional pressure with at least two independent evidence families.

Hover and keyboard focus must explain the contributing evidence. Color alone
must not carry meaning.

### Architectural Risks

An owner or function in the `Architectural Risks` queue should link to this view
with the relevant node selected and the finding's contributing edges
highlighted.

### Direct route

Use a stable route based on a Lineage logical-unit ID, not a display name:

```text
/architecture/unit/:logical_unit_id
/architecture/state/:state_id
```

Query parameters may select the lens and depth:

```text
?lens=combined&depth=1
?lens=state&state=:current_scope
```

## Class/Module Detail Layout

```text
+-----------------------------------------------------------------------+
| ClearParser                             architecture pressure: High    |
| src/ast/parser.rb                       145 functions / 61 state slots |
+---------------------------+-------------------------------------------+
| Members                   | Focus graph                               |
| Search members...         |                                           |
|                           | callers          selected          callees |
| Functions                 |    [A] --------> [parse] --------> [B]     |
|  ! parse             82   |                     |                     |
|  ! parse_expr        67   |                     v                     |
|    token             12   |             writes @current_scope         |
|                           |                     |                     |
| State                     |                  read by [C]               |
|  ! @current_scope    R9 W4|                                           |
|    @tokens           R7 W1|                                           |
+---------------------------+-------------------------------------------+
| Why this is highlighted | Evidence | Source | Tests | History         |
+-----------------------------------------------------------------------+
```

On narrow screens, the member list becomes a drawer above the graph. The
evidence panel follows the graph rather than covering it.

## Member Inventory

The left member list is the stable overview for the selected owner. It should
be useful even if the graph cannot render.

### Function row

Show:

- name and visibility;
- architectural pressure score and band;
- direct caller and callee counts;
- state members read and written;
- unresolved-call count;
- existing Lineage hazard indicator;
- source link.

Default order is descending architectural pressure. Other sorts are name,
visibility, state writes, fan-in, fan-out, and source order.

### State row

Show:

- member name and declared type when known;
- reader and writer counts;
- public writer count;
- lifecycle/protocol evidence;
- whether it participates in co-update or temporal-ordering pressure;
- source link where a declaration span exists.

Sort state by pressure by default: public writers, total writers, protocol
pressure, then readers.

## Function Focus Graph

Selecting a function produces a bounded one-hop graph. The selected function is
always centered and visually dominant.

### Nodes

- selected function;
- direct known callers;
- direct known callees;
- unresolved/external targets, collapsed by receiver or owner;
- state members directly read or written;
- optionally, directly covering tests when the `Tests` lens is active.

### Edges

| Edge | Direction | Meaning |
| --- | --- | --- |
| `calls` | caller -> callee | Direct statically resolved call |
| `conditional call` | caller -> callee | Call occurs behind a branch or conditional dispatch |
| `delegates` | function -> target | Call through another owner or state-held collaborator |
| `reads` | state -> function | Function consumes the current member value |
| `writes` | function -> state | Function may change the member value |
| `covers` | test -> function | Test exposure evidence reaches the function |

The read/write directions deliberately make state flow visible: values flow
from state into readers and effects flow from writers into state.

### Expansion

Clicking a neighbor makes it the new focus. A separate expand control may add
one more hop, subject to the node budget. Never expand merely by clicking the
background or hovering.

The default node budget is 40. The hard budget is 100. When a neighborhood is
larger:

- show the highest-evidence neighbors individually;
- collapse remaining functions by owner and relationship;
- label the aggregate, for example `+31 low-weight callers`;
- offer a searchable table containing every omitted relationship.

All relationships remain inspectable even when they are not simultaneously
drawn.

## State Focus Graph

Selecting a state member switches the graph to a complete read/write view for
that member.

```text
writers                         state                         readers

[initialize] ----writes----> [@current_scope] ----reads----> [resolve]
[enter_scope] ---writes----->        |          ----reads---> [lookup]
[restore] ------writes------>        +----------reads-------> [emit]
```

### Required behavior

- List every known direct reader and writer, not only a sampled subset.
- Use aggregation in the visual graph when the node budget is exceeded, while
  retaining a complete table below it.
- Distinguish read-only functions, write-only functions, and read/write
  functions.
- Highlight public writers because they enlarge the mutation surface.
- Mark conditional writes separately when FactMine provides path-condition
  evidence.
- Show call paths between writers and readers only on request. Do not imply
  temporal order from a shared state member alone.
- Display the member's declared type, owner/type references, lifecycle
  protocols, parameter origins, and co-update relationships when available.

### Useful questions answered

- Who can mutate this member?
- Which public entry points can reach a writer?
- Which functions depend on its current value?
- Is one function the sole writer?
- Does a state member bridge otherwise unrelated responsibility clusters?
- Which tests cover its writers and readers?
- Did a bug-fix commit commonly change this state and one of its consumers?

## Lenses

Only one primary lens is active at a time so edge types do not become visually
indistinguishable.

| Lens | Visible evidence |
| --- | --- |
| Combined | Calls, delegation, reads, and writes for one-hop neighbors |
| Calls | Callers, callees, conditional calls, unresolved targets |
| State | State reads, writes, lifecycle, and co-update evidence |
| Risk | Only relationships contributing to architectural pressure/findings |
| Tests | Covering tests, test types, mutation evidence, uncovered neighbors |
| History | Change coupling, bug-fix relationships, and recent churn |

The selected node, member list, and source links remain stable when switching
lenses.

## Architectural Function Pressure

Do not equate graph degree with architectural complexity. A dispatcher,
registry, or facade may legitimately have high fan-out. Rank functions using
independent evidence families and show the decomposition.

### Evidence families

1. Collaboration:
   - resolved fan-in and fan-out;
   - cross-owner delegation;
   - number of distinct collaborator owners;
   - cycle participation;
   - conditional delegation.
2. State responsibility:
   - distinct state reads and writes;
   - public mutation;
   - write/read breadth;
   - co-update groups;
   - lifecycle or temporal-ordering evidence.
3. Local implementation pressure:
   - Decomplex cognitive/decision/protocol pressure;
   - expensive-function evidence;
   - broad parameter or type pressure from Nil-kill.
4. Operational risk:
   - churn and bug-fix history;
   - coverage and mutation gaps;
   - test-type gaps;
   - active hazards.

### Calibration

Convert each raw measure to a percentile within comparable functions in the
same language and approximate size bucket. Compute a weighted score from those
percentiles, but cap each evidence family so a single extreme metric cannot
dominate.

Suggested initial family weights:

```text
collaboration             30%
state responsibility      30%
implementation pressure   25%
operational risk          15%
```

Require two evidence families for the red band. A function with only high
fan-out can be amber or orange but not red. Keep the raw components in storage
and return them in the API so every highlight is explainable.

Example explanation:

```text
High architecture pressure (91st percentile)
- writes 7 of the owner's 11 state members
- delegates to 6 distinct owners
- participates in a 4-function call cycle
- has high protocol pressure and sparse integration coverage
```

Thresholds must be evaluated against reviewed examples before becoming quality
gates. The score ranks review targets; it does not assert a defect.

## Data Ownership and Ingestion

### FactMine

FactMine owns language-specific extraction and should emit stable structured
facts for:

- owner, function, and state-member definitions with exact spans;
- function calls and resolved/unresolved targets;
- per-function state reads and writes;
- conditional/path evidence where reliable;
- state type references;
- state protocols, parameter origins, and co-update facts;
- extraction confidence and unresolved reasons.

### Espalier

Espalier owns architecture projection:

- owner and function dependency edges;
- delegation and collaborator resolution;
- cycle membership;
- state ownership and mutation-surface summaries;
- architecture pressure components and review findings.

Espalier's existing `DependencyGraph` already represents owner/function nodes,
internal calls, delegation, owner calls, external calls, edge weights, and
cycles. It also attaches per-function `EFFECTS.reads` and `EFFECTS.writes`.
The production contract must extend that graph with first-class state nodes and
read/write edges rather than forcing Lineage to infer them from labels.

### Lineage

Lineage owns:

- durable logical identity across commits;
- joining graph facts to source, history, coverage, mutations, tests, and
  hazards;
- scoped graph queries and node-budget aggregation;
- pressure presentation and user interaction;
- artifact health and stale-analysis warnings.

Do not parse Espalier's Markdown, DOT, or human-readable SARIF messages to build
the graph. SARIF remains the finding transport. Add a versioned architecture
graph JSON artifact for structured ingestion.

## Stable Identity Requirements

The current `owner#function-name` shape is insufficient for overloads,
same-named nested functions, and moves. Every graph entity needs an analyzer
identity plus an optional matched Lineage logical-unit identity.

```text
owner_id    = hash(language, normalized owner path/name, definition span)
function_id = hash(language, path, owner_id, name, signature, definition span)
state_id    = hash(language, path, owner_id, member name, declaration span)
edge_id     = hash(source_id, target_id, kind, source span, analyzer version)
```

Lineage should reconcile functions to existing logical units during import and
retain aliases when units move or rename. IDs must not rely on display names
alone.

## Architecture Artifact Schema

Use a versioned JSON artifact. A compact conceptual form is:

```json
{
  "schema_version": 1,
  "analyzer": { "name": "espalier", "version": "..." },
  "corpus": { "commit": "...", "root": ".", "complete": true },
  "nodes": [
    {
      "id": "fn:...",
      "kind": "function",
      "owner_id": "owner:...",
      "name": "parse",
      "language": "ruby",
      "path": "src/ast/parser.rb",
      "span": { "start_line": 80, "end_line": 120 },
      "confidence": "high"
    },
    {
      "id": "state:...",
      "kind": "state",
      "owner_id": "owner:...",
      "name": "@current_scope",
      "declared_type": "Scope"
    }
  ],
  "edges": [
    {
      "id": "edge:...",
      "source": "fn:...",
      "target": "state:...",
      "kind": "writes",
      "conditional": false,
      "confidence": "high",
      "spans": [{ "path": "src/ast/parser.rb", "line": 94 }]
    }
  ],
  "pressure": [
    {
      "node_id": "fn:...",
      "score": 82.4,
      "percentile": 0.91,
      "components": {
        "collaboration": 0.87,
        "state": 0.96,
        "implementation": 0.81,
        "operational": 0.54
      }
    }
  ]
}
```

Every edge should retain one or more source evidence spans. A graph without
citations is difficult to trust or debug.

## Lineage Storage

Use normalized tables rather than storing the entire artifact as opaque JSON:

```text
architecture_nodes
  analyzer_node_id, logical_unit_id?, owner_node_id?, kind, name,
  language, path, start_line, end_line, metadata_json, confidence,
  artifact_id

architecture_edges
  edge_id, source_node_id, target_node_id, kind, conditional, weight,
  confidence, metadata_json, artifact_id

architecture_edge_spans
  edge_id, path, start_line, start_column, end_line, end_column

architecture_pressure
  node_id, score, percentile, collaboration, state, implementation,
  operational, explanation_json, artifact_id
```

Index `owner_node_id`, both edge endpoints, `logical_unit_id`, `kind`, and
`path`. Replace one analyzer snapshot transactionally so queries never mix graph
versions.

## API

### Owner inventory

```text
GET /api/architecture/owners/:owner_id
```

Returns owner metadata, functions, state members, pressure components, and
artifact health.

### Function neighborhood

```text
GET /api/architecture/functions/:function_id/neighborhood?lens=combined&depth=1&limit=40
```

Returns selected node, visible nodes/edges, aggregate nodes, total relationship
counts, omitted relationship tables, pressure explanation, and source links.

### State access

```text
GET /api/architecture/state/:state_id/access
```

Returns the complete reader/writer inventory plus a bounded visual graph.

### Node search

```text
GET /api/architecture/search?owner=:owner_id&q=scope
```

Searches functions and state members within the selected owner first, then the
repository.

Responses must include the artifact commit/version and stale status. If the
artifact does not match the viewed commit, show a caution banner and explain
how to regenerate it.

## Rendering

Do not embed a complete Graphviz SVG and attempt to make it the application.
Use structured graph JSON and render the bounded neighborhood in Lineage.

The first implementation can use accessible SVG with a deterministic layered
layout:

- callers on the left;
- selected function or state in the center;
- callees/readers on the right;
- state below the selected function;
- aggregate nodes at the outside edge.

This layout fits the focused graph and is more stable than a force simulation.
It can be generated in Rust or lightweight browser code without a graph
framework. Graphviz remains useful for downloadable SVG/DOT export and as a
layout experiment, but it is not required for the interactive MVP.

Required interaction:

- pan and zoom;
- keyboard navigation between nodes;
- focus/hover details without layout changes;
- relationship filtering;
- source navigation;
- back/forward focus history;
- `Fit` and `Reset` controls;
- copy link to the current focus and lens;
- complete text/table equivalent for accessibility.

## Confidence and Missing Evidence

Use three visible confidence states:

- `high`: exact definition and relationship target resolved;
- `partial`: relationship exists but target or receiver resolution is
  incomplete;
- `unknown`: the analyzer could not determine whether a relationship exists.

Render partial edges dashed and keep unknowns in a separate summary. Never turn
an unresolved call into a fabricated exact target. Never interpret zero readers
or writers as proof of no access when analyzer coverage is stale or incomplete
for the language.

The owner header should say, for example:

```text
Architecture coverage: 92% of functions, 14 unresolved dynamic calls
```

## Performance and Large Codebases

The design scales because graph queries begin from indexed endpoints and return
a bounded neighborhood. It never loads the repository graph into the browser.

- Precompute node degrees, cycles, pressure, and owner membership on import.
- Query the selected node's adjacency lists directly.
- Keep the default response under 40 nodes and 150 edges.
- Paginate the complete relationship tables.
- Cache owner inventories and focused neighborhoods by artifact ID, node ID,
  lens, and limit.
- Return aggregate counts before loading optional second-hop data.
- Never run layout over hidden repository nodes.
- Preserve stable ordering and positions to avoid visual movement between lens
  changes.

## Implementation Sequence

### Phase 0: Validate facts

- Generate an Espalier manifest for representative Ruby, Rust, Zig, and one
  object-oriented non-Ruby repository.
- Measure definition, call-target, and state read/write extraction coverage.
- Manually validate at least 30 functions and 20 state members.
- Do not proceed if state access has unacceptable false positives or silently
  drops common access forms.

### Phase 1: Structured artifact

- Add stable owner/function/state IDs to FactMine/Espalier output.
- Add first-class state nodes and `reads`/`writes` edges.
- Add edge citations, confidence, unresolved reasons, and schema versioning.
- Keep DOT and SARIF as derived outputs.

### Phase 2: Import and API

- Add transactional Lineage tables and indexes.
- Reconcile analyzer functions with Lineage logical units.
- Implement owner inventory, function neighborhood, state access, and search
  endpoints.
- Add artifact freshness and language-quality metadata.

### Phase 3: Member inventory

- Add the class/module member panel to the source view.
- Implement pressure badges, sorting, explanations, and source navigation.
- Link existing Architectural Risks rows to the selected owner/function.

### Phase 4: Focus graph

- Implement the deterministic SVG layout and complete relationship table.
- Add function focus and state focus.
- Add lenses, aggregation, focus history, keyboard access, and export.

### Phase 5: Cross-tool enrichment

- Join Decomplex metrics, hazards, coverage, mutations, test exposure, churn,
  bug history, and change coupling.
- Calibrate pressure bands with reviewed examples.
- Add test and history lenses only after their edge semantics are explicit.

## Testing

### Fact and identity tests

- overloaded and same-named methods receive distinct IDs;
- nested owners and functions resolve correctly;
- rename/move reconciliation retains Lineage history;
- state access forms for every supported trial language;
- self/this/instance-variable/static/member access;
- unresolved dynamic calls retain uncertainty;
- edge evidence spans point to the actual expression.

### Graph tests

- one-hop traversal contains only requested relationships;
- read and write edge directions are correct;
- cycles and self-calls do not recurse indefinitely;
- duplicate evidence aggregates weights without losing citations;
- node-budget aggregation is deterministic and lossless in the table;
- state access returns every known reader and writer;
- an artifact replacement cannot mix old and new edges.

### Scoring tests

- one extreme metric cannot create a red badge;
- two independent evidence families can create a red badge;
- percentile calibration separates languages and size buckets;
- missing analyzer data does not lower a function's apparent pressure;
- score explanations sum to the stored components.

### UI tests

- function and state selection update the route and graph;
- browser back restores the prior focus and lens;
- every graph relationship is also available as text;
- keyboard users can reach, inspect, and follow every visible node;
- stale artifacts display remediation guidance;
- large neighborhoods remain within the hard visual budget;
- links open the correct source line and logical unit.

## Acceptance Criteria

The initial feature is complete when:

- a user can open a class/module and see all recognized functions and state;
- elevated functions are ranked and have evidence-backed explanations;
- selecting a function shows its bounded caller, callee, delegation, read, and
  write neighborhood;
- selecting state shows every known reader and writer in a complete table and
  bounded graph;
- every visible edge links to source evidence;
- graph facts join to existing Lineage source, hazards, complexity, and test
  data;
- incomplete or stale analysis is visibly qualified;
- a class with hundreds of functions remains usable without drawing hundreds
  of nodes at once;
- reviewed fixtures demonstrate that highlights improve architectural target
  selection over sorting by function size or graph degree alone.

## Kill Criteria

Do not ship the graph as a primary Lineage feature if validation shows that:

- state read/write facts are too incomplete to distinguish no access from
  missing analysis;
- most call edges are unresolved in the primary target languages;
- pressure ranking does not outperform simple complexity and churn ranking in
  blinded review;
- users primarily consume the complete relationship table and the visual graph
  does not improve comprehension or navigation.

If only the last condition holds, retain the class member inventory, pressure
badges, and reader/writer tables and omit the graph renderer.
