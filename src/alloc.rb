# alloc.rb — Frame arena allocation analysis for CLEAR.
#
# Provides helpers to determine whether loop bodies allocate from
# the frame arena and whether those allocations escape the iteration
# (stored in outer-scope variables). Used by visit_WhileLoop to decide
# whether per-iteration mark/rewind is safe.
#
# Also provides downgrade_frame_to_stack for loop-local SROA.
module AllocHelper
  # Downgrade :frame to :stack for struct literals inside loop bodies.
  # The OS stack reclaims them each iteration; LLVM can SROA the fields.
  def downgrade_frame_to_stack(node, storage)
    return storage unless storage == :frame && @loop_depth > 0
    return storage unless node.value.is_a?(AST::StructLit)

    node.type_info.location = :stack
    node.value.storage      = :stack
    :stack
  end

  # Returns true if any statement in stmts allocates from the frame arena.
  def loop_allocates_frame?(stmts)
    return false if stmts.nil?
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.any? { |s| node_allocates_frame?(s) }
  end

  def node_allocates_frame?(node)
    return false if node.nil?
    case node
    when AST::VarDecl, AST::BindExpr
      return true if node.storage == :frame
      node_allocates_frame?(node.value)
    when AST::FuncCall
      pat = node.respond_to?(:zig_pattern) ? node.zig_pattern : nil
      return true if pat.is_a?(String) && pat.include?("{alloc}")
      return false if node.respond_to?(:extern_call) && node.extern_call
      fn = @fn_nodes&.[](node.name)
      return true if fn && fn.respond_to?(:uses_frame) && fn.uses_frame
      node.args&.any? { |a| node_allocates_frame?(a) } || false
    when AST::MethodCall
      return false if node.respond_to?(:pool_method) && node.pool_method
      pat = node.respond_to?(:zig_pattern) ? node.zig_pattern : nil
      return true if pat.is_a?(String) && pat.include?("{alloc}")
      fn = @fn_nodes&.[](node.name)
      return true if fn && fn.respond_to?(:uses_frame) && fn.uses_frame
      ([node.object] + (node.args || [])).any? { |a| node_allocates_frame?(a) }
    when AST::BinaryOp
      node_allocates_frame?(node.left) || node_allocates_frame?(node.right)
    when AST::UnaryOp
      node_allocates_frame?(node.right)
    when AST::IfStatement
      loop_allocates_frame?(node.then_branch) || loop_allocates_frame?(node.else_branch)
    when AST::WhileLoop
      loop_allocates_frame?(node.do_branch)
    when AST::MatchStatement
      node.cases.any? { |c| loop_allocates_frame?(c[:body]) } ||
        loop_allocates_frame?(node.default_case)
    when AST::ReturnNode
      node_allocates_frame?(node.value)
    when AST::Assignment
      node_allocates_frame?(node.value)
    else
      false
    end
  end

  # Returns true if any frame allocation escapes the loop iteration into
  # an outer-scope variable. If true, mark_per_iter must be false.
  def loop_frame_escapes_to_outer?(stmts, outer_vars)
    return false if stmts.nil?
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.any? { |s| node_frame_escapes?(s, outer_vars) }
  end

  def node_frame_escapes?(node, outer_vars)
    return false if node.nil?
    case node
    when AST::FuncCall
      if node.args&.first.is_a?(AST::Identifier) && outer_vars.include?(node.args.first.name)
        pat = node.respond_to?(:zig_pattern) ? node.zig_pattern : nil
        return true if node.name == "append"
        return true if pat.is_a?(String) && pat.include?("{alloc}")
        fn = @fn_nodes&.[](node.name)
        return true if fn && fn.respond_to?(:uses_frame) && fn.uses_frame
      end
      false
    when AST::MethodCall
      if node.respond_to?(:object) && node.object.is_a?(AST::Identifier) && outer_vars.include?(node.object.name)
        pat = node.respond_to?(:zig_pattern) ? node.zig_pattern : nil
        return true if pat.is_a?(String) && pat.include?("{alloc}")
        fn = @fn_nodes&.[](node.name)
        return true if fn && fn.respond_to?(:uses_frame) && fn.uses_frame
      end
      false
    when AST::Assignment
      target_name = case node.name
                    when AST::Identifier then node.name.name
                    when AST::GetField then node.name.target.is_a?(AST::Identifier) ? node.name.target.name : nil
                    when String then node.name
                    end
      if target_name && outer_vars.include?(target_name)
        return true if node_allocates_frame?(node.value)
      end
      false
    when AST::BindExpr
      if node.name.is_a?(String) && outer_vars.include?(node.name)
        return true if node_allocates_frame?(node.value)
      end
      false
    when AST::WhileLoop
      loop_frame_escapes_to_outer?(node.do_branch, outer_vars)
    when AST::IfStatement
      loop_frame_escapes_to_outer?(node.then_branch, outer_vars) ||
        loop_frame_escapes_to_outer?(node.else_branch, outer_vars)
    when AST::MatchStatement
      node.cases.any? { |c| loop_frame_escapes_to_outer?(c[:body], outer_vars) } ||
        loop_frame_escapes_to_outer?(node.default_case, outer_vars)
    else
      false
    end
  end
end
