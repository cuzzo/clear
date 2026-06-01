# Espalier Design: Architectural Representation and Semantic Abstraction

This document outlines the design for **Espalier**, a framework and tool designed to extract high-level architectural models, method behavioral boundaries, and structural delegations from codebases. Rather than choking Large Language Models (LLMs) with full-source text, control-flow graph (CFG) listings, or data-flow graph (DFG) matrices, Espalier filters and abstracts programs down to **Intent**, **Capabilities/State Ownership**, **Effects**, and **Delegations**.

---

## 1. Why Espalier?

When analyzing large codebases, feeding raw code or fine-grained compiler representations (like standard basic-block control flow graphs) to LLMs suffers from three core issues:
1. **Context Window Saturation:** Real-world implementations contain excessive boilerplate, logging, error check checks, and formatting, exhausting token limits.
2. **Computational Redundancy:** LLMs are excellent at synthesizing conceptual code, but remarkably poor at executing low-level topological sorts or path-traversal algorithms across highly detailed graph syntax trees.
3. **The Noise-to-Signal Gap:** An architectural review cares about *boundary contracts*, *side effects*, and *delegation patterns* (Who owns the state? Who mutates it? Who coordinates/delegates?). Most tools either emit too little (bare folder directory tree-structure) or too much (complete AST or full-text dump).

**Espalier** builds an "espaliered" (flat, trained, structural, and clean) view of code. It focuses on:
- **State Ownership:** What variables/structures hold state, and what is their sync/capability wrapper?
- **Effects:** Direct reads and writes to owned state.
- **Delegations:** Clean paths of responsibility (calls to other domain elements, loops, and conditions scoped as coordination, not logic blocks).

---

## 2. The Architectural Manifest Format

Espalier generates a structured document (in YAML, JSON, or Markdown) following this signature layout for every target module/class:

```yaml
module: MIR::MIRLowering
  file: src/mir/mir_lowering.rb
  responsibility: "Single entity responsible for all heap allocation, promote-to-heap, and cleanup policy decisions for the compiler passes. Lowers high-level AST constructions to explicit compiler instructions."
  
  state:
    - @bindings: Hash[String, SymbolEntry]
      sync: :local
      access:
        - writes: initialize, bind_local!, unbind_local!
        - reads: lookup_binding
    - @scope_stack: Array[Scope]
      sync: :local
      access:
        - writes: push_scope!, pop_scope!
        - reads: current_scope, resolve_local

  functions:
    - name: bind_local!(name, type)
      signature: "def bind_local!(name: String, type: TypeInfo) -> SymbolEntry"
      EFFECTS:
        reads: [@scope_stack]
        writes: [@bindings, @scope_stack]
      DELEGATIONS:
        - always calls: MIR::SymbolEntry.new
        - conditionally calls: push_err_cleanup_for_binding!  # if ownership transfers
        - updates: @bindings
      quality_metrics:
        complexity: high (decomplex: 1.2 deviance)
        churn_risk: low (boobytrap: 0.1)

    - name: lower_ast_node(node)
      signature: "def lower_ast_node(node: AST::Node) -> MIR::Node"
      EFFECTS:
        reads: [@scope_stack, @bindings]
        writes: [] # pure coordinator
      DELEGATIONS:
        - switches: node.type (AST::Alloc -> lower_alloc_node, AST::Assign -> lower_assign_node)
        - always calls: verify_ownership_graph!
```

---

## 3. Data Extraction Pipeline

Espalier relies on a combination of lightweight static parsing, historical context, and specialized data-source engines to map out **Effects** and **Delegations**.

```
+---------------------------------------------------------------------------------+
|                                 INPUT SOURCES                                   |
+-------------+---------------------+-------------------+-------------------------+
              |                     |                   |
    [Tree-sitter Parser]    [Decomplex Gem]     [Nil-kill Gem]    [Boobytrap / Slopcop]
              |                     |                   |                     |
              v                     v                   v                     v
      AST, Signatures,       Re-derived logic,     Concrete Type        Churn-to-risk,
      Class Definitions,      Duplicated Paths,    Annotations &        Uncovered Gaps,
      Call Graph Nodes        "False Simplicity"   Control Shapes       Branch Pathology
              |                     |                   |                     |
              +---------------------+---------+---------+---------------------+
                                              |
                                              v
                              +-------------------------------+
                              |       Espalier Synthesizer    |
                              +-------------------------------+
                                              |
                                              v
                              +-------------------------------+
                              |     Architectural Manifest    |
                              +-------------------------------+
```

---

## 4. Synthesis of Sibling Gem Capabilities

Espalier leverages our adjacent static-analysis and runtime tools to enrich the Manifest:

### 4.1 Tree-sitter (The Structural Foundation)
* **What it does:** Generates extremely fast concrete syntax trees for files, with multi-language capabilities.
* **Espalier's consumption:**
  * Defines outer modular boundaries: class and module definitions, method names, parameters, and return signatures.
  * Discards private method implementations, comments, and boilerplate to establish the skeleton.
  * Parses instance variable assignments (`@variable_name = ...`) to identify the class's **State** registry.

