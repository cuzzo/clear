# typed: strict
# thunk_transform.rb -- plan detection and structural MIR lowering for
# `EFFECTS REENTRANT:THUNK` functions.
#
# The annotator recognizes the supported recursive shapes and stamps
# AST::FunctionDef#thunk_plan or #mutual_thunk_plan. MIRLowering then
# consumes those plans via ThunkTransform::Emit and emits structural MIR
# nodes:
#
#   MIR::ThunkTrampoline        -- non-mutual recurrence with heap frame chain
#   MIR::MutualThunkTrampoline  -- tail-position mutual recursion as tagged union
#
# MIREmitter owns the final Zig text for those MIR nodes. Thunk lowering
# must not route through RawZig or the old Phase 4 segment scaffold.

require "sorbet-runtime"
require_relative "thunk_transform/recursive_splitter"
require_relative "thunk_transform/emit"

module ThunkTransform
  extend T::Sig
  module_function
end
