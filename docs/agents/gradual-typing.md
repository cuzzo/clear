# Gradual typing — `Auto` typed holes

**Status:**
- **M1:** ✅ implemented (parser + collector + unifier + fix
  emission + STRICT-imports + pipeline integration). Tranches
  M1.1–M1.7 in §10.
- **M2:** ✅ implemented
  - M2.1 ✅ operator-aware suggestions for ambiguous / unresolvable
    Auto.
  - M2.2 ✅ forward-flow inference for empty `[]` / `{}`
    initializers via `:list_element` / `:map_key` / `:map_value`
    shape-tagged slots; evidence collected from `.append(e)` /
    `x[k] = v`.
  - M2.3 ✅ STRUCT fields reject `Auto` at parse time with a hard
    error; field types must be concrete.
- **v0.2:** `--strict` mode (§9). Infrastructure in place; flag
  disabled today.

## 1. Goal

Two surfaces, one mechanism. The user writes `Auto` as a placeholder
where the concrete type is unknown; the compiler resolves it from
program-local evidence and rewrites the source via `clear fix`.

```clear
-- Explicit Auto — works in default (non-gradual) mode.
FN double(x: Auto) RETURNS Auto ->
    RETURN x + x;
END

x: Auto = parseConfig();
```

Compiled with `clear build --gradual`, annotations may be omitted
entirely; the parser inserts implicit `Auto`:

```clear
FN double(x) ->
    RETURN x + x;
END

x = parseConfig();
```

After `clear fix`:

```clear
FN double(x: Int64) RETURNS Int64 ->
    RETURN x + x;
END

x: Config = parseConfig();
```

`Auto` is a single placeholder — it resolves to **one** concrete type
per slot. CLEAR does **not** auto-widen multiple constraints into a
union; that's an explicit user decision (§6 Ambiguity).

## 2. Reference: forms that already infer today

CLEAR already pins types when the constructor / literal carries the
information. These continue to work unchanged:

| Form | Inferred from | Resolved type |
|---|---|---|
| `x = 1_i64` | numeric suffix | `Int64` |
| `x = "hello"` | string literal | `String` |
| `x = [1, 2, 3]` | element types | `Int64[]` |
| `x = { "k": 1 }` | key/value types | `HashMap<String, Int64>` |
| `x = SomeStruct{...}` | constructor name | `SomeStruct` |

`Auto` / gradual mode targets the **under-determined** cases:

| Form | Pre-Auto | With Auto / `--gradual` |
|---|---|---|
| `x = []` | error: cannot infer | inferred from later element accesses |
| `x = {}` | error: cannot infer | inferred from later key/value uses |
| `FN foo(x) -> ...` | parse error (no `--gradual`) | implicit `Auto`, inferred from call sites + body |
| `FN foo() -> RETURN x` | error: missing return type | implicit `Auto` return, inferred from `RETURN` exprs |

## 3. Surface

### 3.1. Three modes

| Mode | Default | Annotations | `Auto` | Purpose |
|---|---|---|---|---|
| `clear build` | yes | required | explicit only | normal dev |
| `clear build --gradual` | no | optional | explicit + implicit | prototyping, scripts |
| `clear build --strict` | future | required | rejected | library publish, CI |

`--strict` is documented for context; **out of scope for v1**.

### 3.2. Auto positions

Auto is allowed in any **type position** owned by the current module:

- Function parameters: `FN f(x: Auto) -> ...`
- Function returns: `RETURNS Auto`
- Local declarations: `x: Auto = expr;`, `MUTABLE x: Auto = expr;`
- Struct fields: deferred to **M2** (cross-callsite coordination needed
  in a way that materially complicates the v1 algorithm).

Auto is **never** allowed in:

- Public function signatures of imported modules. Imports must export
  fully-typed surfaces (STRICT-equivalent for the public API).
  Cross-module inference does not run; the importer reads concrete
  types only. See §7 STRICT-imports boundary.
