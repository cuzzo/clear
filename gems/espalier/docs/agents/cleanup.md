# Espalier Cleanup Findings

Based on `Decomplex` and `Espalier` runs on the `espalier` gem, the following areas require refactoring to reduce complexity, consolidate logic, and eliminate structural debt.

## Priority 1: State Re-Derivation and Owner Stamps (Root Causes)

The architecture exhibits the 'Invariant #16 Desync Shape', meaning key contextual state like `language`, `owner`, and `file` are dynamically recomputed or fall back defensively rather than being determined once and stamped onto the target model. 

1. **`language` Propagation Desync**
   - **Locations:** `static_evidence.rb:45`, `static_evidence.rb:122` (`project_modules`), `static_evidence.rb:460-461` (`rbi_field_type_records`)
   - **Finding:** Flagged by 4 detectors. Currently, `project_modules` derives the module's `language` by looking at the first method, then falling back to the first field.
   - **Action:** Single-source this state. When a module model is created, compute the language exactly once and guarantee its presence (or lack thereof), rather than sprinkling `first_meth ? first_meth[:language] : ...` across the system.

2. **`owner` Propagation Desync**
   - **Locations:** `static_evidence.rb:118` (`project_modules`), `nil_kill_evidence.rb:45-51` (`apply!`)
   - **Finding:** Flagged by 4 detectors. Ownership logic contains defensive branching and nil-checks. 
   - **Action:** Similar to `language`, formalize the `owner` object/hash immediately and pass it down reliably without re-derivation.

3. **`file` and `vcs` Scattered Inference**
   - **Locations:** `type_profile.rb:509-511` (`source_file?`), `graphviz_formatter.rb:180` (`tooltip_for`), `static_evidence.rb:336-496` (VCS mapping).
   - **Finding:** 3 detectors flagged defensive IO/file resolution checks scattered.
   - **Action:** Perform directory/repo resolution centrally and pass verified paths to these modules instead of performing `exist?` or `directory?` deeply inside them.

## Priority 2: Method-Level Complexity (Refactoring Targets)

1. **`build_from_rust_facts` (in `static_evidence.rb:150-242`)**
   - **Finding:** Flagged by 5 detectors (Decision Pressure, Derived-State Staleness, False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity). It hides 17.2 cognitive points across multiple helpers.
   - **Action:** This is the core engine entrypoint. Decompose it into explicit, smaller phases (e.g., rust runner, fact loader, projection builder) with explicitly passed DTOs rather than one orchestration method juggling local variables.

2. **`parser_for` (in `tree_sitter.rb:44-79`)**
   - **Finding:** Flagged by 4 detectors for Locality Drag and False Simplicity. 
   - **Action:** The method initializes `roots` at line 44 but doesn't use it until line 69, with unrelated OS/Architecture checks in between. Reorder the setup to eliminate the locality drag gap. Move OS and Arch resolution to constants or a separate method.

3. **`excluded_path?` (in `type_profile.rb:516-518`)**
   - **Finding:** Flagged by 4 detectors for Function LCOM (Lack of Cohesion) and Operational Discontinuity.
   - **Action:** The method has two distinct components doing disjoint data-flow work (processing inclusion patterns vs exclusion logic). Split this out into two single-responsibility predicates.

4. **`collect_state_properties` (in `aggregator.rb:160`)**
   - **Finding:** 3 detectors. Constant resolution string interpolations (e.g. `["#{class_name}::STATE_CO_UPDATE"]`) add decision pressure and state-branch density. 
   - **Action:** Normalize these constant references beforehand rather than interpolating strings inline repeatedly.

## Priority 3: Eliminate "False Simplicity" File/IO calls

- **`File.exist?`, `File.directory?`, `File.extname`, `Pathname.new`** scatter across 36 units.
- **Action:** `espalier` runs tightly bound to the file system. Rather than having the `Aggregator`, `TypeProfile`, and `Reporter` individually checking file properties or building paths, centralize this in a `Workspace` or `ProjectDirectory` object that provides safe, pre-verified properties to the rest of the application.
