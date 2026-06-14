# Nil-Kill Generalization Gap Analysis

This document identifies the remaining Ruby-specific and Sorbet-specific "tendrils" in `nil-kill` that must be abstracted to achieve true multi-language capability.

## 1. Executive Summary

While `nil-kill` has a solid `Provider` registry architecture, the **Inference Engine** and **Evidence Extraction** layers remain heavily coupled to the Ruby/Sorbet ecosystem. To support "General Purpose Code Changing," the gem must move from "Ruby-as-Primary" to a "Universal Semantic Fact" model.

## 2. Critical Generalization Gaps

### A. Evidence Extraction (The Z3 Pipeline)
- **Current State:** `static_evidence.rb` and `infer.rb` rely on Prism (Ruby AST) to extract facts like null-guards (`if x.nil?`), assignments, and local aliasing.
- **The Gap:** There is no generic "Evidence Provider" interface.
- **Requirement:** Abstract AST-walking for Z3 facts into the `Language::Provider`. A Python provider must be able to map `if x is None` to the same semantic fact that Ruby’s `if x.nil?` currently generates.

### B. Type Definition Indexing (Sorbet/RBI)
- **Current State:** `rbi_return_index.rb` and `struct_rbi.rb` are dedicated to parsing Sorbet `.rbi` files and `sig` blocks.
- **The Gap:** "Type Pressure" calculation is hardcoded to look for Sorbet signatures.
- **Requirement:** Generalize the "Type Indexer" to look for language-native type declarations (e.g., TypeScript `interface`, Go `struct`, Python `typing`).

### C. Runtime Instrumentation (The "In-Place" Strategy)
- **Current State:** `SourceInstrumenter` uses an "In-Place" strategy, overwriting Ruby source files with wrapped versions that use `TracePoint` and `Coverage`.
- **The Gap:** This strategy is designed around Ruby’s load-path semantics (`require`, `autoload`). It does not translate easily to compiled languages (Zig, Go) or even differently-structured interpreted languages.
- **Requirement:** The "Collection Strategy" must be fully owned by the `Language::Provider`. The core should only care about the resulting JSON event stream.

### D. Coverage Format Coupling
- **Current State:** Nil-kill uses `SimpleCov` results to identify "untraced" or "unreachable" code.
- **The Gap:** It lacks a generic parser for industry-standard coverage formats like `LCOV` or `gcov`.
- **Requirement:** Integrate with the generalized coverage providers being built in `Boobytrap`.

## 3. The "Final Boss": General-Purpose Autofix
- **Current State:** All code-changing logic (`lib/nil_kill/autofix/`) is implemented as Ruby AST transformations.
- **The Gap:** To fix code in JS or Python, `nil-kill` would currently need an entirely parallel set of rewriters.
- **Proposed Solution:** Implement a **Hybrid LLM-Driven Autofix** model:
  1. **Surgical Fact:** Use the generalized static analysis to find the exact file/line/span needing a fix.
  2. **Provider Template:** The `Language::Provider` provides the *idiomatic* template for the fix (e.g., `return nil if x.nil?` vs `if x is None: return None`).
  3. **LLM Execution:** Orchestrate an LLM to apply the transformation using the surgical fact and the idiomatic template.

## 4. Priority Roadmap

1. **Phase 1: Fact Abstraction.** Move Z3 evidence extraction from `static_evidence.rb` into the `Language::Provider` interface.
2. **Phase 2: Type Indexer Generalization.** Create a generic interface for "External Type Definitions" (replacing the RBI-only logic).
3. **Phase 3: Integration with Boobytrap.** Swap Ruby-specific coverage loading for the generalized Boobytrap provider registry.
4. **Phase 4: Multi-Language Autofix.** Implement the first Python null-guard autofix using the Hybrid LLM model.

## 5. Conclusion

`nil-kill` is the most semantically complex gem in the suite. By abstracting the **Evidence Extraction** and **Code Transformation** layers, it will transform from a "Ruby Type-Fixer" into a "Universal Nil-Drift Elimination Engine."