### 4.2 Decomplex (The Logic and Sequence Analyst)
* **What it does:** Mines decision frequency across sites, detects "scatter" (shared decision tuples), and isolates "False Simplicity" (hidden side-effects, implicit dependencies, dynamic dispatch).
* **Espalier's consumption for EFFECTS and DELEGATIONS:**
  * **False Simplicity Identification:** Decomplex identifies if a function relies on implicit dynamic dispatch, global environment maps, or dynamic metaprogramming. Espalier tags these functions as `EFFECTS: reads: env / globals` or `DELEGATIONS: dynamic_dispatch`.
  * **Inconsistent Updates (CoUpdate):** If Decomplex reveals that `@storage` and `@provenance` are co-written in 9 out of 10 methods, but one method misses it, Espalier flags this relationship under the State ownership layout:
    ```yaml
    state:
      - @storage: (co-updates with @provenance)
    ```
  * **Broken Protocols:** If Decomplex identifies standard call-order protocols, Espalier flags them within Delegations (e.g., "always calls: `open(...)`, then always calls: `write_header(...)`").

### 4.3 Nil-kill (The Concrete Contract Provider)
* **What it does:** Fuses Sorbet-style static typing with production runtime logs and z3 inputs to strongly type untyped variables, eliminate nils, and analyze branchless/typed "Control Shapes."
* **Espalier's consumption for EFFECTS and DELEGATIONS:**
  * **Narrow / True Type Signatures:** Resolves untyped structures. Instead of `def connect(id, socket)`, Nil-kill feeds Espalier: `def connect(id: String, socket: TCPSocket)`.
  * **Control Shapes Integration:** Nil-kill marks whether a function has a high ratio of branchless control flow. A branchless function is tagged with `EFFECTS: pure` or is mapped to direct linear state transitions.
  * **Hash-to-Struct Promotion:** Nil-kill tracks nested hash shape flows (`{category, severity}`). Espalier uses this to model ephemeral parameters as structural data shapes rather than blobs.

### 4.4 Boobytrap & Slopcop (The Churn and Quality Overlay)
* **What they do:** Boobytrap integrates git-churn history (Google Bugspots algorithm) with branch coverage to identify untested churn hotspots. Slopcop categorizes dark branch areas as `genuine` gaps or defensive blocks, ranking them by fix risk.
* **Espalier's consumption:**
  * Adds risk-scoring metadata directly alongside functions.
  * If a method has high bugspot scores and an open simplecov branch gap, Espalier tags it:
    ```yaml
    quality_metrics:
      churn_risk: HIGH
      uncovered_execution_arms: "genuine (Category: Slopcop)"
    ```
  * Tells the architectural LLM: "This specific coordinating block is fragile, poorly-tested, and has been edited 14 times for bug fixes. Prioritize reviewing its delegation safety."

---

## 5. Architectural Metrics & Heuristics

When Espalier generates a Manifest, it runs local structural heuristics to compute architectural cohesion:

1. **State Cohesion Index (SCI):**
   $$\text{SCI} = \frac{\sum_{f \in F} |S_f|}{|F| \times |S|}$$
   Where $F$ is the set of functions, $S_f$ is the subset of state variables modified/read by function $f$, and $S$ is the total state variables of the class.
   * *High SCI ($\ge 0.6$)*: Cohesive, focused capsule.
   * *Low SCI ($\le 0.15$)*: Potential "God Object." The class acts as a bucket for disjoint state. Suggest split.

2. **Policy vs. Mechanism Separation:**
   * **Mechanism Functions:** High state direct modification (`writes`), zero external system delegations.
   * **Policy/Coordinator Functions:** Zero state direct modification (`writes: []`), high `DELEGATIONS` to other classes or internal mechanism functions.
   * *Violation*: A function with high direct `writes` *and* deep system `DELEGATIONS`. This violates clean layer separation and should be flagged for refactoring.

3. **Dependency Coupling Inversion:**
   * Tracks target modular delegations. If lower-level helpers delegate upward to orchestrators, alert on circular delegation flows.

---

## 6. Practical Ruby Extraction Strategy

To build Espalier for Ruby without writing a full compiler frontend, we implement a multi-source metadata processor:

```ruby
module Espalier
  class Extractor
    def initialize(root_path)
      @root = root_path
      # Initialize connections to sibling directories/databases if present
      @decomplex_data = load_decomplex_report
      @nil_kill_data  = load_nil_kill_signatures
      @boobytrap_data = load_boobytrap_hotspots
    end

    def extract_file(file_path)
      ast = Prism.parse_file(file_path).value # Use Prism, modern Ruby's core parser
      
      # 1. Gather class/module structures
      # 2. Extract state variables via instance assign nodes (@...)
      # 3. Analyze local method boundaries
      # 4. Synthesize EFFECTS by analyzing lvars, ivars, and constants
      # 5. Synthesize DELEGATIONS from nested CallNodes
      # 6. Merge Decomplex, Nil-kill, and Boobytrap annotations
    end
  end
end
```

By presenting relationships in this cleaned, signature-driven format, LLMs are equipped with the structural facts they need to perform elite-level architectural evaluations at a fraction of the token cost, with near-zero noise.
