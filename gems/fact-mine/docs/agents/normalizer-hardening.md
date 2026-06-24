# Normalizer Hardening Plan

**Goal:** Achieve ~95% test coverage for `src/ast/normalizer.rs`.

**Strategy:** Prioritize integration-style oracle tests and use unit tests as a fallback.

## Phase 1: Coverage Mapping & AST Role Extraction
We first map the uncovered lines in `normalizer.rs` to the specific `tree-sitter` node roles and types they are checking. 
* Instead of guessing, we use the `cobertura.xml` output from `cargo tarpaulin` to find exactly which `check_node_role(..., Role::X)` or `node.kind() == "Y"` branches are missing.
* We cross-reference these missing paths with the language adapters in `src/ast/adapters/` to know *which* language can trigger them (e.g., missing heredoc logic means we need Ruby/PHP snippets; missing `rescue` logic means we need Ruby).

## Phase 2: Data-Driven Integration/Oracle Harness (The Core Strategy)
Writing hundreds of manual unit tests for AST transformations is brittle. We will build a data-driven oracle test harness.
1. **Test Corpus Generation:** We create a directory structure like `tests/fixtures/normalizer/` containing diverse, targeted source code snippets across multiple languages (Ruby, JavaScript, Python, Go, PHP, etc.).
2. **The Harness:** We write a single Rust test driver that iterates through the corpus, parsing each snippet with the correct `tree-sitter` grammar and running `TreeSitterNormalizer::normalize()`.
3. **The Oracle:** The harness serializes the normalized output to an AST representation (e.g., JSON or a simplified string format) and compares it against a "golden" expected file. If the golden file is missing, it generates it. 
4. **Scaling Coverage:** As we find uncovered lines, we simply drop a new code snippet (e.g., a complex nested exception in Python or a multi-assignment in Go) into the corpus folder. The harness picks it up, runs it through the entire stack, and immediately spikes coverage.

## Phase 3: Language-Specific Snippet Injection
We will systematically go through the supported languages to trigger complex normalization paths:
* **Ruby:** Blocks, yields, complex `rescue`/`ensure`, heredocs, modifiers.
* **JavaScript/TypeScript:** Destructuring assignments, complex arrow functions, ternary operators.
* **Python:** List comprehensions, `try/except/finally`, decorators.
* **Go/Rust:** Switch/match statements, diverse loop structures.

## Phase 4: Targeted Unit Testing (The Fallback)
There will be ~5-10% of lines that the integration harness can't reach easily:
* Defensive programming checks (e.g., `if node.is_error()`).
* Internal helper methods that are conditionally executed based on bizarre state combinations.
* Fallback paths for broken ASTs.

For these, we will use `normalizer-test.rs`. Since creating synthetic `tree-sitter` nodes in memory is notoriously difficult, the strategy here is:
1. Parse a microscopic string to generate a valid `tree-sitter` node.
2. Instantiate the `TreeSitterNormalizer` manually.
3. Directly call the deep, isolated `normalize_xyz()` helper method on that specific node rather than starting from the top-level root.
