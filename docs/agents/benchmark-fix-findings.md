# Benchmark-Fix Branch: Tech Debt and Bug Findings

This document summarizes the technical debt, architectural violations, potential bugs, and partial implementations identified in the `benchmark-fix` branch (relative to `master`).

## 1. Architectural Violations

### MIREmitter Type Inspection (Tech Debt)
- **File:** `src/mir/mir_emitter.rb`
- **Issue:** The emitter uses regex to parse Zig type strings (e.g., `node.zig_type[/ArrayListUnmanaged\((.+)\)/, 1]`) to determine element types.
- **Violation:** Violates the "Dumb Transpiler" rule (Role 3 in `GEMINI.md`). The emitter should not perform semantic analysis or string parsing to make code-gen decisions.
- **Recommendation:** Explicitly pass the element type in the MIR node (`MIR::EscapePromote`, `MIR::ContainerInit`, etc.).

### Transpiler Semantic Decisions
- **File:** `src/backends/pipeline_generator.rb`
- **Issue:** Contains logic to determine cleanup requirements (e.g., `src_needs_cleanup = list_node.is_a?(AST::MethodCall) && ...`).
- **Violation:** All allocator and cleanup decisions must reside in Pass 2 (`MIRLowering`) per `GEMINI.md`. Pass 4 should be a passive consumer of these decisions.
- **Recommendation:** Move this logic into `MIRLowering` and communicate it via MIR nodes.

### Legacy Pipeline Path
- **File:** `src/mir/mir_lowering.rb` (`lower_smooth`)
- **Issue:** Complex pipeline operators still fall back to `pipeline_legacy_host`, which generates `RawZig`.
- **Violation:** `RawZig` is an unsafe escape hatch that bypasses `MIRChecker` (INV-12). Chained pipelines using this path are unverified for memory safety.
- **Recommendation:** Complete the migration of all pipeline operators to structural MIR.

## 2. Potential Bugs and Safety Risks

### SmartEventFd.notify Optimization
- **File:** `zig/runtime/scheduler.zig`
- **Issue:** Re-introduces an optimization to skip the `write()` syscall if the target is not `WakeParked`.
- **Risk:** A previous version of this optimization was removed because it caused deadlocks. While `prepareSleep` now uses atomics, this is a high-risk change for a core synchronization primitive.
- **Recommendation:** Verify with aggressive Hammer and VOPR tests that no wake-up signals are lost.

### Incomplete FsmTask Sequence Bumping
- **File:** `zig/runtime/scheduler.zig`
- **Issue:** `FsmTask.seq` (the park/wake transition counter) is only bumped on lock timeouts. It is NOT bumped during regular `WaitForIO` or `WaitForLock` transitions.
- **Risk:** This breaks the `detectCycleFsm` protocol, which relies on `seq` to validate that a task hasn't been recycled or moved during a cross-scheduler chain walk.
- **Recommendation:** Bump `task.seq` in `submitFsmResume` and `submitFsmSpawn` (or in the scheduler's FSM dequeue/dispatch loop).

### FSM Liveness for IoSuspend Async Access
- **File:** `src/mir/fsm_transform/liveness.rb`
- **Issue:** For `IoSuspend` (e.g., async `read`), the kernel may access arguments after the FSM body has yielded.
- **Risk:** If those arguments (like a buffer) are stack-allocated, they must be promoted to the FSM `ctx` struct. The current analysis charges these reads to the "next" segment, which should trigger promotion, but this needs rigorous validation to ensure no Use-After-Free (UAF) windows exist.
- **Recommendation:** Add explicit tests for async IO with stack-allocated buffers in FSM tasks.

## 3. Partial Implementations and Stubs

### Missing detectCycleFsm
- **File:** `zig/runtime/scheduler.zig`, `zig/runtime/fsm.zig`
- **Issue:** References to `detectCycleFsm` and the UAF-safe "slab-pin" protocol exist, but the actual cycle detection logic for FSM tasks is missing.
- **Status:** Partial implementation.

### FSM Next-Bind RawZig
- **File:** `src/mir/fsm_transform/suspend_resolvers.rb`
- **Issue:** `resolve_next` uses a block of `RawZig` to handle `fsm_next_bind` logic.
- **Status:** A "small follow-up" is noted to migrate this to structured MIR (`IfStmt` + `ReturnStmt`).

### Disabled Liveness Safety Check
- **File:** `src/mir/fsm_transform/liveness.rb`
- **Issue:** `return unless uses_by_seg.key?(next_idx) || true` (line 143).
- **Status:** The `|| true` effectively disables the check. Likely a debug leftover.

## 4. Testing Gaps

### FSM Stealing Stress
- **Issue:** `fsm-steal-test.zig` covers basic functionality, but interactions between stealing and status transitions (Blocked/Ready) under heavy load need more coverage.
- **Recommendation:** Implement a Hammer test specifically for FSM work-stealing with oversubscribed workers and high IO/Lock contention.

### ArrayListUnmanaged String Matching
- **Issue:** The `MIREmitter` logic for `ArrayListUnmanaged` relies on string-pattern matching on `zig_type`.
- **Risk:** Fragile; could fail on complex nested types or if Zig's internal type naming changes.
- **Recommendation:** Add unit tests in `spec/mir_emitter_spec.rb` covering complex nested collections to verify the regex robustness.
