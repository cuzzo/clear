# Hidden Enum Discovery

## Goal

Hidden enum discovery finds primitive `String`/`Symbol` slots that are really closed domain states:

```ruby
def transition(status)
  case status
  when :pending then :queued
  when :active then :running
  when :archived then :done
  end
end
```

The immediate goal is report-only pressure: identify where a named enum, closed set, or literal-union contract would remove stringly/symbolly decision pressure. Autofix is intentionally out of scope until report quality is proven.

## Why nil-kill Owns Discovery

This is type-pressure evidence, not a generic complexity metric. `nil-kill` already owns:

- Slot inventory: params, returns, fields, ivars, and weak signatures.
- Runtime evidence: method calls, primitive classes, field observations, and call pressure.
- Type-contract reporting and eventual verified rewrite loops.

`Decomplex` should rank the complexity symptom: repeated `case`/`if` decisions around a primitive domain. `Espalier` can add architectural boundary context. `nil-kill` should own the candidate slot, observed/static value set, confidence, blockers, and future rewrite plan.

## Evidence Model

A hidden-enum candidate is keyed by a slot-like origin:

- Method param: owner, method, param name.
- Ivar/field: owner and field name.
- Local-only candidates may be reported only when the local is initialized from or returned to a contract slot.

The first implementation is conservative and uses static evidence as the decisive source:

- `case slot; when :a, :b`
- `slot == :a`, `slot != :a`, `:a == slot`
- Array/set membership checks such as `[:a, :b].include?(slot)`
- Literal assignments/defaults to params, ivars, or locals that flow from a known slot.

Runtime class evidence can support a candidate, but runtime class evidence alone is not enough because the current Ruby tracer records `String`/`Symbol` classes, not the actual primitive values. A later runtime-value sampler can improve confidence, but it must still be bounded and opt-in enough to avoid collecting arbitrary user data.

## Confidence

Confidence is intentionally staged:

- `high`: a contract slot has a small closed static set, enough decision pressure, no open-world blocker, and no dynamic producer found.
- `review`: the value set is useful but the origin story is incomplete, the slot has weak typing, or there is mixed static/dynamic/open-world evidence.
- `suppressed`: no report row because there is no compact closed static set, no contract slot, or the value set is too large.

Small means `2..10` unique values. A single literal may be a constant/default, not an enum. More than ten values usually points to data, not a compact state machine.

## Open-World Blockers

Do not promote a slot as a strong candidate when producers include:

- `ENV`, `ARGV`, file/socket/network reads, JSON/YAML/CSV parsing, CLI/input APIs.
- Interpolation, string concatenation, `to_s`, dynamic symbol conversion, or unbounded external method returns.
- Public parse/diagnostic text where arbitrary strings are expected.

Blocked evidence should be shown on review rows so future tuning can distinguish useful enum candidates from intentionally open contracts.

## Report Shape

The report should include:

- Slot label and source location.
- Primitive kind: `Symbol` or `String`.
- Static values.
- Decision sites and producer sites.
- Runtime support if available.
- Confidence and blockers.
- Suggested next step: define a named enum or literal-union contract, not an automated rewrite.

## Rewrite Later

Autofix should be added only after the report consistently produces high-signal candidates.

Ruby/Sorbet `T::Enum` is invasive because call sites must move from raw `:value` or `"value"` to enum constants and serialization must be explicit. The safer order is:

1. Report-only candidates.
2. Verified local narrowing where the language supports literal unions.
3. Named enum generation only when placement, naming, and boundary serialization are review-approved.

For CLEAR, named enum generation may be easier, but it still needs the same confidence and boundary checks.
