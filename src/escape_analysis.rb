# src/escape_analysis.rb - Single pre-pass escape analysis for CLEAR compiler.
#
# Determines which declarations require heap allocation before CleanupClassifier
# runs. Replaces the cascade of upgrade_* methods in MIRPass.
#
# Pipeline position: after LoopFrameAnalysis, before CleanupClassifier.
#
# Phases:
#   E1 - compute_heap_return_fns!  fixed-point: which functions return heap values
#   E2 - per-declaration scan      one walk per fn: apply all 6 escape conditions
#   E3 - call-site tagging         propagate heap provenance to call expressions

require_relative "type"
require_relative "ast"

module EscapeAnalysis
  # Phase E1: compute the set of functions whose return value is heap-owned.
  #
  # Fixed-point iteration over the call graph: a function is heap-returning if
  # any of its return statements directly returns a heap value, calls a
  # heap-returning function, or returns a frame collection that needs escape.
  #
  # Writes fn.return_provenance = :heap on each discovered function.
  # Returns a frozen Set of function names.
  #
  # Replaces MIRPass#recompute_fn_return_provenance! (mir_pass.rb:1259-1320).
  def self.compute_heap_return_fns!(fn_nodes)
    # Seed: functions already stamped heap by the annotator (visit_ReturnNode,
    # visit_FunctionDef, etc.). These are the base facts; fixed-point extends them.
    heap_fns = fn_nodes.each_with_object(Set.new) do |(name, fn), s|
      s << name if fn&.return_provenance == :heap
    end

    changed = true
    while changed
      changed = false
      fn_nodes.each do |name, fn|
        next unless fn&.body
        next if heap_fns.include?(name)
        next unless fn_body_returns_heap?(fn, fn_nodes, heap_fns)

        heap_fns << name
        fn.return_provenance = :heap
        changed = true
      end
    end

    heap_fns.freeze
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  private_class_method def self.fn_body_returns_heap?(fn, fn_nodes, heap_fns)
    returns = []
    AST.walk_body(fn.body) { |n| returns << n if n.is_a?(AST::ReturnNode) }

    returns.any? do |ret|
      next false unless ret.value
      return_expr_is_heap?(ret.value, fn_nodes, heap_fns)
    end
  end

  # Returns true if a return-position expression produces a heap-owned value.
  private_class_method def self.return_expr_is_heap?(val, fn_nodes, heap_fns)
    # Direct call to a known heap-returning function.
    callee_name = case val
                  when AST::FuncCall   then val.name
                  when AST::MethodCall then val.name
                  end
    return heap_fns.include?(callee_name) if callee_name

    # RETURN obj.field where obj came from a heap-returning call.
    if val.is_a?(AST::GetField)
      root = val
      root = root.target while root.is_a?(AST::GetField) || root.is_a?(AST::GetIndex)
      if root.is_a?(AST::Identifier) && root.symbol
        decl     = root.symbol.reg
        decl_val = decl.respond_to?(:value) ? decl.value : nil
        callee2  = case decl_val
                   when AST::FuncCall   then decl_val.name
                   when AST::MethodCall then decl_val.name
                   end
        if callee2 && heap_fns.include?(callee2)
          ret_type = val.respond_to?(:full_type) ? (Type.new(val.full_type) rescue nil) : nil
          return !!(ret_type&.string? || ret_type&.collection? || ret_type&.map?)
        end
      end
    end

    # RETURN var where var is a frame collection that needs escape.
    if val.is_a?(AST::Identifier)
      ti = val.type_info
      ti = ti.is_a?(Type) ? ti : (ti ? (Type.new(ti) rescue nil) : nil)
      return !!(ti&.needs_escape_promotion? && !ti&.heap_provenance?)
    end

    false
  end
end
