# FactMine-Espalier Integration

## Problem

Espalier currently mines facts through two independent code paths:

1. **`AstExtractor`** (`gems/espalier/lib/espalier/ast_extractor.rb`) -- calls
   `Decomplex::Syntax.parse()` / `doc.adapter.structural_facts(doc)` then builds
   module/method/state representations with effects and delegation edges in
   pure Ruby. Used by `dependency_graph.rb`, `architecture_analyzer.rb`,
   `privacy_analyzer.rb`.

2. **`FactMineStaticFacts`** (`gems/espalier/lib/espalier/fact_mine_static_facts.rb`) --
   builds a deeper set of facts (type definitions, hash shapes, protocols, param
   origins, dead nil checks, deterministic guards, return origins) on top of
   `FactMine::Syntax` structural facts. Used by `static_evidence.rb`.

These paths overlap: both parse, both extract structural facts, both walk state
read/write/call facts. The duplication means:
- Ruby-only execution (no path to Rust)
- Inconsistent fact shapes between the two paths
- Tests for fact correctness live in espalier, not fact-mine

## Target Architecture

```
                  Espalier
                     |
                     v
            FactMine (Rust binary)
          "espalier" profile
                     |
                     v
         Tree-sitter + normalized extractor
```

- **FactMine** becomes the single source of truth for ALL fact extraction.
- **Espalier** consumes facts from FactMine only -- it does zero parsing or
  tree-walking.
- FactMine supports **profiles** to control which facts are mined. The
  `"espalier"` profile produces exactly the fact-set Espalier needs.

## Fact Sets

### What Espalier needs

| Fact category | Used by | Gap (Rust FactMine) |
|---|---|---|
| `methods` (owner, name, kind, path, line, span, signature, params, visibility, source) | static_evidence, nil_kill_evidence | `Document` has `FunctionDef` but no visibility/source enrichment |
| `fields` (id, owner, name, type, line, span, declared_type) | static_evidence | `Document` has `StateDeclaration` + `StateWrite` but not merged into field records |
| `state_types` (owner\0field -> type) | static_evidence | Ruby `FactMineStaticFacts` produces this; Rust does not |
| `state_protocols` (owner\0field -> Set[message]) | static_evidence | Ruby `FactMineStaticFacts` produces this from call_sites; Rust does not |
| `state_param_origins` (owner\0field -> Set[param]) | static_evidence | Ruby only |
| `signatures` (owner\0name -> signature) | static_evidence | `FunctionDef.signature` exists but not indexed |
| `type_definitions` (method_signature, state_field, type_alias, included_module) | static_evidence, nil_kill | Ruby-only per-language logic. Rust needs language-specific type extraction (Sorbet sigs, Python annotations, TS types) |
| `hash_shapes` (path, line, keys, value_types) | static_evidence, nil_kill | Ruby walks Tree-sitter; Rust needs equivalent |
| `array_shapes` (path, line, tuple_types, size) | static_evidence | Ruby only |
| `struct_declarations` | static_evidence | Ruby only |
| Call-graph edges (internal, delegation) | dependency_graph, architecture_analyzer | `AstExtractor` builds from call_sites + state; Rust has `CallSite` but no graph edge synthesis |
| State-type edges (owner -> owner via typed fields) | dependency_graph | `AstExtractor` + `FactMineStaticFacts` produce `state_type_records`; Rust needs owner resolution |
| Effects (reads, writes per method) | dependency_graph | `AstExtractor` builds from state_reads/writes; Rust has raw facts |

### What FactMine already has in Rust

Rust `Document` struct already produces:
- `function_defs` (Vec\<FunctionDef\>) -- name, params, signature, line, span, visibility
- `owner_defs` (Vec\<OwnerDef\>) -- name, kind, line
- `state_declarations` (Vec\<StateDeclaration\>) -- field, owner, type, line
- `state_writes` (Vec\<StateWrite\>) -- field, receiver, owner, function, line
- `state_reads` (Vec\<StateRead\>) -- field, receiver, owner, function, line
- `call_sites` (Vec\<CallSite\>) -- receiver, message, owner, function, line
- `state_param_origins` (Vec\<...\>) -- field, owner, param

The gap is the **enrichment layer** -- what `FactMineStaticFacts` does on top of
raw structural facts: canonicalizing names, classifying receivers, building
protocol indexes, type extraction from language-specific annotations, hash shape
walking, etc.

## Phase 1: Move `FactMineStaticFacts` into fact-mine

Move `gems/espalier/lib/espalier/fact_mine_static_facts.rb` into
`gems/fact-mine/lib/fact_mine/` as a new module (e.g.,
`FactMine::EnrichedFacts` or `FactMine::EspalierProfile`).

### Interface (Ruby)

```ruby
# Before (in Espalier):
facts = Espalier::FactMineStaticFacts.build(document, structural_facts, root: root)

# After (in Espalier):
facts = FactMine::Profile.espalier(document, root: root)
# or: FactMine::Profile.build(document, profile: :espalier, root: root)
```

The `profile` parameter controls the fact-set returned:
- `:espalier` -- methods, fields, state_types, state_protocols,
  state_param_origins, signatures, type_definitions, hash_shapes, array_shapes,
  struct_declarations, call-graph edges, state-type edges
- `:nil_kill` (default/full) -- all of the above + tlet_sites, dead_nil_checks,
  deterministic_guards, return_origins, noreturn_methods, collection_index_lookups,
  hash_record_blockers

### What moves