- Generic type parameters (`<T>`). `T` is already a type variable;
  Auto resolves to a concrete type, not a type variable.

### 3.3. Implicit Auto under `--gradual`

When `--gradual` is set and a type position is omitted entirely, the
parser inserts implicit `Auto`:

| Source | Equivalent under `--gradual` |
|---|---|
| `FN f(x) -> ...` | `FN f(x: Auto) -> ...` |
| `FN f(x) ->\n    RETURN x;\n END` | `FN f(x: Auto) RETURNS Auto -> ...` |
| `x = parseConfig()` | `x: Auto = parseConfig()` |
| `MUTABLE x = []` | `MUTABLE x: Auto = []` |

Without `--gradual`, omitting a required annotation is a **parse
error** (current behavior, unchanged). Users who want the placeholder
without the flag write `Auto` explicitly.

### 3.4. Forward-flow inference for empty container literals

`x = []` and `x = {}` (whether explicit-Auto or implicit-Auto) trigger
forward-flow inference: the unifier walks subsequent uses of `x` and
collects element / key / value type constraints from:

- `x.append(e)` / `x.put(k, v)` and the equivalent index writes
- `x[i] = e` / `x[k] = v`
- `FOR e IN x` (binds `e` to the element type)
- Passing `x` to a function whose declared param type is concrete

If all observed uses agree, the literal resolves. If they disagree,
ambiguity per §6.

## 4. Inference algorithm

Three phases, run **once per build**, between the existing
signature-collection pass and body-validation pass.

### 4.1. Constraint collection

Walk every function body and every local declaration with an `Auto`
slot. Record constraints:

| Auto slot | Constraint sources |
|---|---|
| `FN foo(x: Auto)` | every call site's actual arg type |
| `FN foo(...) RETURNS Auto` | every `RETURN expr` in the body |
| `x: Auto = expr` | RHS type |
| `MUTABLE x: Auto = init; ...; x = other;` | RHS of every reassignment |
| `x = []` | element type from later uses (§3.4) |
| `x = {}` | key/value types from later uses (§3.4) |

Constraints are **concrete types** observed in the program (`Int64`,
`String`, `Counter`, etc.). Type variables (`T` from generic
functions) are not eligible — Auto resolves to concrete only.

### 4.2. Unification

Each Auto slot must resolve to **exactly one** concrete type. The
unifier walks slots in dependency order:

```
call sites' arg types
        │
        ▼
   FN param Auto ───────┐
                         ▼
              body uses of param
                         │
                         ▼
              return-expr types
                         │
                         ▼
       FN RETURNS Auto ──┘
                         │
                         ▼
        call sites that consume the return value
```

Iterates to fixpoint. Each pass either pins a slot or makes no
progress. When no slot was pinned in a full pass, the remaining slots
are unresolved (single observed type → resolve; multiple → ambiguity;
zero → cannot-infer error).

### 4.3. Resolution

For each Auto slot, after fixpoint:

- **Exactly one observed type** → resolved. Emit `:info` `FixableFinding`
  with category `:type` and an `:auto` fix replacing the Auto span
  with the resolved type's source form.
- **Zero observed types** (e.g., a parameter never called, an empty
  `[]` never used) → fixable error, category `:type`, level `:error`,
  message "cannot infer type for X; please specify". No `:auto` fix.
- **Two or more incompatible types** → ambiguity error, see §6.

## 5. Tooling: `clear fix`

When inference resolves an Auto slot, the fixer offers an
`:auto`-confidence span replacement. `clear fix --apply` rewrites the
source in place; `clear fix` (no flag) prompts.

When inference reports ambiguity, the fixer presents the ranked
options (§6) interactively. **None** are `:auto` — the user must
choose deliberately.

## 6. Ambiguity resolution (ranked)

When two or more constraints on a single Auto slot disagree, CLEAR
does **not** silently widen to a union. Unions are explicit
user-authored types. The compiler emits a fixable error with three
ranked options:

