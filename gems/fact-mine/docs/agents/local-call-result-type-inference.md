# Design: Local Call-Result Type Inference

## 1. Problem & goal

A local bound to a call result carries no type, so method calls and operators on
it cannot be priced:

```rust
let mut v = Vec::new();   // v : ??? (today: no type)
v.push(x);                //  -> unresolved_receiver_type -> blocks the function
let n = v.len();          //  -> unresolved_receiver_type
```

`v`'s type is fully determined by the return type of `Vec::new`, but nothing
infers it. This is the single largest remaining static blocker: on the Rust
stdlib corpus the collection cluster (`push`/`len`/`get`/iterators over locals
built from `Vec::new`/`String::new`/same-file constructors) dominates the tail.

**Goal:** infer the type of a local `x` bound to a call result `x = f(...)` from
the callee's return type, so downstream receiver-typing prices the local's
method calls. The collection-method cost registry already exists
(`config/stdlib_complexity/rust.yml`: `Array`/`String` len/push/get/...), so this
inference is the *only* missing piece for the cluster.

## 2. Current architecture (and the gap)

Types flow through the system as **flow-type facts** seeded from *declared*
types only:

- `cfg/effects.rs` seeds `write_type_hints[name] = "declared:{T}"` from (a)
  declared parameter types and (b) declared local annotations (`let x: T = ..`,
  via `behavior.declared_local_type`). It already records
  `write_call_sources[name] = producer_span` for locals written from a call, but
  never types them.
- `cfg/dataflow.rs` propagates those hints along reaching-definitions into
  `document.flow_types`.
- `profile.rs::extract_type_definitions` parses every function's **return type**
  into a `TypeDefinition{kind:"method_signature", return_type}` — but this runs
  *separately* from, and is **not passed to**, `complexity_facts::facts`.
- `complexity_facts::facts(document)` prices calls. Its `call_receiver_type`
  resolves a receiver from `parameter_types` (declared params) / self-state /
  field-access, and I augment that map in `fact_for_method`
  (`augmented_parameter_types`). It never sees inferred local types.

**Gap:** the two facts needed for inference — "local `v` is bound to call `C`"
(`write_call_sources` / the `LASGN` RHS) and "call `C` returns type `T`"
(`return_type` on the callee) — exist but are never joined.

Two structural constraints shape the design:

1. `complexity_facts` runs at document-extract time, **before** cross-file call
   resolution. So inference may rely only on facts available per-document:
   same-file function return types, and a stdlib-constructor registry. (Cross-file
   project constructors are out of scope for v1 — see §8.)
2. `cfg/effects.rs` (the single-source-of-truth for flow types) runs in the
   syntax layer, which has no return-type parser (that lives in `profile.rs`).
   Threading return types down into the CFG is invasive.

## 3. Design overview

A dedicated, per-function inference that produces a `name -> TypeExpr` map from
call-result bindings, consumed by `complexity_facts`' receiver typing. It joins
two document-level sources, both available before resolution:

- **Same-file function returns:** reuse the existing `TypeDefinition` return
  types; build `return_type_by_name: BTreeMap<String, TypeExpr>` once per
  document and pass it into `facts()`.
- **Stdlib constructors:** a new adapter method
  `behavior.constructor_return_type(receiver, message) -> Option<String>`
  (`Vec::new` -> `Vec<_>`, `String::new` -> `String`, `Box::new` -> `Box<_>`,
  ...), gated on the concrete stdlib type so an arbitrary `T::new` is never
  blanket-typed.

The inference walks each method's `LASGN`/`DASGN` nodes (`[target, rhs]`), and
for every `local = call(receiver, message)` resolves the return type via the two
sources, adding `local -> T` to `augmented_parameter_types` (the map
`call_receiver_type` already consults). No new type store; no CFG change.

### Why this placement

- **Correct layer.** The consumer that needs local types for pricing is
  `complexity_facts`; return types are available one layer up (`profile.rs`) and
  pass down cleanly. Seeding the CFG flow layer (the "purest" single source)
  would require threading a return-type parser into the syntax layer — high cost,
  and the produced facts would still only benefit the same consumer today.
- **Genuinely new information.** Unlike an earlier reverted attempt that wired
  *declared* flow types into `call_receiver_type` (redundant — declared
  receivers were already typed), inferred call-result types are absent today, so
  this adds signal rather than duplicating it.
- **Elegant extension, not a parallel system.** It reuses `LASGN`/`DASGN`
  (already walked by `collect_assignments`), the existing `TypeDefinition` return
  types, the existing `augmented_parameter_types` seam, and the existing
  `rust.yml` method registry. A future step can export the same `name -> T` map
  as `inferred:` flow-type facts to make it the single source of truth for
  nil-kill/decomplex too (§8).

