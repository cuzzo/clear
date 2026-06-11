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