### Option 1 (recommended): pin one type at the function, convert at divergent call sites

If at least one of the observed types is convertible to the others (or
one is a clear superset), the compiler picks N candidate concrete
types and proposes:

- A signature fix: replace `Auto` with the chosen type.
- Per-callsite fixes: insert a conversion call where the actual arg
  type doesn't match (`Int64.toString(x)`, `Int.fromString(s)`, etc.).

Example diagnostic:

```
[Ambiguity] FN parseValue(x: Auto) at line 12:
  x is called with Int64 (line 30) and String (line 45).

  Recommended: pin x: String at the signature, convert at call sites.
    line 12: FN parseValue(x: String) -> ...
    line 30: parseValue(Int64.toString(count))
    line 45: parseValue(s)               -- already a String

  Alternative: pin x: Int64 at the signature.
    line 12: FN parseValue(x: Int64) -> ...
    line 30: parseValue(count)            -- already an Int64
    line 45: parseValue(Int.fromString(s) OR_ELSE RAISE)

  Pick a fix or restructure to converge on one type.
```

The fixer offers each ranked alternative as a separate
`:interactive` (not `:auto`) fix. The user selects.

### Option 2: types not obviously compatible

If no observed type is convertible to the others (e.g., `Counter` and
`User`), the compiler reports:

```
[Ambiguity] FN handle(x: Auto) at line 8:
  x is called with Counter (line 20) and User (line 31).
  These types are not obviously compatible. Restructure the call sites
  to converge on one type, or define a union explicitly (see Option 3).
```

No `:auto` fix; the user must redesign.

### Option 3 (last resort): build a union type

The compiler shows an example of how to write the union explicitly
but **never** offers it as a fix:

```
If you genuinely need to accept multiple types, define a union:

    UNION Value { Number: Int64, Text: String }

    FN parseValue(x: Value) -> ...
        MATCH x START
            Value.Number(n) -> { ... },
            Value.Text(t)   -> { ... },
        END
    END

Auto does NOT auto-create unions. They are deliberate type definitions.
```

This option is documentation only — never `:auto`, never the
recommended path. The intent is to make the easy thing the right
thing: most ambiguities are user mistakes, not genuine union needs.

### Local re-binding follows the same rules

```clear
MUTABLE x: Auto = 0_i64;
x = "hello";   -- ambiguity: x observed as both Int64 and String
```

Same Option 1/2/3 ranking. The compiler does **not** widen `x` to
`Int64 | String`. The user picks one type and converts the
disagreeing assignment, or builds an explicit union.

## 7. STRICT-imports boundary

Imported module signatures **must** be fully concrete. The importer
rejects any imported `FunctionSignature` whose params or return type
contain `Auto`:

```
[Error] Imported function 'foo' from module "math" has Auto in its
  public signature. Imported modules must compile with concrete types
  in their public surface. Compile module "math" without --gradual
  and resolve any Auto via `clear fix --apply`, then re-import.
```

Rationale: cross-module inference would couple module compilation
in ways that defeat separate compilation and bog down the build.
Public APIs are deliberate.

## 8. Out of scope (v1)

- **`--strict` CLI flag** — documented in §3.1 for context; lands
  in v0.2 release. v1 must leave the infrastructure ready for it
  but not enable it.
- **Auto in struct field declarations** (`STRUCT Foo { value: Auto }`)
  — explicitly **rejected**, not deferred. Per design: struct fields
  must be concrete because the v1 inference algorithm is per-function
  and cross-callsite struct-field constraint propagation is its own
  algorithmic shape we don't want to add. The compiler emits a hard
  error pointing the user at concrete types. See §10 M2.3.
- **Cross-module inference.** Imports always export concrete types
  (§7). Will not change.
- **Auto on generic type parameters.** `T` is already a type variable;
  Auto resolves to concrete only.
