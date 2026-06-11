# Espalier Report Generation Design

Espalier's primary artifact is the full architectural manifest
(`architecture.yml`). That file is evidence, not judgment. The companion
`report.md` should be a ranked architectural review brief generated from that
evidence so an LLM can spend context interpreting risks instead of mining YAML.

## Separation of Concerns

Espalier should not duplicate the sibling tools:

- NilKill owns type, nilability, union, and hash-record contract evidence.
- Decomplex owns decision pressure, repeated predicates, false simplicity, and
  neglected update/protocol candidates.
- Boobytrap owns churn-weighted defect risk.
- SlopCop owns true uncovered branch gaps ranked by churn and structural
  deviance.

Espalier owns architecture-level synthesis:

- which objects own the most state;
- which state fields are protocol-shaped or lifecycle-sensitive;
- where public API surface, mutable state, and internal-helper evidence suggest
  encapsulation pressure;
- where one owner has multiple disconnected instance-state clusters;
- where manifest-visible owner-to-owner delegations form broad hubs or dense
  webs;
- where those collaboration webs suggest a missing or overloaded mediator,
  context, or role object;
- which methods both mutate state and coordinate many collaborators;
- which methods are conditional delegation hubs;
- where sibling-tool findings converge on an architectural boundary.

## Inputs

The first implementation consumes the normalized manifest only. It may use
source files for method line lookup, but the ranking logic should not require
parsing implementation bodies again.

Required manifest fields:

- `module`, `file`, `type`
- `state[].name`, `state[].type`, `state[].properties`
- `functions[].name`, `functions[].EFFECTS.reads`,
  `functions[].EFFECTS.writes`
- `functions[].DELEGATIONS.always_calls`,
  `functions[].DELEGATIONS.conditionally_calls`
- optional `functions[].quality_metrics`

## Ranked Finding Types

### State Owner Pressure

Ranks modules/classes by state count, method count, total state access, and
delegation count. This finds state bags and phase objects where many unrelated
responsibilities may be sharing one mutable context.

### Encapsulation Pressure

Ranks owners where public method surface overlaps mutable state, public
state-touching methods, public mutators, lifecycle-sensitive fields, broad
fan-out, or Espalier privacy candidates. This is intentionally not just a
method-count metric: pure data carriers and simple reader objects should be
suppressed, while classes such as phase contexts, compiler facades, and mutable
registries should surface when they expose implementation detail through a broad
public API.

### Owner State Cohesion

Ranks class/module-level LCOM-style state fragmentation. Espalier builds a
bipartite graph of methods and instance state slots from direct reads/writes;
disconnected components mean the owner contains multiple state concerns that do
not interact through shared fields.

Internal call propagation is used only as evidence. A method that calls helpers
from more than one state component is reported as an orchestration bridge, but
it does not merge those components. This avoids hiding split owners behind a
single public entrypoint such as `run`, `emit`, or `parse`.

The report suppresses simple data carriers, isolated accessor-only fields,
duplicate owner/file manifest entries, and tiny low-fragmentation cases. Bridge
counts are displayed but capped in the score so parser/emitter-style APIs do not
dominate the ranking merely because many methods route through the same
entrypoints.

### Collaboration Meshes

Ranks manifest-visible owner-to-owner delegation graphs. A hub row means one
owner delegates to many other owners; a dense-cycle row means several owners are
mutually coupled. The graph is conservative: Espalier only creates an edge when
a delegation receiver resolves to another owner present in the manifest.

### Mediator/Reification Candidates

Ranks collaboration meshes where repeated vocabulary and graph shape suggest a
missing role object, or where an existing role object such as a host, context,
server, helper, or builder appears overloaded. These are subjective review
candidates and should not be treated as proof that an extraction is required.

### Coordinator/Mutator Collisions

Ranks methods that both write state and delegate broadly. These are policy and
mechanism collisions: the method is deciding what to do, calling many helpers,
and mutating phase state directly.

### Conditional Delegation Hubs

Ranks methods with high conditional call fan-out. Decomplex can say this is
branchy; Espalier says it is an orchestration boundary that may need reified
operation variants, sub-dispatchers, or a table-driven phase.

### State Lifecycle and Protocol Pressure

Ranks state fields by how many methods read/write them and whether the manifest
records protocol interfaces such as `push`, `pop`, `clear`, `[]=`, `[]`, or
`<<`. These fields often want lifecycle helpers, records, or smaller phase
state objects.

### Privatization Candidates

Ranks public methods that look like same-owner helper/protocol steps: they have
internal callers, no manifest-visible external receiver calls, and evidence
such as state touches, helper-shaped names, internal coordination, or overlapping
quality metrics. These are visibility-tightening review candidates, not automatic
API changes.

### Cross-Tool Overlap

If the manifest contains quality metrics, the report should surface them as
overlap rather than owning their interpretation. A finding with high
architecture pressure plus Decomplex/Boobytrap/SlopCop evidence is higher
priority than either signal alone.

## Report Shape

`report.md` should contain:

1. Project prioritization: the top architectural actions.
2. Run summary: module/function/state counts and manifest/source size ratios.
3. Ranked sections for the finding types above.
4. Exact file/method references where possible.
5. Suggested refactor shape for each finding.

The report should be compact enough to fit in an LLM prompt while keeping links
back to the full manifest and source. The target size is a review brief, not a
second full manifest.

## Non-Goals

- Do not rank coverage gaps directly; SlopCop owns that.
- Do not rank bug-churn directly; Boobytrap owns that.
- Do not rank decision complexity directly; Decomplex owns that.
- Do not claim a finding is a bug. Espalier findings are architecture review
  candidates.