## 4. Components

### 4.1 `behavior.constructor_return_type` (adapter, new)

```rust
// normalized_behavior.rs (default None)
fn constructor_return_type(&self, _receiver: &str, _message: &str) -> Option<String> { None }
```

Rust adapter: `(Vec|VecDeque|LinkedList|BinaryHeap, new|with_capacity) -> "Vec<Value>"`
(the representative generic shape the nominal parser folds into the `Array`
family), `(String, new|with_capacity) -> "String"`, `(HashMap, new|with_capacity)
-> "HashMap<Value, Value>"`, `(HashSet, ...) -> "HashSet<Value>"`, `(BTreeMap,...)`,
`(BTreeSet,...)`, `(Box|Rc|Arc|Cell|RefCell|Mutex|RwLock, new) -> receiver` (the
wrapper is transparent for method dispatch; `Box<T>` derefs to `T`, but v1 types
it as the wrapper name, which is safe — its own methods are O(1)). Gated to these
names so a project `Foo::new` is never mistyped.

### 4.2 Document return-type map

Built in `profile.rs` where `type_definitions` are already produced, keyed by the
bare function name (dispatch name), value `TypeExpr`. Passed as a new parameter
to `complexity_facts::facts(document, &return_types)`. Same-name collisions
across owners resolve to the shared type or, if they differ, are dropped
(conservative — see §5).

### 4.3 Inference pass (complexity_facts, `fact_for_method`)

```
for each LASGN/DASGN node under the method:
    name = target child; rhs = value child
    if direct_call_message(rhs) is Some(message):
        receiver = call_receiver(rhs) text (may be empty)
        ty = constructor_return_type(receiver, message)         // stdlib
             or return_type_by_name[message]                    // same-file fn
        record candidate name -> ty
collapse candidates: a name with exactly one distinct inferred type is bound;
conflicting reassignments are dropped.
insert into augmented_parameter_types (never overriding a declared type).
```

This mirrors the existing receiver-alias / field-type augmentation already in
`fact_for_method`, and runs before `let parameter_types = &augmented_parameter_types`.

### 4.4 Consumption (unchanged)

`call_receiver_type("v")` now returns `Vec<Value>` -> `TypeExpr::Array`;
`behavior.call_complexity(Array, "push")` -> `linear_materialize` from `rust.yml`.
The function completes.

## 5. Correctness & edge cases

- **Reassignment / shadowing.** A name inferred to two different types is
  dropped (unique-type rule), so `let x = Vec::new(); x = other_fn();` never
  mis-prices. Declared types always win over inferred (`.or_insert`).
- **Blanket-constructor safety.** `constructor_return_type` is gated on concrete
  stdlib type names, so a project `Widget::new` (which may be O(n)) is never
  typed as O(1) or mis-dispatched.
- **Generics.** Return `Vec<Value>` folds to `Array` via the existing nominal
  parser; element type is irrelevant to method cost. `HashMap<Value, Value>`
  likewise.
- **Chained RHS** (`let v = foo().bar()`): `direct_call_message(rhs)` yields the
  outer call's message; its return type is used. Deeper inference is out of scope.
- **Language-neutrality.** The pass uses only neutral AST accessors
  (`direct_call_message`, `call_receiver`, `LASGN`/`DASGN`) and adapter-provided
  return types; the `complexity_fact_extractor_has_no_language_iterator_lexicon`
  guard holds. Non-static / no-return-type languages simply get an empty map.
- **No false completeness.** Inference only ever *adds* a receiver type that was
  previously unknown; it cannot change an already-priced call.

## 6. Testing

- Unit (rust adapter): `constructor_return_type(Vec,new)=Some("Vec<Value>")`,
  `(Widget,new)=None`.
- Oracle (`call_target_oracle` / `profile_oracle`):
  - `let mut v = Vec::new(); v.push(x); v.len()` -> function completes; `push` is
    `linear_materialize`, `len` is `O(1)`.
  - Same-file: `fn make()->Foo; let f = make(); f.work()` -> `work` resolves via
    `f: Foo`.
  - Negative: `let w = Widget::new(); w.work()` with `Widget::new` not O(1) stays
    correctly typed by resolution, not by constructor guess.
- Corpus: Rust stdlib complete% (expect a multi-point rise); Go/Java/Swift/C
  unchanged (no `constructor_return_type` override); full suite green.

## 7. Non-goals (v1)

- Cross-file project-constructor return types (needs post-resolution; a later
  pass can feed the same map).
- Exporting inferred types as `inferred:` flow facts for nil-kill/decomplex
  (clean follow-up once the map is proven).
- Full local type inference (only call-result RHS; not arithmetic/`as`/pattern
  bindings).