- **Resolution-preference config file.** Out of scope for both v1
  and M2. Revisit when usage data shows the ambiguity surface.
- **Polymorphic Auto.** An Auto slot resolves to one concrete type.
  It cannot resolve to a type variable.
- **Lazy / runtime Auto.** Auto is resolved at compile time. No
  runtime "Auto cell" exists.
- **Pattern-position Auto** (e.g., `MATCH x START Auto -> ...`).
  Patterns require explicit types or wildcards (`_`); Auto is for
  declarations only.

## 9. Future work (post-M2)

### `--strict` mode (v0.2)

Rejects any `Auto` (explicit or implicit). Used for library publish
and CI lockdown after a `clear fix --apply` pass. Production builds
should default to STRICT once the ecosystem matures. The v1+M2
infrastructure (Parser.gradual_mode, Auto Type sentinel,
STRICT-imports boundary) is already in place; flipping the switch
in v0.2 is a flag-check + diagnostic.

### Resolution-preference config file (post-v0.2)

A project-level config (`clear.toml` or similar) lets a project encode
its style without per-callsite annotation. Entries:

```toml
[auto]
int_default       = "Int64"      # ambiguous int literal → Int64
int_float_meet    = "Float64"    # Int + Float → Float, auto-cast Int
size_default      = "USize"
string_int_meet   = "error"      # never silently coerce; force §6
```

The inferencer applies these **before** the operator-derived
suggestions in §6, removing the corresponding ambiguity diagnostics
automatically. Out of scope for v1+M2 — revisit when usage data
shows the ambiguity surface.

## 10. Implementation tranches

### M1.1 — Parser

- `Auto` is a reserved keyword in type positions. Verify in
  `src/ast/parser.rb#parse_type_annotation` and add to lexer
  KEYWORDS if missing.
- New `--gradual` CLI flag in `clear`. When set, the parser allows
  omitted parameter types and return types; each omitted slot gets
  an implicit `Auto` AST marker. Without `--gradual`, omission stays
  a parse error.
- Local declarations: `x = expr` already legal under existing
  inference; under `--gradual`, omitted-with-Auto-implicit equivalence
  is documented but no parser change is required (the existing parser
  doesn't require a type annotation on locals).
- AST: `Auto` Type sentinel. Carries `inferred_type` (nil
  pre-resolution, filled by the inference pass).

### M1.2 — Constraint collector

- New annotator pass `collect_auto_constraints!`, between
  signature-pass-1 and body-pass-2.
- Walks each `FunctionDef` and `VarDecl` / `BindExpr`. For each Auto
  slot, accumulates a `Set<Type>` of observed concrete types.
- Forward-flow for empty `[]` / `{}`: walks subsequent uses of the
  binding to collect element/key/value type constraints.
- Records the source span of each constraint so ambiguity diagnostics
  can cite line numbers.

### M1.3 — Unifier + resolver

- Iterate to fixpoint. Per slot:
  - 1 observed type → resolve, stamp on AST node.
  - 0 observed types → "cannot infer; please specify".
  - 2+ observed types → ambiguity, route to §6 helper.
- Mutable param-type / return-type back-flow: a resolved param type
  contributes to body type-checking; a resolved return type back-flows
  to call sites that read the return value.

### M1.4 — Fix emission

- Resolved slots: `emit_auto_resolved_fix!(span, inferred_type)` —
  `:info` `FixableFinding`, category `:type`, `:auto` fix replacing
  the Auto span with the resolved type's source form.
- Ambiguity: `emit_auto_ambiguity_finding!(slot, observed_types,
  callsites)` — `:error` `FixableFinding`, category `:type`. Body
  composes Option 1 / 2 / 3 per §6. None are `:auto`.
- Cannot-infer: `emit_auto_unresolved_finding!(slot)` — `:error`,
  category `:type`, message "cannot infer type for X; please specify".
  No `:auto` fix.

### M1.5 — STRICT-imports boundary

- `ModuleImporter` rejects any imported `FunctionSignature` with Auto
  in params / return. Diagnostic per §7.
- Verified by: a transpile test that imports a module compiled with
  `--gradual` and unresolved Auto; expects the importer error.

### M1.6 — Tests

`spec/gradual_typing_spec.rb`:

- **Parser**: explicit `Auto`, implicit `Auto` under `--gradual`,
  omitted-without-`--gradual` rejected.
- **Inference**: param from call sites, return from body, local from
  RHS, empty-list/map from forward uses, MUTABLE local with multiple
  consistent assignments.
- **Resolution**: `:auto` fix replacement is the right type and span.
- **Ambiguity**: each of Option 1 / 2 / 3 exercised by a fixture.
- **Cannot infer**: parameter never called, empty list never used.
- **Cross-module**: imported `Auto` rejected.
- **Local re-binding ambiguity**: `MUTABLE x: Auto = 0_i64; x = "hi"`
  produces the ranked diagnostic.

`transpile-tests/3XX_gradual_basic.clear`:

- End-to-end `--gradual` build of a small program with empty
  containers, omitted param/return types, and a single resolved-by-use
  binding. Compiles and runs.

`transpile-tests/3XX_gradual_ambiguity.clear`:

- A program that produces an ambiguity. Expects the build to fail
  with the ranked diagnostic.

## 11. Annotator restructure (the bulk of M1)

The annotator today runs over a complete type environment — every
annotation is resolved before each body is visited. `Auto` breaks
that ordering:

- A function's signature may depend on body analysis (return-type
  inference).
