# Formal Verification / Fuzz Suite Hardening

Goal: make `tools/fuzz` an A-level, future-proof ownership-safety regression suite rather than a hand-maintained set of useful-but-partial templates. A new escape method, capability, collection/container kind, MIR ownership effect, or execution boundary must not be able to land without MIR and fuzz coverage knowing about it.

## Phase 1 - Make Coverage Future-Proof

 - [x] Bring `tools/fuzz` into this branch from `origin/master` so hardening work can start against the real suite.
 - [x] Add an initial machine-readable ownership-surface registry for `tools/fuzz`. It enumerates storage capabilities (`plain`, `@local`, `@multiowned`, `@shared`, `@indirect`), sync capabilities (`@locked`, `@writeLocked`, `@versioned`, `@atomic`), collection/container shapes, cleanup-bearing value shapes, escape sources, escape sinks, execution boundaries, and MIR ownership contracts.
 - [x] Add an initial `tools/fuzz/coverage.rb` report that loads the real templates, checks README/template drift, and reports uncovered registry dimensions.
 - [ ] Wire the ownership-surface registry into MIR safety tooling so MIR and fuzz share the same source of truth.
 - [ ] Replace template-local hardcoded dimensions (`ALLOC_KINDS`, `SYNCS`, ownership lists, escape-pattern lists) with registry-derived dimensions wherever the template is meant to cover a whole ownership surface.
 - [ ] Promote `tools/fuzz/coverage.rb` to a CI gate once the first intentionally uncovered P0 surfaces are either covered or marked unsupported/in-dev with reasons.
 - [ ] Add a CI gate for registry drift: adding a new capability/collection/escape method/MIR ownership-effect node/collection method registry entry/boundary form requires registry metadata, and the fuzz coverage report must stay green.
 - [ ] Make negative cells diagnostic-specific. `expected: :compile_error` should include an expected diagnostic code/category/message fragment or MIR invariant id, so a parser/codegen failure cannot masquerade as the intended safety rejection.
 - [ ] Fix stale fuzz documentation/reporting: README matrix counts must be generated from the registry/template loader, and documented templates must exist.

## Phase 2 - Expand UAF / Cleanup Matrices Across All Owned Shapes

 - [ ] Expand `escape_via_return` to cover every cleanup-bearing value that can escape a frame: strings, dynamic arrays, `@list`, `@pool`, `@set`, `HashMap`, sharded/soa variants where applicable, structs containing owned fields, unions/options with owned payloads, and nested containers.
 - [ ] Expand `loop_carry_collection` and `nested_loop_escape` to cover every collection created inside a loop and used/stored outside the loop, including sets, pools, hash maps, sharded collections, and nested collection payloads.
 - [ ] Expand `mutable_collection_param` to cover every mutable collection/container parameter shape, not only `@list`, and include forwarding chains so pointer-passing / allocator identity bugs surface across multiple frames.
 - [ ] Expand cleanup templates (`loop_cleanup`, `error_cleanup`, `branch_cleanup`, `or_positional`) to use the registry's complete cleanup-bearing type set instead of the current small `ALLOC_KINDS` sample.
 - [ ] Expand `access_gate` so every non-copy alias can try every meaningful escape sink: return, field store, list append, set insert, map put, pool insert, collection literal, function arg, `TAKES`, `GIVE`, BG capture, DO capture, BG STREAM capture.
 - [ ] Expand `lifetimed_return` beyond active `@local` cells so all lifetime-bound captures are tested once their baseline capture semantics compile: `@shared:atomic`, `@locked`, `@writeLocked`, `@versioned`/snapshot-like handles, `@multiowned`, and future lifetime-bearing capabilities.
 - [ ] Expand `stream_into_boundary` and `execution_boundary` to include all registered ownership/capability combinations that can cross or be rejected at BG / DO / BG STREAM / FSM / stream-pipeline boundaries, including `@multiowned`, `@indirect`, arena-like memory, nested boundaries, and modifier combinations.

## Phase 3 - Prove The Fuzz Suite Catches Real Classes Of Bugs

 - [x] Prototype targeted mutant runner under `tools/fuzz/mutants/`.
 - [x] Add first mutant, `allow_with_alias_return`, which disables RETURN rejection for WITH-scoped aliases.
 - [x] Validate first mutant signal: `access_gate` baseline was 50 run / 46 ok / 4 MIR errors / 0 unexpected-pass; mutated run was 50 run / 43 ok / 4 MIR errors / 3 unexpected-pass. Result: killed with useful signal despite existing baseline noise.
 - [x] Harden mutant runner for manual release: target-file dirty guard, `--allow-dirty`, `--dry-run`, progress output, persisted baseline/mutated logs, defensive reverse-patch check, configurable kill predicates, and README docs marking the harness manual-only.
 - [ ] Add mutant tests for each major invariant: skip promotion, skip cleanup, allow alias escape, forget BG lifetime stamping, omit collection cleanup, treat non-copy collections as copyable, drop allocator identity on error paths, and bypass MIR for a collection mutation.
 - [ ] Add per-template scope metadata: real code vs modeled behavior, exhaustive matrix vs sampled cells, active vs `:in_dev`, exact invariants asserted, known exclusions, and what class of bug a failure proves.
 - [ ] Add a generated coverage report that maps each template to registry dimensions and highlights uncovered capability/type/escape cross-products by severity.
 - [ ] Keep template matrices bounded with pairwise/orthogonal-array generation for huge cross-products, but require full expansion for high-risk P0 surfaces: cleanup-bearing type escaping frame, alias escape sinks, lifetime-bound BG handle escape, and boundary admission.

## Acceptance Criteria

 - [ ] A developer cannot add a new capability, collection/container type, escape sink/source, MIR ownership effect, or execution boundary without updating the ownership-surface registry.
 - [ ] `tools/fuzz/coverage.rb` proves every registered high-risk surface is covered by the relevant templates or explicitly marked unsupported/in-dev with a reason.
 - [ ] Negative fuzz cells fail only for the intended diagnostic/invariant, not any compile failure.
 - [ ] At least one mutant per major invariant is caught by the fuzz suite.
 - [ ] Fuzz README/reporting is generated enough that matrix counts and template lists cannot go stale.
