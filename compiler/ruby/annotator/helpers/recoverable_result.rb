# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

# The type of a source-level recovery boundary.  This deliberately does not
# use `can_fail`: that flag also carries implementation effects such as an
# allocation which may fail, and those do not give a CLEAR expression a `!T`
# value that OR_ELSE/TRY/IS_OK may handle.
module RecoverableResult
  extend T::Sig

  sig { params(node: AST::Node, context: String).returns(T.nilable(Type)) }
  def recoverable_result_type(node, context:)
    T.bind(self, Annotator::Phases::TypeAnalysisSession)

    stored = if node.respond_to?(:error_union_type) && T.unsafe(node).error_union_type
      T.unsafe(node).error_union_type
    end
    return stored.is_a?(Type) ? stored : Type.new(stored) if stored

    resolved = Type.new(node.full_type!(context: context))
    resolved.error_union? ? resolved : nil
  end

  # Allocation FAULT is recoverable at an explicit OR_ELSE boundary even
  # though it does not turn an ordinary CLEAR binding into source-level !T.
  # Keep that orthogonal to recoverable_result_type so inferred assignment
  # rejects only wrappers the programmer must retain or consume.
  sig { params(node: AST::Node).returns(T::Boolean) }
  def fault_recoverable_result?(node)
    T.bind(self, Annotator::Phases::TypeAnalysisSession)

    result = Type.new(node.full_type!(context: "recoverable FAULT result"))
    return false if result.future? || result.stream?
    return true if node.respond_to?(:can_fail) && T.unsafe(node).can_fail == true
    return false unless node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)

    callee = function_node_map[node.name]
    !!(callee && (callee.alloc_fault == true || callee.uses_frame == true ||
                  callee.uses_heap == true || callee.uses_alloc == true))
  end
end