- A body may depend on parameter types (param-type inference).
- Call sites need the resolved signature to type-check.

Workable design:

1. **Pass A — collect signatures.** Existing pass; now skips Auto
   slots (records them as unresolved).
2. **Pass B — collect Auto constraints.** New pass; walks bodies and
   locals, records observed types per Auto slot. Does **not**
   type-check; just collects.
3. **Pass C — unify Auto.** Resolve to fixpoint over recorded
   constraints. Resolve, ambiguity-error, or cannot-infer.
4. **Pass D — body validation.** Existing pass; now sees fully-resolved
   signatures.

Passes A and D are existing code. B and C are new. The total work is
~1-2 weeks of focused effort.

## 12. M2 — operator-aware suggestions, forward-flow, struct-field rejection

### M2.1 — Operator-aware ambiguity / unresolved suggestions

The v1 ambiguity diagnostic (§6) lists observed types from call sites
but doesn't mine the **body** for hints. When a slot has zero
call-site evidence (uncalled fn) or the body uses the param in
operator-expressions whose result type is ambiguous, M2.1 ranks
candidate concrete types per operator class and presents them as
`:interactive` fixes.

**Operator → ranked candidate hints:**

| Op | Default | Alternatives | Notes |
|---|---|---|---|
| `+` | `Int64` | `Float64`, `String` | String only when concat semantics intended |
| `-` | `Int64` | `Float64` | numeric only; not String |
| `*` | `Int64` | `Float64` | numeric only |
| `/` | `Float64` | `Int64` | "Int64 = integer division (truncates)"|
| `%` | `Int64` | — | numeric integer only |
| `==`, `!=`, `<`, `>`, `<=`, `>=` | `Int64` | `Float64`, `String`, comparable types | "must be a comparable type" |
| `&&`, `||` | `Bool` | — | logical |
| `&` (string concat alt) | `String` | — | when explicit concat |

For an unresolved slot, the body walker that visits operator
expressions involving the slot collects an evidence map:
`{ slot_id => Set<{op, position}> }`. Pass C, on detecting an
unresolved/ambiguous slot, consults the evidence map and ranks
candidates by operator-default. Each candidate becomes a
`:interactive` Fix that replaces the `Auto` keyword span with the
chosen concrete type.

Example diagnostic:

