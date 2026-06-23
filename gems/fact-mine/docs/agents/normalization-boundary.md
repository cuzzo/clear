# Normalization Boundary Between Fact-Mine and Decomplex

## 1. Executive Summary & Root Cause

The normalization phase in `fact-mine` is failing to normalize language-specific details at the mining stage. Instead, raw syntactic markers leak downstream into the JSON facts. As a result, downstream detectors in `decomplex` must use language-specific `Dialect` dispatches to strip these markers (such as `@`, `self.`, or `!/?/=`) before doing equivalence checks.

This creates substantial technical debt:
- Generic detectors are coupled to language-specific syntaxes.
- Testing requires cross-multiplying every detector against every language's syntax markers to prevent regressions.
- The boundary between raw extraction and semantic fact mining is blurred.

The correct architectural boundary is:
- **`fact-mine`** must produce clean, normalized, language-agnostic facts.
- **`decomplex`** generic detectors must consume only normalized names and attributes, with zero awareness of language-specific sigils or prefixes.

---

## 2. Leakage Instances

The following five major categories of syntactic leakage have been identified in the codebase:

### I. Ruby Instance Variables (`@` prefix)
- **Source Location**: `gems/fact-mine/rust/src/syntax/normalized_extractor.rs` at `record_state_read_node` (line 708) and `record_state_write` (line 625).
- **Leakage Mechanism**: For `IVAR`/`GVAR` nodes, the symbol/string value (like `@foo` or `$bar`) is extracted directly using `first_string_or_symbol(node)`. This leads to `StateRead` and `StateWrite` facts containing raw `@foo` / `$bar` strings in the `field` attribute.
- **Downstream Impact**: `decomplex` detectors (such as `state_mesh.rs` at line 573) must call `dialect.clean_identifier(attr)` which removes `@`.

### II. Python Instance Variables (`self.` prefix)
- **Source Location**: `gems/fact-mine/rust/src/syntax/python.rs` at `dotted_member_reads` and `embedded_member_reads`.
- **Leakage Mechanism**: Python attributes are not mapped to `IVAR` nodes in `normalizer.rs`. Instead, `python.rs` extracts state reads and writes using a textual parser `dotted_member_reads` which parses expressions like `self.foo` or nested ones like `self.bar.baz`.
- **Nested Assignment**: If a nested reference like `self.bar.baz` is assigned (`self.bar.baz = 1`), `receiver_text` on the receiver `self.bar` returns the formatted string `"self.bar"`. Thus, `StateWrite` records receiver as `"self.bar"` and field as `"baz"`.
- **Downstream Impact**: `Dialect::is_ivar` must check for `"self."` prefix, and `clean_identifier` must strip `"self."`.

### III. Call Receivers with Syntactic Prefixes (`self.`)
- **Source Location**: `gems/fact-mine/rust/src/syntax/normalized_extractor.rs` at `call_source_text` and `receiver_text`.
- **Leakage Mechanism**: For nested calls like `self.foo().bar()`, the receiver is `self.foo()`, which is formatted using `self_member_receiver` to prefix it with `"self."` (or `"self->"` in C). Thus, the call receiver field in the JSON facts retains the `"self."` prefix.
- **Downstream Impact**: `decomplex` detectors must handle call receivers containing `"self."` prefixes.

### IV. Class/Singleton Methods (`self.` prefix)
- **Source Location**: `gems/fact-mine/rust/src/syntax/local_flow.rs` at `method_name` (line 422).
- **Leakage Mechanism**: For Ruby `DEFS` nodes (singleton class methods, e.g., `def self.foo`), `method_name` prefixes the method name with `"self."` (e.g. `"self.foo"`). This means class method names in `MethodSummary` or `FunctionDef` facts contain the raw `"self."` prefix.
- **Downstream Impact**: `structural_topology.rs` in `decomplex` uses `dialect.scoped_name` to append `"self."` to target names when calling class methods.

### V. Ruby Query, Mutation, and Setter Sigils (`?`, `!`, `=`)
- **Source Location**: `gems/fact-mine/rust/src/syntax/local_flow.rs` at `method_name` (line 422) and `gems/fact-mine/rust/src/syntax/normalized_extractor.rs` / `CallSite` extraction.
- **Leakage Mechanism**: Ruby method definitions and calls retain the trailing sigils `?` (query), `!` (mutation), and `=` (setter) directly in their names/messages (e.g., `nil?`, `save!`, `name=`).
- **Downstream Impact**: `inconsistent_rename_clone.rs`, `state_mesh.rs`, and others must strip these sigils before checking equivalence or identifying valid identifiers (via `Dialect::is_identifier` and `Dialect::clean_identifier`).

---

## 3. Investigation and Remediation Plan

To thoroughly investigate and decomplex the code, the following structured remediation plan should be executed:

### Phase 1: Deep Codebase Clue Search
1. **Audit AST Normalization Adapters**:
   - Inspect all files under `gems/fact-mine/rust/src/ast/adapters/` (e.g. `python.rs`, `ruby.rs`, `lua.rs`, `go.rs`) to verify where instance variables are mapped.
   - Investigate why `state_field_name` is only implemented for C-like languages and PHP, forcing Ruby and Python to map instance variables textually or skip `IVAR` mapping.
2. **Scan Extractor Output & Tests**:
   - Write a helper script to scan all pre-mined `.json` test fixtures (such as those in `transpile-tests/`) and check for keys/fields containing `@`, `self.`, `!`, `?`, or `=`.

### Phase 2: Fact-Mine Normalization Refactoring
1. **Unify Instance Variable Representation**:
   - Modify the Python AST adapter (`ast/adapters/python.rs`) and normalizer (`normalizer.rs`) to map `self.foo` accesses to `IVAR` nodes, with a clean name `"foo"`.
   - Modify the Ruby normalizer to output clean string/symbol names (stripping `@`) for `IVAR`/`GVAR`/`IASGN`/`GASGN` nodes.
   - Introduce a semantic property `scope: :global` or `scope: :instance` on variable declarations/reads/writes instead of encoding it via sigils.
2. **Normalize Call Receivers & Message Names**:
   - Strip `"self."` / `"this."` prefixes from call receivers at extraction time. A call on the current instance should always have `receiver: "self"` or be identified by a boolean `is_self_call: true`.
   - Strip query/mutation/setter sigils from Ruby method names at extraction time.
   - Introduce explicit metadata flags in `CallSite` and `FunctionDef`:
     - `is_query: bool` (for `?` sigils)
     - `is_mutation: bool` (for `!` sigils)
     - `is_setter: bool` (for `=` sigils)
     - `is_class_method: bool` (for Ruby `DEFS` or Python classmethods, eliminating the need to prepend `self.`)

### Phase 3: Decomplex Cleanup
1. **Remove Language Dialect Dispatches**:
   - Deprecate `gems/decomplex/rust/src/decomplex/dialect.rs`.
   - Simplify detectors (like `state_mesh.rs`, `inconsistent_rename_clone.rs`, and `structural_topology.rs`) to operate directly on the clean, normalized strings.
   - Update testing suite to remove dialect cross-multiplication.