All of `fact_mine_static_facts.rb` (~2100 lines) moves to `gems/fact-mine/lib/fact_mine/`.
Espalier gets a thin require + delegation shim during the transition.

## Phase 2: Replicate in Rust FactMine

Build the enrichment layer in `gems/fact-mine/rust/src/` that mirrors what
the Ruby `FactMine::Profile` produces.

### New module: `fact_mine_rust::profile`

```rust
// gems/fact-mine/rust/src/profile.rs

pub enum Profile {
    Espalier,
    NilKill,
}

pub struct ProfileOutput {
    pub methods: Vec<MethodRecord>,
    pub fields: Vec<FieldRecord>,
    pub state_types: BTreeMap<String, String>,
    pub state_protocols: BTreeMap<String, Vec<String>>,
    pub state_param_origins: BTreeMap<String, Vec<String>>,
    pub signatures: BTreeMap<String, String>,
    pub type_definitions: Vec<TypeDefinition>,
    pub hash_shapes: Vec<HashShape>,
    pub array_shapes: Vec<ArrayShape>,
    pub struct_declarations: Vec<StructDeclaration>,
    pub call_graph: CallGraph,
    pub state_type_edges: Vec<StateTypeEdge>,
}

pub fn extract(document: &Document, profile: Profile, root: &Path) -> ProfileOutput {
    // ...
}
```

### What needs to be built (by category)

**Enrichment layer** (language-agnostic):
- Method record building: canonical owner, kind classification, visibility from
  directives, source/signature assembly
- Field record building: merge state_declarations + state_writes, deduplicate,
  resolve declared types
- State protocol building: group call_sites by receiver, resolve receiver to
  state field, build protocol sets
- State param origin building: group state_param_origins by owner+field
- Hash shape walking: detect hash literals in the tree, extract key-value type pairs
- Array shape walking: detect array literals, extract element types
- Call-graph edge synthesis: internal calls, delegation from call_sites,
  state-type edges from typed fields

**Language-specific type extraction** (needed for type_definitions):
- **Ruby**: Sorbet sig parsing (`sig { params(x: Type).returns(Type) }`),
  `T::Struct` field types, `T.type_alias`, `Struct.new` fields, included modules
- **Python**: PEP 484 annotations (`def f(x: int) -> str`), dataclass fields,
  `TypeAlias`, stub files (`.pyi`)
- **TypeScript**: interface/type annotations, `type X = ...`, class fields
- **Go, Rust, Zig, C, C++, Java, Kotlin, Swift, Lua, PHP, C#**: basic
  signature extraction where annotations exist

**Hash/array shape walking**:
- Tree-sitter node walking to find hash/dict/object literal nodes
- Extract key names (string, symbol, identifier)
- Resolve value types from literal type inference
- Handle nested shapes (array of hashes, hash of arrays)

### Binary interface

The `fact-mine-rust` binary gets a new command:

```bash
fact-mine-rust profile espalier --root /repo --output out.json src/**/*.rb
fact-mine-rust profile nil-kill --root /repo --output out.json src/**/*.rb
```

Output is a JSON blob matching the `ProfileOutput` struct. Espalier's Ruby code
shells out to the binary and loads the JSON.

## Phase 3: Wire Espalier to Rust FactMine

### `Espalier::StaticEvidence` changes

```ruby
def build
  if rust_binary_available?
    output = Tempfile.new(["espalier-facts", ".json"])
    system(rust_binary, "profile", "espalier",
           "--root", @root,
           "--output", output.path,
           *target_files)
    facts = JSON.parse(File.read(output.path))
  else
    # Fallback to Ruby FactMine::Profile.espalier(...)
  end
  # ... rest of build uses facts hash directly
end
```

### `Espalier::AstExtractor` changes

The `AstExtractor` is replaced by consuming call-graph edges + state-type edges
from FactMine's profile output. The `dependency_graph.rb` Builder reads these
edges directly instead of walking raw structural facts.

### Backward compatibility

- FactMine Ruby remains as a fallback (development, environments without Rust)
- `--fact-mine-backend=rust|ruby` flag on the Espalier CLI
- CI always uses Rust

## Phased Rollout

| Phase | What ships | Risk |
|---|---|---|
| 0 (now) | Design doc approved | None |
| 1 | Move `fact_mine_static_facts.rb` into fact-mine gem, add `Profile` module with `:espalier` / `:nil_kill` | Low -- code moves, tests move, thin shim in espalier |
| 2a | Rust enrichment layer: methods, fields, signatures, state_types | Medium -- new Rust code, cross-language parity |
| 2b | Rust enrichment layer: type_definitions (Ruby Sorbet first, then Python/TS) | High -- per-language type extraction is complex, needs oracle tests |
| 2c | Rust enrichment layer: hash_shapes, array_shapes, struct_declarations | Medium -- tree-walking parity |
| 2d | Rust enrichment layer: call-graph edges, state-type edges | Medium -- edge synthesis from raw facts |
| 3a | Espalier shell-out to fact-mine-rust binary | Low -- JSON I/O, fallback path exists |
| 3b | CI switch to Rust backend | Low -- single flag change |
| 4 | Remove Ruby fallback once Rust is stable for 2 releases | Low |

## Acceptance Criteria

1. `FactMine::Profile.espalier(document)` returns the exact same fact shape as
   `Espalier::FactMineStaticFacts.build(document, facts)` currently does (Ruby parity)
2. `fact-mine-rust profile espalier` returns identical JSON for a given file set
   (Rust parity, verified by oracle tests)
3. All existing espalier tests pass with both backends
4. CI `decomplex-rust-test` job covers the new Rust profile code