```
[Auto] parameter 'x' of `double` could not be resolved from call sites.
  In the body, x is used in `x + x` (line 4).

  Suggested fixes:
    1. (recommended) FN double(x: Int64) ->     -- Int64 + Int64 → Int64
    2.               FN double(x: Float64) ->   -- Float64 + Float64 → Float64
    3.               FN double(x: String) ->    -- String + String → String (concat)

  Pick a fix or specify the type manually.
```

For `/` specifically, the diagnostic explicitly notes integer
division truncation:

```
  Suggested fixes:
    1. (recommended) FN ratio(x: Float64) ->    -- floating-point division
    2.               FN ratio(x: Int64) ->      -- integer division (TRUNCATES toward zero)
```

This replaces the original "iterate-to-fixpoint" approach. The
compiler does **not** re-walk bodies after resolution; it presents
informed options for the user to choose. Deliberate over magic.

### M2.2 — Forward-flow inference for empty `[]` / `{}`

Extends `AutoConstraintCollector::Slot` with an optional `shape:`
field (`:list_element`, `:map_key`, `:map_value`).

For `x = []` (under `--gradual` or with explicit `Auto`):
- Register a `:list_element` slot keyed off the binding's decl-node.
- Walk subsequent uses of the binding for:
  - `x.append(e)` → element-type observation: type of `e`
  - `x[i] = e` → element-type observation: type of `e`
  - `FOR e IN x` → no constraint (e gets x's element type, not the
    other way around)
  - `someFn(x)` where someFn declares a concrete element type →
    element-type observation
- Unifier resolves the `:list_element` slot from observations.
- Binding's full Type becomes `<element>[]`.

For `x = {}`: register `:map_key` and `:map_value` slots; walk for
`x[k] = v`, `x.put(k, v)`, etc.

Same ambiguity / unresolved diagnostics as M1 §6 (operator-aware
suggestions per M2.1 apply here too: if `x[i] = 5` and `x[j] = "s"`
disagree, the diagnostic lists Int64 + String and asks the user to
pick a type — not auto-widen to a union).

### M2.3 — Reject Auto in STRUCT fields

Hard error at parse time. No fix offered (the user must pick the
field's concrete type). Diagnostic:

```
[Error] Auto is not allowed in STRUCT field declarations.
  STRUCT Foo {
    value: Auto    <-- here
  }

  Struct field types must be concrete because cross-callsite struct-
  field inference is intentionally not supported. Replace Auto with
  a concrete type.
```

### Out of scope for M2

- **Iterate-to-fixpoint A1+B+C body re-walk.** The case
  `FN double(x: Auto) RETURNS Auto -> RETURN x + x; END` stays
  unresolvable in M2; the M2.1 diagnostic guides the user to pin
  the return type explicitly. Magic resolution via body re-walk is
  not in v1+M2 plans.
- **`--strict` flag** — v0.2.
- **Resolution-preference config** — post-v0.2.

### Known sharp edges (M2.2 shape inference)

- **Reassigning a shape-tracked binding to an incompatible shape**
  diagnoses as "Cannot infer element type" rather than as a type
  mismatch. Example:

  ```clear
  MUTABLE xs: Auto = [];
  xs = "hello";              -- diagnoses as: Cannot infer element type
                                 of list `xs` (rather than: type mismatch).
  ```

  Why: the empty `[]` initializer commits the binding to a list
  shape (`:list_element` slot). `xs.append(...)` and `xs[i] = v`
  contribute element evidence; a non-list reassignment contributes
  none. With no evidence the slot stays unresolved.

  CLEAR's existing assignment validation is permissive enough to
  let `MUTABLE xs: Int64[] = []; xs = "hello";` through silently
  too — the inferencer's "cannot infer" message is at least an
  error, not silent acceptance. If you intend a polymorphic
  binding, write the type out:
  `MUTABLE xs: Auto = 0_i64; xs = "hello";` — then the regular
  M1 ambiguity diagnostic fires with both observations.
