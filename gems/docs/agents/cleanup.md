# Gems Cleanup Roadmap

## 1. Oracle Tests Verification & Decomplex/Fact-Mine Ruby Deletion
- [x] **TODO: Discovery Needed** - Verify if `decomplex-rust` and `fact-mine-rust` currently run the oracle tests.
- [x] **TODO: Discovery Needed** - If Rust code runs oracles, verify if it runs on GitHub CI.
- [x] **Action**: Ensure oracle tests are preserved and running (keep Ruby tests around to run oracles if Rust isn't running them).
- [x] **Action**: Delete `gems/decomplex` and `gems/fact-mine` Ruby code (once SlopCop/Boobytrap are fully decoupled and oracles are secured).

## 2. Restore Broken Tests in `gems/`
- [x] **Action**: Identify and fix the `gems/` tests that were turned off/broken due to the recent merge into `master` and failed attempts to fix them on this branch.
- [x] **Action**: Fix failing tests in `gems/decomplex` (Start by looking at `FatUnionTest` and work outwards).

## 3. Espalier Migration (The Model)
- [x] **Action**: Green-light all tests in `espalier` that are currently skipped due to the partial Fact-Mine Rust migration.
- [x] **Architecture Check**: Ensure `espalier` gets its facts from `Fact-Mine` and does ZERO parsing of un-normalized AST data.
- [x] **Architecture Check**: Ensure `espalier` has zero requirements on Ruby `fact-mine` and `decomplex` logic.
- [x] **Test Coverage**: Ensure everything the Rust code does for Espalier has >95% line coverage predominantly via INTEGRATION tests.

## 4. SlopCop and BoobyTrap Migration
- [x] **Action**: Migrate `SlopCop` and `BoobyTrap` to the exact same style as Espalier.
- [x] **Architecture Check**: They must require a fact-mine file directly rather than requiring `fact-mine` indirectly or requiring `decomplex` directly.
- [x] **Architecture Check**: Ensure ZERO parsing of un-normalized AST data.
- [x] **Action**: Move necessary `decomplex` code (like SARIF functionality) directly into `SlopCop`.
- [x] **Test Coverage**: Ensure >95% line coverage for the Rust integration logic predominantly via INTEGRATION tests.


## 5. Nil-Kill Cleanup (Deferred)
- [x] **TODO: Discovery Needed** - Investigate `gems/nil-kill`'s broken state after haphazardly migrating static analysis fact-mining into `gems/espalier`.
- [x] **Action**: Restore functionality to `source_index` (which did the fact-mining it needs).
- [x] **Architecture Check**: Ensure Nil-kill also follows the architectural rule: get facts from Fact-Mine, ZERO parsing of un-normalized AST data, zero requirements on Ruby fact-mine/decomplex logic.

## 6. Coverage Goal Checklist
- [x] **Action**: Verify >95% line coverage for Rust code execution across the tools, leaning heavily on integration tests rather than unit tests.

## 7. Post-Migration Decomplex Audit & Tech Debt Epic
- [x] **Action**: Once Decomplex is working in Rust, passing all tests, and has adequate coverage for Fact-Mine and Decomplex in general (specifically for Ruby), run Decomplex on each repository.
- [x] **Action**: Add a new task (or epic) to clean up obvious, major tech debt uncovered by this run.
- [x] **Constraint**: Do NOT change the architecture of Decomplex or Fact-Mine.

## 8. Post-Espalier Architecture Sweep
- [x] **Action**: Once Espalier is working, review all gems from the beginning and create tasks or epics to clean up any major issues/tech-debt uncovered during the migration.

## 9. Nil-Kill Spec TODOs & Investigation items
- [ ] **Action**: Investigate unused return void type promotion sig fix at [nil_kill_spec.rb:L2294](file:///home/yahn/cheat/gems/nil-kill/spec/nil_kill_spec.rb#L2294).
- [ ] **Action**: Investigate always-raising untyped returns signature promotion to verifiable T.noreturn (currently void) at [nil_kill_spec.rb:L2327](file:///home/yahn/cheat/gems/nil-kill/spec/nil_kill_spec.rb#L2327).
- [ ] **Action**: Fix commented out assertion for using indexed hash-record escape facts when available at [nil_kill_spec.rb:L2651](file:///home/yahn/cheat/gems/nil-kill/spec/nil_kill_spec.rb#L2651).
- [ ] **Action**: Investigate why unused_wrapper returns `"source_kind" => "unknown source"` instead of the actual source at [nil_kill_spec.rb:L3453](file:///home/yahn/cheat/gems/nil-kill/spec/nil_kill_spec.rb#L3453).

## 10. Decomplex and Espalier Audit Task List
- [x] **Action**: Run Decomplex on Decomplex and Fact-Mine repositories, verifying correct execution and expected execution times (~0.3s and ~1.0s).
- [x] **Action**: Run Espalier on Decomplex and Fact-Mine repositories, verifying successful compilation and output.
- [x] **Action**: Compile file LoC and branch coverage lists for Decomplex and Fact-Mine.
- [x] **Action**: Spot-check Decomplex findings and document sloppy implementation/tech debt.


