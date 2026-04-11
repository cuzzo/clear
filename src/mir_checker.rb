# mir_checker.rb -- Post-lowering MIR verification.
#
# Checks that require lowered MIR (not available pre-lowering):
#   HPT_LEAK              -- heap-returning call result discarded (leak)
#   INLINE_ALLOC_MISMATCH -- operation allocator doesn't match container's AllocMark
#   FRAME_NO_REWIND       -- scope frame-allocates without save/restore (post-lowering)
#
# All other ownership checks run pre-lowering:
#   FlowChecker          -- LEAK, ORPHAN_DROP, ORPHAN_GUARD, FRAME_OVERFLOW
#   UseAfterMoveChecker  -- use-after-move (Rule 1)
#   BorrowChecker        -- MOVE_WHILE_BORROWED, ALIAS_VIOLATION

require_relative "type"

class MIRChecker
  attr_reader :errors

  def initialize(fn_name: nil)
    @fn_name = fn_name
    @errors = []
  end

  def check_fn!(fn_def)
    @fn_name = fn_def.name
    @errors = []

    allocs = {}
    hpt_leaks = []
    inline_alloc_nodes = []

    walk_mir(fn_def.body) do |node|
      case node
      when MIR::AllocMark
        (allocs[node.name] ||= []) << node
      when MIR::ExprStmt
        scan_expr_for_hpt_leak!(node.expr, hpt_leaks)
        if node.expr.is_a?(MIR::InlineZig) && node.expr.allocs
          inline_alloc_nodes << node.expr
        end
      when MIR::InlineZig
        if node.allocs && !inline_alloc_nodes.include?(node)
          inline_alloc_nodes << node
        end
      when MIR::LambdaExpr
        if node.fn_def
          sub = MIRChecker.new
          @errors.concat(sub.check_fn!(node.fn_def))
        end
      end
    end

    hpt_leaks.each { |e| @errors << e }
    verify_inline_alloc_contracts!(inline_alloc_nodes, allocs)
    verify_frame_rewind!(fn_def.body)

    @errors
  end

  def check_program!(program)
    all_errors = []
    program.items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      all_errors.concat(check_fn!(item))
    end
    all_errors
  end

  private

  # Tree walker -- yields every node in the MIR tree.
  def walk_mir(stmts, &block)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_mir_node(s, &block) }
  end

  def walk_mir_node(node, &block)
    return unless node
    yield node

    case node
    when MIR::FnDef       then walk_mir(node.body, &block)
    when MIR::IfStmt
      walk_mir(node.then_body, &block)
      walk_mir(node.else_body, &block)
    when MIR::WhileStmt, MIR::ForStmt
      walk_mir(node.body, &block)
    when MIR::ScopeBlock, MIR::BlockExpr
      walk_mir(node.body, &block)
    when MIR::SwitchStmt
      node.arms&.each { |a| walk_mir(a[:body], &block) }
      walk_mir(node.default_body, &block)
    when MIR::IfChain
      node.branches&.each { |b| walk_mir(b[:body], &block) }
      walk_mir(node.default_body, &block)
    when MIR::DeferStmt   then walk_mir_node(node.body, &block) if node.body
    when MIR::ErrDeferStmt then walk_mir_node(node.body, &block) if node.body
    when MIR::Let          then yield node.init, {} if node.init.is_a?(MIR::LambdaExpr)
    end
  end

  # HPT_LEAK: heap-returning call result discarded.
  def scan_expr_for_hpt_leak!(node, leaks)
    return unless node
    if node.is_a?(MIR::Call) && node.heap_provenance
      leaks << error(:HPT_LEAK, node.callee,
        "heap-returning call result not bound to variable (leak)")
    end
    if node.is_a?(MIR::InlineZig) && node.stdlib_def&.dig(:allocates)
      ret = node.stdlib_def[:return]
      unless ret == :Void || ret.nil?
        leaks << error(:HPT_LEAK, node.reason,
          "stdlib call with allocates:true result not bound to variable (leak)")
      end
    end
    if node.is_a?(MIR::Call) && node.args
      node.args.each { |a| scan_expr_for_hpt_leak!(a, leaks) }
    end
  end

  # INLINE_ALLOC_MISMATCH: InlineZig operation allocator must match container.
  #
  # Checks ALL allocator params (:alloc, :key_alloc, :val_alloc) against the
  # container's AllocMark. A frame-allocated key/value stored in a heap
  # container becomes a dangling pointer after frame rewind.
  def verify_inline_alloc_contracts!(inline_nodes, allocs)
    inline_nodes.each do |iz|
      next unless iz.allocs
      target = iz.target_var
      next unless target && allocs.key?(target)

      container_alloc = allocs[target].first.alloc

      # Check primary allocator
      if iz.allocs.key?(:alloc)
        op_alloc = iz.allocs[:alloc]
        if op_alloc != container_alloc
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "operation uses :#{op_alloc} but container '#{target}' is :#{container_alloc}")
        end
      end

      # Check key/value allocators: frame-allocated stored data in a heap
      # container = use-after-free when the frame rewinds.
      [:key_alloc, :val_alloc].each do |alloc_key|
        next unless iz.allocs.key?(alloc_key)
        stored_alloc = iz.allocs[alloc_key]
        if stored_alloc == :frame && container_alloc == :heap
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "#{alloc_key} is :frame but container '#{target}' is :heap " \
            "(stored data will dangle after frame rewind)")
        end
      end
    end
  end

  # FRAME_NO_REWIND: every loop that frame-allocates must rewind per iteration.
  #
  # Post-lowering check: walks the MIR tree looking for loops that contain
  # frame AllocMarks or InlineZig with frame allocs but lack mark_per_iter.
  # Without per-iteration rewind, frame arena grows unboundedly across iterations.
  def verify_frame_rewind!(body)
    return unless body.is_a?(Array)
    check_loop_rewind!(body)
  end

  def check_loop_rewind!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::WhileStmt
        unless stmt.mark_per_iter || stmt.tight
          if body_has_frame_alloc?(stmt.body)
            @errors << error(:FRAME_NO_REWIND, @fn_name,
              "loop body frame-allocates but has no mark_per_iter rewind")
          end
        end
        check_loop_rewind!(stmt.body)

      when MIR::ForStmt
        unless stmt.mark_per_iter || stmt.tight
          if body_has_frame_alloc?(stmt.body)
            @errors << error(:FRAME_NO_REWIND, @fn_name,
              "loop body frame-allocates but has no mark_per_iter rewind")
          end
        end
        check_loop_rewind!(stmt.body)

      when MIR::IfStmt
        check_loop_rewind!(stmt.then_body)
        check_loop_rewind!(stmt.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        check_loop_rewind!(stmt.body)
      when MIR::SwitchStmt
        stmt.arms&.each { |a| check_loop_rewind!(a[:body]) }
        check_loop_rewind!(stmt.default_body)
      when MIR::IfChain
        stmt.branches&.each { |b| check_loop_rewind!(b[:body]) }
        check_loop_rewind!(stmt.default_body)
      end
    end
  end

  # Does this statement list contain frame allocations (directly, not in nested scopes)?
  def body_has_frame_alloc?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      case s
      when MIR::AllocMark
        s.alloc == :frame
      when MIR::ExprStmt
        s.expr.is_a?(MIR::InlineZig) && s.expr.allocs&.any? { |_k, v| v == :frame }
      when MIR::Let
        # Let with frame-allocating init (e.g., InlineZig call)
        s.init.is_a?(MIR::InlineZig) && s.init.allocs&.any? { |_k, v| v == :frame }
      else
        false
      end
    end
  end

  def error(kind, name, msg)
    "[#{kind}] #{@fn_name}::#{name} -- #{msg}"
  end
end
