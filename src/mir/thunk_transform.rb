# typed: strict
# thunk_transform.rb -- CPS transform for `EFFECTS REENTRANT:THUNK`
# functions.
#
# Per docs/agents/thunks.md, a `:THUNK` function is compiled to:
#   1. A heap-allocated frame state struct (one per recursive call,
#      chained via `parent: ?*Self`)
#   2. A runStep<N>(frame: *Self) StepResult fn that does one segment
#      of work and returns Done / Recurse / Goto / Err
#   3. A synthesized trampoline that loops over runStep calls,
#      managing the frame chain and decrementing a shared gas
#      counter (cooperative yield to the scheduler at zero)
#
# Submodules mirror fsm_transform/'s shape so adding a new control-
# flow form or recursion shape is one new branch in the splitter +
# resolver, NEVER a new top-level emit function.
#
#   ThunkTransform::Segments           -- tail variants (Done / Goto /
#                                          RecurseTail / RecurseStep)
#   ThunkTransform::RecursiveSplitter  -- AST -> segment graph;
#                                          pivots on recursive self-
#                                          calls (instead of FSM's
#                                          suspend points)
#   ThunkTransform::Liveness           -- reused from fsm_transform
#                                          via require -- cross-
#                                          segment vars become frame
#                                          fields
#   ThunkTransform::Emit               -- segments + liveness -> MIR-
#                                          typed thunk body + frame
#                                          struct + trampoline
#
# The transform reuses the FSM cleanup invariant + task_destroy_lines
# pipeline, so a thunk frame's MIR::Cleanup nodes that target cross-
# segment fields are lifted to a per-frame destroyFrame hook (the
# trampoline's Err unwind invokes it on each popped frame).
#
# This file is the SCAFFOLDING for Phase 4. The transform currently
# returns nil for every input; subsequent commits land:
#   Phase 4b: tail-recursive single-call case
#   Phase 4c: non-tail single-call (frame chain + pending_op)
#   Phase 4d: multi-call (e.g. fibonacci)
#   Phase 4e: runtime trampoline + Zig integration
#   Phase 4f: mutual recursion via tagged-union frames
#   Phase 4g: stack-sizing rule + verification

require "sorbet-runtime"
require_relative "thunk_transform/segments"
require_relative "thunk_transform/recursive_splitter"
require_relative "thunk_transform/emit"

module ThunkTransform
  extend T::Sig
  module_function

  # Public entry. Given a `:reentrant_thunk` FunctionDef plus the
  # surrounding lowering, produce an MIR::ThunkBody for the wrapper
  # emitter to render -- OR nil if the function falls outside the
  # transform's coverage for the current Phase 4 stage. The caller
  # (MIRLowering) falls back to plain `:reentrant` lowering when nil.
  #
  # As stages land, the nil-returning path shrinks until it
  # disappears.
  sig { params(fn_node: T.untyped, lowering: T.untyped).returns(T.untyped) }
  def transform(fn_node, lowering)
    return nil if fn_node.reentrance_kind != :reentrant_thunk

    # Phase 4a returns nil for every input. The hook is wired so
    # MIRLowering routes :THUNK functions through here, but the
    # actual CPS lowering lands in Phase 4b+.
    nil
  end
end
