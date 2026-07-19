# Compile-Time Type Measures for CLEAR

Status: proposed design; no compiler implementation yet

Date: 2026-07-19

Primary references:

- [F# units of measure](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/units-of-measure)
- [Rust `uom` design](https://docs.rs/uom/latest/uom/)
- [Julia Unitful type model](https://juliaphysics.github.io/Unitful.jl/stable/types/)
- [Julia Unitful conversion and promotion](https://juliaphysics.github.io/Unitful.jl/stable/conversion/)

Scope: numeric measure syntax, dimensional checking, unit conversion,
measure-generic functions, standard-library migration, STRICT-mode policy,
and zero-cost Zig lowering

## Executive Decision

CLEAR should add compiler-native, erased numeric measures based primarily on
F#'s design:

```clear
delay: Float64|ms| = 10|ms|;
sleep(delay);
sleep(10|ms|);
```

The measure is part of the compile-time type and has no field, wrapper,
allocation, reference count, or run-time tag. `Float64|ms|` has exactly the
same Zig representation and ABI as `Float64`. The compiler uses the measure to
check arithmetic and API boundaries, then erases it after producing any
required numeric conversion.

CLEAR should improve on F# in one important way: distinguish a physical
dimension such as `Time` from concrete units such as `s` and `ms`. F# treats
unit symbols primarily as independent type-level measures and leaves scaled
conversions to values and functions. CLEAR can retain F#'s simple erased
algebra while giving standard and user-defined units exact rational scale
relationships.

The initial language should support:

- numeric types annotated with `|measure expression|`;
- measured numeric literals such as `10|ms|`;
- base dimensions, units, derived dimensions, and derived units;
- normalized multiplication, division, and integral powers;
- addition, subtraction, comparison, multiplication, and division checks;
- exact, type-directed conversions at assignments, returns, and calls;
- explicit measure parameters using CLEAR's existing generic-bound shape;
- nesting inside collections, tuples, tenses, generics, and capabilities;
- erased FFI and Zig ABI representation;
- STRICT-mode enforcement for designated standard-library parameters; and
- fixable diagnostics for missing units at legacy standard-library calls.

This would eliminate a broad class of bugs involving milliseconds versus
seconds, bytes versus element counts, radians versus degrees, distance versus
velocity, incompatible coordinates, and incorrect scientific formulas.

It does **not** solve calendar semantics. Time zones, daylight-saving
transitions, leap seconds, civil dates, and the difference between an instant
and a duration still require nominal standard-library types and deliberate
APIs.

The recommended complete first version is approximately 2,400-3,900
production lines plus 2,500-4,500 lines of tests. A deliberately smaller F#-
style MVP without scaled-unit conversion or measure generics would be roughly
1,100-1,700 production lines, but it would not meet the stated time/API and
scientific-computing goals.

## Surface Syntax

### Value types and literals

The measure follows the numeric pivot type or numeric literal:

```clear
timeout: Int64|ms| = 250|ms|;
distance: Float64|m| = 12.5|m|;
speed: Float64|m/s| = distance / 2.0|s|;
force: Float64|kg*m/s^2| = mass * acceleration;
```

The user's proposed `Float|ms|` spelling assumes a concrete `Float` alias.
Current CLEAR has concrete `Float32` and `Float64` storage types, while
`Number` is normalized to `Float64` in several compiler paths. Measures should
not independently introduce a new ambiguous-width `Float` type. The initial
canonical spellings should therefore be `Float32|ms|` and `Float64|ms|`.
If CLEAR separately adopts `Float` as an explicit alias or numeric-family
surface, `Float|ms|` composes naturally.

A literal keeps its normal backing type:

```clear
10|ms|       # Int64|ms|
10.0|ms|     # Float64|ms|
10_f32|ms|   # Float32|ms|
```

Normal safe numeric coercion remains available without dropping the measure:

```clear
delay: Float64|ms| = 10|ms|;
```

An immediately visible measured destination may supply the literal's measure:

```clear
delay: Float64|ms| = 10;
```

This is safe contextual typing: the source line itself declares what `10`
means. It is distinct from passing an unannotated number to an API whose unit
is not visible at the call site.

The parser should permit a measure suffix only on a numeric literal, not an
arbitrary expression. Otherwise `(untrustedValue)|ms|` would become an easy,
unchecked unit cast. A value changes units through a checked expected-type
boundary or an explicit future conversion operation.

### Declarations

Use separate declarations for dimensions and units:

```clear
MEASURE Time;
UNIT s: Time;
UNIT ms: Time = s / 1000;
UNIT us: Time = s / 1_000_000;
UNIT min: Time = 60 * s;

MEASURE Length;
UNIT m: Length;
UNIT cm: Length = m / 100;
UNIT km: Length = 1000 * m;

MEASURE Mass;
UNIT kg: Mass;

MEASURE Velocity = Length / Time;
UNIT mps: Velocity = m / s;

MEASURE Force = Mass * Length / Time^2;
UNIT N: Force = kg * m / s^2;
```

`MEASURE` declares a dimension. `UNIT` declares a concrete scale within a
dimension. A unit without `=` has scale one and establishes the dimension's
canonical reference unit. A dimension must not have two unrelated scale-one
units.

All scale factors must be exact compile-time rationals composed from integer
constants and registered units. Floating-point conversion constants are
rejected because they make type equality and reproducible compilation
dependent on rounding.

Derived measure equations use dimensions. Derived unit equations use units.
The compiler verifies that a unit's right-hand expression has the dimension
declared after `:`.

This is slightly more syntax than F#:

```fsharp
[<Measure>] type m
[<Measure>] type s
[<Measure>] type N = kg m / s^2
```

The additional distinction pays for itself at API boundaries. CLEAR can know
that `ms` and `s` are compatible Time units while preserving their different
scales. F# normally expresses that relationship using separately typed
conversion constants or functions.

### Measure formulas

Inside `|...|`, `MEASURE`, and `UNIT` formulas:

- `*` forms a product;
- `/` forms a quotient;
- `^` applies a signed integral power;
- parentheses group a formula; and
- `1` is dimensionless.

Examples:

```clear
Float64|m/s|
Float64|kg*m/s^2|
Float64|1/s|
Float64|m^2|
Float64|m/(s^2)|
```

The compiler canonicalizes equivalent formulas by summing exponents and
sorting dimension identities. These are the same type:

```clear
Float64|kg*m/s^2|
Float64|m*kg/(s*s)|
Float64|N|
```

They are equivalent because the registered `N` equation has the same exact
dimension and scale.

Only integral powers belong in the first version. Rational powers complicate
unit existence, numeric domains, and diagnostics. A future `sqrt` intrinsic
can accept only measures whose exponents are all divisible by two and return
the statically computed result.

### Composition with the existing type system

A measured value is a numeric payload type, not a capability or collection
layer:

```clear
[]Float64|m|                       # list of measured distances
[3]Float64|m|                      # fixed vector of measured distances
Tuple<Float64|m|, Float64|s|>      # distance and elapsed time
?Float64|ms|                       # optional measured duration
!Float64|kg|                       # fallible measured mass
~Float64|m/s|                      # future measured velocity
[List]@local Float64|m|            # local list; measured elements
```

The binding order is:

```text
tense / collection layers -> measured numeric pivot -> measure expression
```

Measures must not be stored in `TypeCapabilities`. Capabilities describe
ownership, representation, synchronization, and visibility. Measures obey an
algebra under numeric operators. Mixing them would make both systems harder
to reason about.

The type-expression node should conceptually be:

```text
MeasuredTypeExpression(
  numeric: NamedTypeExpression(Float64),
  measure: MeasureSyntax(m / s)
)
```

Thus `[]Float64|m|` is a `LinearTypeExpression` whose item is a
`MeasuredTypeExpression`. Tenses and capabilities continue to attach at their
existing layers.

## Semantic Model

### Dimensions, units, and representations

Keep three concepts separate:

1. **Backing type**: `Int64`, `Float32`, `Float64`, and other supported numeric
   representations.
2. **Dimension signature**: a canonical exponent vector such as
   `{Length: 1, Time: -1}`.
3. **Unit signature**: a dimension signature plus an exact rational scale and
   preferred display formula, such as `km/h`.

Suggested immutable semantic values:

```text
MeasureExponent
  dimension_id: MeasureId
  power: Integer

DimensionSignature
  exponents: sorted Array<MeasureExponent>

RationalScale
  numerator: Integer
  denominator: Integer

UnitSignature
  dimensions: DimensionSignature
  scale: RationalScale
  display: MeasureFormula
```

The numerator and denominator are reduced, sign-normalized, bounded integers.
Unbounded declaration-time arithmetic is a compiler resource-exhaustion risk;
the frontend budget should cap factor count, exponent magnitude, and rational
bit width with stable diagnostics.

### Type identity

Exact measured type identity includes:

- the backing numeric type;
- the canonical dimension vector; and
- the exact unit scale.

The preferred display alias is not identity. `N` and `kg*m/s^2` are the same
type when their canonical scale and dimensions match.

This identity belongs in:

- `TypeShape#semantic_key`;
- generic substitutions and associated types;
- function signature keys and overload resolution;
- collection element identity;
- incremental interface and body fingerprints; and
- MessagePack AST/type equivalence used during self-hosting.

Zig type identity deliberately omits the measure. `Float64|m|` and
`Float64|s|` both emit `f64`.

### Arithmetic

The initial rules should be deliberately unsurprising:

| Operation | Rule | Result measure |
| --- | --- | --- |
| `a + b`, `a - b` | exact units must match | same exact unit |
| `<`, `<=`, `>`, `>=`, `==`, `!=` | exact units must match | `Bool` |
| `a * b` | any numeric measures | product |
| `a / b` | any numeric measures | quotient |
| `a % b` | exact units must match | same exact unit |
| `a ** n` | `n` is compile-time integer | input measure to power `n` |
| unary `-`, absolute value | preserve | input measure |
| dimensionless result | cancel all factors and scale | ordinary numeric type after scale application |

Requiring exact units for addition and comparison avoids a hidden promotion
policy where `a + b` and `b + a` acquire different types, or where integers
silently lose precision in a canonical unit. Compatible but differently
scaled units convert at an expected-type boundary:

```clear
distanceM: Float64|m| = distanceCm;
total = distanceM + offsetM;
```

The assignment carries an authoritative `MeasureConversionPlan`. Literal
conversions fold at compile time. Runtime conversions emit one multiply or
divide, normally optimized with surrounding arithmetic.

A later version may add deterministic same-dimension promotion after real
scientific workloads establish the desired policy. Julia Unitful supports
configurable preferred-unit promotion, but global or session-sensitive
promotion is a poor fit for CLEAR's local reasoning and reproducible builds.

### Conversion safety

A conversion is legal only when dimensions match.

```clear
millis: Int64|ms| = seconds;       # multiply by 1000, checked
meters: Float64|m| = centimeters; # multiply by 0.01
```

Integral conversion must be exact for every value or use an explicit checked
or rounding operation. For example, `Int64|us| -> Int64|ms|` is not an
implicit conversion because some microsecond values are not whole
milliseconds.

Overflow follows CLEAR's existing checked integer policy. A scale conversion
must not introduce wrapping through backend arithmetic. Annotation should
produce a conversion plan containing reduced multiply/divide factors and
overflow/exactness policy; MIR consumes it without reconstructing measures.

No ordinary `CAST` may add a measure to an unmeasured runtime value or change
one dimension into another. FFI and deserialization need a narrow, auditable
boundary operation analogous to an unsafe representation assertion. Its
syntax should be designed with the C-FFI boundary rather than added to the
common language prematurely.

### Generic measures

F#'s generic-unit support is one of its strongest properties and should not be
omitted from a serious CLEAR implementation.

Reuse the shape of CLEAR's generic bounds:

```clear
FN sum<M: Measure>(left: Float64|M|, right: Float64|M|)
  RETURNS Float64|M| ->
  RETURN left + right;
END

FN speed<L: Length, T: Time>(distance: Float64|L|, elapsed: Float64|T|)
  RETURNS Float64|L/T| ->
  RETURN distance / elapsed;
END
```

`M: Measure` introduces an arbitrary measure parameter. `L: Length` restricts
the parameter to units having the `Length` dimension. A generic parameter used
inside `|...|` is measure-kinded and cannot also be used as an ordinary value
type. The compiler should diagnose the ambiguity at the declaration.

This is not a protocol or runtime interface. Measure genericity is a compiler
kind with exponent substitution. Because measures erase, instantiations with
the same backing numeric ABI can share emitted code when the body contains no
unit conversion whose scale depends on the call. This can avoid the type and
monomorphization expansion common in library-encoded Rust unit systems.

Collections preserve the parameter normally:

```clear
FN average<M: Measure>(values: []Float64|M|) RETURNS Float64|M| ->
  RETURN values |> AVERAGE _;
END
```

Pipeline reducers need measure-aware rules:

- `SUM`, `MIN`, and `MAX` preserve the item measure;
- `AVERAGE` preserves the measure while applying its existing backing-type
  promotion;
- `COUNT` remains dimensionless;
- `REDUCE` follows its explicit accumulator type; and
- numeric `SELECT` expressions infer their complete measured result type.

## Standard-Library and Mode Policy

### The signature is measured in every mode

Standard-library contracts should contain real measured types:

```clear
sleep(duration: Int64|ms|) RETURNS Void
```

The scheduler may ultimately accept nanoseconds or another internal unit. The
public measure and the lowering conversion are separate decisions.

For the requested floating-point form, `sleep` should accept the supported
numeric Time family and lower it through a checked conversion to scheduler
ticks:

```clear
delay: Float64|ms| = 10;
sleep(delay);
```

Negative, non-finite, overflowing, and sub-tick values need one documented
policy. The recommended policy is a fixable/static error for compile-time
literals and a fallible checked conversion for runtime values rather than
silent wrap or truncation.

### Missing measures at legacy STDLib calls

Explicitly wrong measures are errors in every mode:

```clear
sleep(10|bytes|);
# Type Error: sleep expects a Time value; got Bytes.
```

Only absence is mode-dependent, and only for designated standard-library
parameters carrying a legacy default unit:

```clear
sleep(10);
```

| Mode | Behavior |
| --- | --- |
| EASY | Accept as the parameter's declared legacy default (`ms`) |
| DEFAULT | Accept as `ms`; optionally emit a migration hint |
| STRICT | Fixable error: `sleep` requires a Time unit; replace with `sleep(10|ms|)` |

The standard-library declaration needs metadata equivalent to:

```text
expected: Int64|ms|
legacy_unmeasured_default: ms
strict_requires_measure: true
```

This must not be a name-based `sleep` special case. The same mechanism covers
timeouts, retry delays, socket deadlines, byte counts, rates, and other
existing numeric APIs.

User-defined measured parameters should reject unmeasured call arguments in
every mode. The programmer wrote an explicit API contract; EASY must not erase
it. This does not prohibit a bare literal initializing an explicitly measured
local or field, where the unit is visible beside the literal. A future
library-migration annotation could expose the same legacy-default call
behavior, but it should not be part of the MVP.

### Autofix policy

For a bare literal passed directly to a legacy STDLib parameter, STRICT can
apply a high-confidence fix:

```clear
sleep(10);       # before
sleep(10|ms|);   # after
```

For a variable, the compiler should point to both the call and its inferred
declaration but avoid rewriting the declaration automatically unless all uses
require the same unit:

```clear
delay = config.timeout;
sleep(delay);
```

The value may be raw external data whose unit has not been validated. Adding a
unit would assert semantics, not merely make syntax explicit.

### Initial STDLib coverage

Audit numeric parameters and returns in these categories:

- scheduler sleep, timeout, retry, polling, and deadline APIs;
- clock and elapsed-time APIs;
- network and file timeouts;
- buffer sizes, byte counts, offsets, and capacities;
- rates and throughput;
- random ranges and probabilities where nominal measures help; and
- FFI functions whose C/Zig documentation currently carries a unit only in
  prose.

Do not add measures mechanically to counts or indexes when the semantic unit
adds no protection. `list.length()` can remain `Int64`; an API mixing a byte
length with an element count should distinguish them.

## Time and Date: What Measures Fix

Measures make duration APIs substantially safer:

```clear
connectTimeout: Int64|ms| = 500|ms|;
retryDelay: Float64|s| = 0.25|s|;
throughput: Float64|bytes/s| = transferred / elapsed;
```

They eliminate parameter-name conventions such as `timeout_ms`, families of
`fromMillis` constructors, and accidental calls like passing nanoseconds to an
API expecting milliseconds.

They do not make an instant a duration. The standard library should retain
nominal distinctions:

```text
MonotonicInstant - MonotonicInstant -> Duration with a Time measure
MonotonicInstant + Duration         -> MonotonicInstant
UnixTimestamp - UnixTimestamp       -> Duration with a Time measure
UnixTimestamp + UnixTimestamp       -> error
Date / LocalDateTime / ZonedDateTime -> calendar and timezone APIs
```

Representing both timestamps and durations as `Int64|ms|` would permit adding
two timestamps and would reproduce a major class of time API bugs. Measures
solve scale and dimension; nominal types solve semantic roles and affine
origins.

Affine units such as Celsius are deferred for the same reason. Temperature
differences form a multiplicative measure; absolute Celsius/Fahrenheit values
have offsets and require affine-point semantics. Treating `C` as merely a
scaled `K` would be wrong.

## Scientific Computing Examples

### Formula checking

```clear
MEASURE Length;
UNIT m: Length;

MEASURE Time;
UNIT s: Time;

MEASURE Mass;
UNIT kg: Mass;

mass: Float64|kg| = 80|kg|;
acceleration: Float64|m/s^2| = 9.81|m/s^2|;
force = mass * acceleration;

expected: Float64|kg*m/s^2| = force;
```

The final assignment is valid. Assigning `force` to `Float64|kg*m/s|` reports
the missing Time exponent and identifies the multiplication that produced it.

### Generic vectors

```clear
STRUCT Vector3<M: Measure> {
  x: Float64|M|,
  y: Float64|M|,
  z: Float64|M|
}

position: Vector3<m> = Vector3<m>{
  x: 1|m|,
  y: 2|m|,
  z: 3|m|
};
```

This requires measure-kinded generic arguments to compose with existing
generic structs without becoming runtime fields.

### Domain-specific nominal measures

Measures need not be limited to SI physics:

```clear
MEASURE Requests;
UNIT request: Requests;

MEASURE Data;
UNIT byte: Data;
UNIT KiB: Data = 1024 * byte;

rate: Float64|request/s| = completed / elapsed;
payload: Int64|KiB| = 64|KiB|;
```

Currencies should be independent dimensions unless conversion uses an
explicit runtime exchange rate. Declaring a fixed scale between USD and EUR
would be semantically false.

## Comparison with F#

F# provides the closest model to CLEAR's goals:

- measures decorate primitive numeric types;
- formulas normalize multiplication, division, and integral powers;
- functions can be generic over a measure;
- incompatible arithmetic is rejected at compile time; and
- measures are erased and have no runtime representation cost.

That is why the compiler-native approach is preferable.

Differences in the recommended CLEAR design:

| Concern | F# | Proposed CLEAR |
| --- | --- | --- |
| Syntax | `float<ms>`, `10.0<ms>` | `Float64|ms|`, `10.0|ms|` |
| Declaration | measure symbols and derived formulas | dimensions plus scaled units |
| Scale conversion | explicit typed constants/functions | exact registered scale plus conversion plans |
| Genericity | inferred generic measures and annotated measure parameters | explicit `M: Measure` / `M: Time`, with EASY inference possible later |
| Runtime | erased | erased |
| Standard library policy | library-specific | STRICT-required units with EASY/DEFAULT legacy defaults |
| Capabilities/tenses | not applicable | compose as independent type axes |

Implementing the F# model inside CLEAR is mechanically straightforward
because the compiler already owns type parsing, numeric operation inference,
generic substitution, diagnostics, and lowering. The hard part is not the
dimension-vector algebra. It is integrating measure identity everywhere that
currently assumes `resolved == :Float64` is a complete numeric type.

## Comparison with Rust

Rust has no built-in units-of-measure feature. Common choices are:

1. a nominal newtype per quantity or unit; or
2. a crate such as [`uom`](https://docs.rs/uom/latest/uom/) that encodes
   dimensions and units through generic types, traits, macros, and
   zero-sized/type-level markers.

From the Rust compiler's perspective, the library approach is easier: it
requires essentially no units-specific compiler implementation. From the
language user's perspective, it exposes much more machinery:

- quantity wrapper types rather than ordinary numeric types;
- macro-defined systems and units;
- trait-resolution and generic errors for invalid arithmetic;
- type-level exponent representations;
- conversion APIs such as constructing or extracting a value in a named unit;
- possible compile-time and monomorphization growth; and
- additional work at FFI, serialization, and generic-library boundaries.

Rust's `uom` normalizes values to a base unit for the quantity and documents
the resulting representability problem for integral storage, such as a
centimeter that cannot be represented as an integer number of meters. CLEAR
should avoid hiding that loss by preserving exact unit scale in the measured
type and requiring exact integer conversions.

Rust newtypes are excellent when two values have the same physical dimension
but different semantic roles, such as `UnixTimestamp` and `Duration`. They do
not by themselves derive `Velocity = Length / Time`. CLEAR should use both
ideas at their appropriate levels: nominal structs for semantic roles and
erased measures for dimensional algebra.

The Rust approach would be harder to reproduce *as a CLEAR library* than to
implement in the compiler. CLEAR would first need significantly richer
type-level integers, associated-type arithmetic, operator protocols, and
possibly higher-kinded machinery. Error messages would then expose those
encodings. A compiler-native measure engine is less total complexity and gives
the compiler enough intent to produce direct fixes.

## Comparison with Julia

Julia's Unitful package distinguishes backing number, dimensions, and units in
a `Quantity{T,D,U}` type. It supports rich unit conversion, configurable
promotion, affine units, runtime display, and extension packages. Staged
specialization moves much of the unit work out of hot arithmetic.

Julia is stronger for interactive scientific exploration:

- values retain units for display and runtime inspection;
- promotion behavior is highly extensible;
- mixed ecosystems can define new units dynamically; and
- affine and context-specific conversions are library-extensible.

CLEAR should not copy those dynamic properties into its core representation.
They would weaken ABI transparency, reproducibility, and local performance
reasoning. Instead:

- borrow Julia's dimension-versus-unit distinction;
- keep registrations compile-time and module-scoped;
- keep promotion deterministic rather than session-configurable;
- erase measures before runtime; and
- require a format unit explicitly when runtime output should contain a unit
  label.

This makes CLEAR less dynamic than Unitful but potentially better for systems
and infrastructure code: arrays remain raw contiguous numerics, C/Zig ABI is
unchanged, and a unit-generic helper need not create a runtime quantity
wrapper. Julia remains more capable where runtime unit reflection and
interactive promotion are the priority.

## Which Model Best Fits CLEAR

| Model | Compiler work | User complexity | Diagnostics | Runtime/ABI | Fit |
| --- | ---: | ---: | --- | --- | --- |
| F#-style built-in erasure | moderate | low | domain-specific | raw numeric | excellent |
| Rust newtypes | low | moderate per domain | nominal mismatch | wrapper, often optimized | useful only for semantic roles |
| Rust `uom`-style library | very low compiler work, high library machinery | high | generic/trait-shaped | zero-cost in optimized code | poor fit for CLEAR ergonomics |
| Julia Unitful-style library | no core language work in Julia | low-to-moderate | rich and dynamic | quantity type/runtime unit info | excellent for exploration, weaker CLEAR ABI fit |
| Proposed hybrid | moderate | low | direct and fixable | erased raw numeric | best fit |

The proposed hybrid is closer to F# than to Rust or Julia. It adds Julia's
clean distinction between dimensions and units, but it retains F#'s compiler
knowledge and erasure. That combination aligns with CLEAR's goals:

- safety information is explicit where it prevents mistakes;
- ordinary calls remain concise;
- EASY preserves compatibility;
- STRICT makes contracts visible;
- diagnostics speak in domain concepts rather than type-level encodings;
- performance and memory layout remain those of primitive numerics; and
- the Zig output remains simple.

## Compiler Architecture

### One authoritative measure subsystem

Most new logic should live in a small subsystem rather than spread special
cases through annotation and MIR:

```text
compiler/ruby/ast/measure.rb
  MeasureSyntax
  MeasureFormulaParser
  DimensionSignature
  RationalScale
  UnitSignature
  MeasureRegistry
  MeasureResolver

compiler/ruby/annotator/measure_operations.rb
  MeasureOperationPlanner
  MeasureConversionPlan
  MeasureDiagnosticFacts
```

Existing phases call these authorities:

```text
operator + operand measured types
  -> result measured type
  -> operand conversions
  -> diagnostic, if any

source measured type + expected measured type
  -> compatibility
  -> exact conversion plan
  -> overflow/exactness policy
```

MIR accepts only the plan. It must not parse measure strings, consult the
registry, or re-derive dimensional arithmetic.

### Required integration points

The feature cannot be completely isolated because numeric type identity is
currently observed in many places. Expected touch points are:

- lexer keyword and `^` token support;
- parser declarations, type suffixes, and numeric literal suffixes;
- AST declaration and literal/type-expression nodes;
- type-expression tree traversal, copying, printing, and semantic keys;
- declaration indexing and import resolution;
- type registration and measure-definition cycle checking;
- numeric `Type` predicates, equality, acceptance, coercion, and display;
- binary and unary operation planning;
- generic parameter kinds and substitution;
- function argument, assignment, return, and field coercion;
- collection and pipeline numeric operations;
- diagnostics and autofixes;
- MIR conversion nodes and both Zig/bytecode emission;
- FFI validation;
- formatter support;
- incremental interface fingerprints; and
- MessagePack/self-host equivalence.

The semantic algebra should still have one owner. Callers should ask the
measure planner rather than branching on measure fields independently.

### Parsing and ambiguity

The syntax is a good fit for the current lexer:

- `|>` is already tokenized before `|`, so pipelines remain unambiguous;
- legacy `||` is tokenized separately;
- standalone `|` is no longer a binary OR spelling; and
- `|...|` gives the measure parser a bounded subgrammar.

The lexer needs `MEASURE`, `UNIT`, and likely `^`. The parser should recognize
the closing bar through a location-aware bounded routine; it must not slice
source and invoke a second context-free lexer without absolute ranges.

The frontend resource budget should cap nested parentheses, formula nodes,
absolute exponent, declaration dependencies, and rational size.

### Registration and imports

Measure and unit declarations must be indexed before function signatures are
resolved, just like type declarations. Forward references are legal. The
registry builds a dependency graph, rejects cycles, and publishes immutable
resolved definitions.

Imported collisions are errors unless they resolve to the same qualified
identity. A unit named `m` from two packages must not unify solely because the
surface symbol matches. Canonical dimension IDs include their defining module.

Changes to a public measure or unit definition invalidate any signature or
body whose semantic measure key depends on it. The registry's public digest
belongs in incremental `ProgramInterface` facts.

### Lowering and ABI

Most measured operations lower identically to existing numeric operations.
Only conversions add MIR:

```text
MeasureConvert(
  value,
  multiply_numerator,
  divide_denominator,
  target_numeric_type,
  exactness,
  overflow_policy
)
```

Zig and bytecode backends emit ordinary numeric operations and casts. The
measured type itself emits the underlying numeric Zig type.

Extern declarations can carry measures without changing ABI:

```clear
EXTERN FN wait_ns(duration: UInt64|ns|) RETURNS Void ABI C;
```

The declaration protects CLEAR callers while Zig/C receives `u64`. Header
generation should emit the raw type plus a comment or sidecar metadata; C
cannot enforce the measure.

## Diagnostics

Diagnostics should describe the formula mismatch, not expose canonical hash
keys:

```text
Measure Error: `sleep` expects Time, but argument 1 has Data (`bytes`).
  sleep(payloadSize)
        ^^^^^^^^^^^
Use a Time value such as `10|ms|`; do not cast between unrelated measures.
```

```text
Measure Error: cannot add `Float64|m|` and `Float64|s|`.
Addition requires identical units; multiplication would produce `m*s`.
```

```text
STRICT requires a unit for argument 1 of `sleep`.
This legacy parameter is measured in milliseconds.
Fix: sleep(10|ms|)
```

```text
Conversion from `Int64|us|` to `Int64|ms|` may discard a fractional
millisecond. Use a floating backing type or an explicit rounding operation.
```

Definition errors need source ranges for the declaration and dependency that
caused an unknown symbol, scale mismatch, duplicate base unit, cycle, exponent
overflow, or rational-budget violation.

## Testing Strategy

### Focused compiler integration tests

Prefer CLEAR source strings covering:

- declarations, forward references, imports, cycles, and duplicate units;
- type/literal syntax and formatter round trips;
- canonical equivalent formulas;
- incompatible dimensions and different scales;
- every numeric backing type;
- arithmetic, comparisons, powers, and cancellation;
- exact and inexact conversions;
- overflow and negative-duration behavior;
- generic measure inference and substitution;
- fields, returns, calls, tuples, collections, tenses, and capabilities;
- FFI erasure;
- EASY, DEFAULT, and STRICT standard-library behavior;
- diagnostic source ranges and fixes; and
- incremental invalidation.

### Transpile tests

End-to-end tests should prove:

- generated Zig uses raw numeric fields and arrays;
- a literal unit conversion constant-folds;
- a runtime conversion emits correct arithmetic;
- scientific formulas compute expected results;
- measured generic functions work;
- `sleep(10|ms|)` actually suspends for the expected scheduler scale;
- C FFI receives the expected raw value; and
- no measure metadata changes ABI size or alignment.

### Fuzzing and properties

A dedicated measure grammar generator should produce bounded formulas and
check:

- canonicalization is associative and commutative for products;
- division adds inverse exponents;
- normalization is idempotent;
- equivalent formulas have equal semantic keys;
- incompatible dimensions never coerce;
- conversion composition equals direct conversion;
- exact integer conversion never loses information;
- parse -> format -> parse preserves the measure AST; and
- annotation plans and MIR conversion plans agree.

Cross-check generated rational conversions against an independent Ruby
`Rational` oracle in tests. Keep production values in the compiler's bounded,
strongly typed representation.

### Corpus migration

Add strict-measure corpus runs over examples, benchmarks, fuzz fixtures, and
transpile tests. Do not mass-rewrite ambiguous variables. Autofix only direct
literals and uniquely inferred declarations, then review the resulting diff.

New and changed production code requires 100% line coverage. The measure fuzz
and transpile suites should cover at least 80% of the subsystem; focused
source-string specs cover error and resource-limit branches.

## Estimated Size and Effort

### Recommended feature

| Area | Estimated production LoC |
| --- | ---: |
| Measure algebra, rational scale, registry | 300-500 |
| Lexer, parser, AST, formatter | 300-500 |
| Type-expression integration and semantic keys | 300-500 |
| Declaration resolution, imports, incremental fingerprints | 250-450 |
| Arithmetic, compatibility, conversion, generics | 500-850 |
| MIR, Zig, and bytecode lowering | 200-350 |
| STDLib mode policy, diagnostics, autofix | 250-450 |
| Pipelines, collections, FFI, remaining integration | 200-300 |
| **Total** | **2,300-3,900** |

Allow approximately 2,500-4,500 test lines, including generated fuzz cases,
and 300-600 documentation/data lines for standard measures and migrated API
metadata.

For one engineer already familiar with this compiler:

- parser, model, and exact equality MVP: 1-2 weeks;
- arithmetic, conversion, and generics: 2-3 weeks;
- standard-library migration, backends, fuzzing, and hardening: 2-3 weeks;
- total recommended feature: approximately 5-8 engineering weeks.

The lower end assumes no unexpected numeric-inference duplication and that
bytecode can consume the same conversion plan. The upper end is more honest if
measure-kinded generics expose assumptions that type parameters are always
ordinary types.

### Smaller alternatives

| Scope | Production LoC | Effort | Limitation |
| --- | ---: | ---: | --- |
| `sleep(10|ms|)` syntax-only nominal tag | 500-800 | 1-2 weeks | not a dimensional system; poor value |
| F#-like exact symbolic measures, no scales/generics | 1,100-1,700 | 2-3 weeks | conversions remain manual; weak scientific reuse |
| Recommended dimensions + scaled units + generics | 2,300-3,900 | 5-8 weeks | excludes affine units/runtime reflection |
| Julia-like affine units and configurable promotion | 4,500-7,000+ | 10-16 weeks | more runtime/type complexity than CLEAR needs |

The syntax-only option should not be implemented. It would make `sleep` safer
but create a second nominal-type mechanism without solving derived formulas,
unit-generic algorithms, or scientific composition.

## Implementation Phases

### Phase 1: erased exact measures

- Add measure syntax/model and declarations.
- Add canonical dimension algebra without scaled conversion.
- Integrate semantic keys, numeric equality, arithmetic, and formatting.
- Prove raw Zig/bytecode representation.

### Phase 2: dimensions and scaled units

- Add exact rational unit scales.
- Add assignment/call/return conversion plans.
- Add exactness and overflow checks.
- Add standard Time/Data/Length unit definitions.

### Phase 3: measure-kinded generics

- Add `M: Measure` and dimension-constrained bounds.
- Extend substitution, overload keys, structs, tuples, and collections.
- Ensure erased measure instantiations share code where possible.

### Phase 4: standard-library migration

- Annotate standard-library numeric unit contracts.
- Add legacy default-unit metadata.
- Enforce STRICT and add high-confidence literal fixes.
- Migrate relevant examples and tests.

### Phase 5: scientific and hostile testing

- Add operator/collection fuzz matrices.
- Add formula/property testing and resource budgets.
- Add scientific and FFI transpile examples.
- Verify incremental invalidation and self-host MessagePack equivalence.

Affine measures, runtime unit reflection, configurable promotion, and calendar
types are separate future projects.

## Acceptance Criteria

The feature is complete only when:

1. `Float64|ms|` and `10|ms|` parse, format, type-check, and erase correctly.
2. Equivalent derived formulas unify and incompatible dimensions do not.
3. Numeric arithmetic produces the specified measured result type.
4. Scaled conversions are exact, checked, and owned by annotation plans.
5. `sleep(10)` remains compatible in EASY/DEFAULT and has a fixable STRICT
   error suggesting `sleep(10|ms|)`.
6. Explicitly wrong STDLib measures fail in every mode.
7. Generic measure functions and measured collections work end to end.
8. Zig/C ABI layout is byte-identical to the backing numeric type.
9. Bytecode and Zig backends agree on conversion results.
10. Incremental and clean builds produce byte-identical Zig.
11. All existing tests pass and changed production lines have 100% coverage.
12. Fuzzing finds no parser crash, algebra non-canonicality, conversion
    disagreement, uncontrolled rational growth, or annotation/MIR mismatch.

## Risks and Stop Conditions

The primary architectural risk is scattering `if measured?` checks throughout
the compiler. Stop and centralize if arithmetic, coercion, MIR, or pipelines
begin independently manipulating exponent maps.

Other stop conditions:

- measure definitions require parse-time global semantic state;
- MIR has to resolve names or reconstruct conversion scales;
- erased measure generics cause uncontrolled monomorphization;
- integer conversion silently truncates or wraps;
- STRICT behavior is implemented using STDLib function names;
- capabilities begin carrying measure state;
- units change ABI without an explicit representation type; or
- time measures are used as a substitute for nominal instant/calendar types.

## Recommendation

Implement the recommended feature in phases, starting with the central erased
algebra and exact-unit arithmetic. Do not ship only the `|ms|` syntax: that
would solve one API spelling while leaving the difficult semantics for later.

The design is a strong fit for CLEAR. It offers F#-quality compile-time
dimensional safety with primitive runtime representation, improves on F#'s
scaled-unit ergonomics, avoids Rust's visible generic/newtype machinery, and
keeps more predictable ABI and compilation behavior than a dynamic Julia-like
quantity system.

The honest cost is moderate rather than trivial: approximately 2,300-3,900
production LoC and 5-8 engineering weeks. The payoff is also broad. Unlike a
time-specific `Duration` wrapper, the same subsystem protects infrastructure
APIs, storage sizes, rates, geometry, simulation, finance-domain quantities,
and scientific formulas while adding no per-value runtime overhead.
