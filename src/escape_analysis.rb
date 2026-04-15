# src/escape_analysis.rb - Single pre-pass escape analysis for CLEAR compiler.
#
# Determines which declarations require heap allocation before CleanupClassifier
# runs. Replaces the cascade of upgrade_* methods in MIRPass.
#
# Pipeline position: after E1 (compute_heap_return_fns!) and PromotionClassifier,
# before LoopFrameAnalysis and CleanupClassifier.
#
# Phases:
#   E1 - compute_heap_return_fns!  fixed-point: which functions return heap values
#   E2 - analyze!                  one walk per fn: apply all 6 escape conditions
#   E3 - call-site tagging         propagate heap provenance to call expressions
#                                  (currently handled by apply_transitive_heap_promotion!
#                                   and mark_heap_carry_call_sites! in MIRPass)

require_relative "type"
require_relative "ast"

module EscapeAnalysis
  # ── Phase E1 ─────────────────────────────────────────────────────────────

  # Compute the set of functions whose return value is heap-owned.
  # Fixed-point iteration over the call graph.
  # Writes fn.return_provenance = :heap on each discovered function.
  # Returns a frozen Set of function names.
  def self.compute_heap_return_fns!(fn_nodes)
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

  # ── Phase E2 ─────────────────────────────────────────────────────────────

  # Per-function escape scan: applies all 6 escape conditions to stamp
  # storage/provenance on declaration nodes before CleanupClassifier runs.
  #
  # Escape conditions handled:
  #   1. :always_returned    — collection returned on all paths → heap from start
  #   2. :bg_captured        — list/map/pool/set captured by BG block → heap
  #   3. :heap_ptr_return    — identifier returned from RETURNS %T fn → storage :heap
  #   4. :assign_escape      — frame value (requires_move?) assigned to heap field → storage :heap
  #   5. :loop_carry_string  — string reassigned in mark_per_iter loop → heap
  #   6. :transitive_callee  — declaration value is call to heap-returning fn → provenance :heap
  #
  # Replaces MIRPass#upgrade_loop_string_carries_to_heap!,
  #           MIRPass#upgrade_always_escaped_to_heap!,
  #           MIRPass#upgrade_bg_captures_to_heap!,
  #           MIRPass#upgrade_heap_ptr_returns_to_heap!,
  #           MIRPass#upgrade_assign_escapes_to_heap!.
  # (Condition 6 currently also handled by apply_transitive_heap_promotion! — E3 will remove that.)
  #
  # Must run AFTER E1 (heap_fns) and PromotionClassifier (promotion_plans),
  # BEFORE LoopFrameAnalysis and CleanupClassifier.
  #
  # @param fn_nodes       [Hash]  name -> AST::FunctionDef
  # @param heap_fns       [Set]   function names with heap return_provenance (from E1)
  # @param promotion_plans [Hash] name -> PromotionClassifier plan hash
  # @return [Set<String>] BG-upgraded variable names (for insert_bg_escape_promote! filtering)
  def self.analyze!(fn_nodes, heap_fns:, promotion_plans: {})
    all_bg_upgraded = Set.new

    fn_nodes.each do |name, fn|
      next unless fn&.body
      plan   = promotion_plans[name]
      result = per_fn_scan!(fn, heap_fns, plan)

      all_bg_upgraded.merge(result[:bg_upgraded])

      # Stamp carry-return metadata so mark_heap_carry_call_sites! can run after.
      if result[:carry_return_vars]&.any?
        fn.heap_carry_return      = true
        fn.heap_carry_return_vars = result[:carry_return_vars]
      end

      # Remove always-escaped vars from promotion plan — no runtime MIR::Promote needed.
      if result[:always_escaped]&.any? && plan.is_a?(Hash) && plan[:var_promotes]
        escaped = result[:always_escaped]
        plan[:var_promotes] = plan[:var_promotes].reject { |vp| escaped.include?(vp[:var]) }
      end
    end

    all_bg_upgraded
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  # E1 helper: check whether any return in fn's body yields a heap value.
  private_class_method def self.fn_body_returns_heap?(fn, fn_nodes, heap_fns)
    returns = []
    AST.walk_body(fn.body) { |n| returns << n if n.is_a?(AST::ReturnNode) }

    returns.any? do |ret|
      next false unless ret.value
      return_expr_is_heap?(ret.value, fn_nodes, heap_fns)
    end
  end

  # E1 helper: true if a return-position expression produces a heap-owned value.
  private_class_method def self.return_expr_is_heap?(val, fn_nodes, heap_fns)
    callee_name = case val
                  when AST::FuncCall   then val.name
                  when AST::MethodCall then val.name
                  end
    return heap_fns.include?(callee_name) if callee_name

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

    if val.is_a?(AST::Identifier)
      ti = val.type_info
      ti = ti.is_a?(Type) ? ti : (ti ? (Type.new(ti) rescue nil) : nil)
      return !!(ti&.needs_escape_promotion? && !ti&.heap_provenance?)
    end

    false
  end

  # ── E2 private helpers ───────────────────────────────────────────────────

  private_class_method def self.per_fn_scan!(fn, heap_fns, plan)
    bg_upgraded    = Set.new
    always_escaped = Set.new
    carry_ret_vars = Set.new

    # Condition 3 context: does this function return a heap pointer?
    ret_t = fn.return_type
    ret_t = ret_t.is_a?(Type) ? ret_t : (Type.new(ret_t) rescue nil)
    heap_ptr_return = ret_t&.heap?

    # Conditions 1 + 3: collect return nodes once.
    return_nodes = e2_collect_returns(fn.body)

    # Condition 2: BG-captured collection/map/pool/set names.
    bg_names = e2_bg_capture_names(fn)

    # Condition 5: loop carry string names + side-effect promote on reassignment values.
    carry_names = e2_loop_carry_names!(fn)
    carry_ret_vars.merge(e2_carry_return_vars(fn, carry_names))

    # Condition 1: always-returned identifiers from the promotion plan.
    always_ret = if plan.is_a?(Hash) && plan[:var_promotes]&.any?
      plan[:var_promotes].select { |vp|
        return_nodes.all? { |r| r.value && e2_return_refs?(r.value, vp[:var]) }
      }.map { |vp| vp[:var] }.to_set
    else
      Set.new
    end

    # ── Declaration walk (conditions 1, 2, 3, 5, 6) ──
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
      vname = node.name.to_s

      if always_ret.include?(vname)
        # Condition 1: always returned — heap storage + provenance on decl AND symbol.
        e2_stamp_full!(node)
        e2_stamp_symbol_via_return_ident!(return_nodes, vname)
        always_escaped << vname

      elsif bg_names.include?(vname)
        # Condition 2: BG-captured collection — heap storage + provenance.
        e2_stamp_full!(node)
        bg_upgraded << vname

      elsif heap_ptr_return
        # Condition 3: RETURNS %T — returned identifiers get storage :heap only
        # (no provenance write; classify_heap_struct_plain consults schema via storage).
        ident = e2_find_return_ident(return_nodes, vname)
        if ident
          sym_ti = ident.symbol&.type
          sym_ti = sym_ti.is_a?(Type) ? sym_ti : (Type.new(sym_ti) rescue nil)
          if sym_ti&.requires_move?
            node.storage = :heap if node.respond_to?(:storage=)
            ident.symbol.storage = :heap if ident.symbol
          end
        end

      elsif carry_names.include?(vname)
        # Condition 5: loop carry string — heap storage + provenance + upgrade literal value.
        e2_stamp_full!(node)
        val = node.value
        val.storage = :heap if val&.respond_to?(:storage=)
      end

      # Condition 6: transitive callee — declaration value is a heap-returning call.
      # Only stamp provenance (not storage); storage is managed by the node's own type.
      # This runs independently and does NOT skip already-stamped nodes.
      val = node.value
      callee_name = case val
                    when AST::FuncCall   then val.name.to_s
                    when AST::MethodCall then val.name.to_s
                    end
      if callee_name && heap_fns.include?(callee_name)
        ti = node.type_info rescue nil
        ti.provenance = :heap if ti.is_a?(Type) && !ti.heap_provenance?
      end
    end

    # ── Condition 4: assign escape (walk Assignments separately) ──
    # A frame value (requires_move?) assigned to a heap container field must be
    # heap-allocated so it survives beyond the current frame.
    # Storage only; no provenance write (classify_heap_struct_plain uses storage).
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::Assignment)
      rhs = node.value
      next unless rhs.is_a?(AST::Identifier) && rhs.symbol
      next unless [:frame, :stack].include?(rhs.symbol.storage)
      rhs_ti = rhs.symbol.type
      rhs_ti = rhs_ti.is_a?(Type) ? rhs_ti : (Type.new(rhs_ti) rescue nil)
      next unless rhs_ti&.requires_move?
      lhs_root = e2_root_ident(node.name)
      next unless lhs_root.is_a?(AST::Identifier) && lhs_root.symbol
      next unless [:heap, :multiowned, :shared].include?(lhs_root.symbol.storage)
      rhs.symbol.storage = :heap
      decl = rhs.symbol.reg
      decl.storage = :heap if decl&.respond_to?(:storage=)
    end

    { bg_upgraded: bg_upgraded, always_escaped: always_escaped, carry_return_vars: carry_ret_vars }
  end

  # Collect all ReturnNode descendants in body.
  private_class_method def self.e2_collect_returns(body)
    nodes = []
    AST.walk_body(body) { |n| nodes << n if n.is_a?(AST::ReturnNode) }
    nodes
  end

  # Collect names of BG-captured collection variables (list/map/pool/set).
  private_class_method def self.e2_bg_capture_names(fn)
    names = Set.new
    fn.body.each do |stmt|
      e2_each_bg(stmt) do |bg|
        captures = bg.capture_analysis&.captures
        next unless captures&.any?
        captures.each do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          next unless t && !t.needs_pointer_passing?
          next unless t.list_collection? || (t.map? && !t.numeric_map?) || t.pool? || t.set_collection?
          names << name
        end
      end
    end
    names
  end

  # Walk a top-level statement for embedded BG/BgStream blocks.
  private_class_method def self.e2_each_bg(stmt, &blk)
    case stmt
    when AST::BgBlock, AST::BgStreamBlock
      yield stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      e2_walk_expr_bg(stmt.value, &blk)
    when AST::FuncCall
      stmt.args&.each { |a| e2_walk_expr_bg(a, &blk) }
    when AST::MethodCall
      stmt.args&.each { |a| e2_walk_expr_bg(a, &blk) }
    end
  end

  private_class_method def self.e2_walk_expr_bg(expr, &blk)
    return unless expr
    case expr
    when AST::BgBlock, AST::BgStreamBlock
      yield expr
    when AST::FuncCall
      expr.args&.each { |a| e2_walk_expr_bg(a, &blk) }
    when AST::MethodCall
      e2_walk_expr_bg(expr.object, &blk)
      expr.args&.each { |a| e2_walk_expr_bg(a, &blk) }
    end
  end

  # Find string variables reassigned inside loops that will have mark_per_iter.
  # Side effect: calls LoopFrameAnalysis.promote_value_to_heap! on each carry value.
  private_class_method def self.e2_loop_carry_names!(fn)
    carry_names = Set.new
    AST.walk_body(fn.body) do |node|
      body = case node
             when AST::WhileLoop then (node.tight ? nil : node.do_branch)
             when AST::ForRange  then node.body
             when AST::ForEach   then node.body
             end
      next unless body

      local_names  = LoopFrameAnalysis.collect_local_names(body)
      non_escaping = LoopFrameAnalysis.local_frame_decls(body, local_names).reject { |d|
        LoopFrameAnalysis.escapes_to_outer?(d.name.to_s, body, local_names)
      }
      next unless non_escaping.any?  # only when loop WILL have mark_per_iter

      AST.walk_body(body) do |bind|
        next unless bind.is_a?(AST::BindExpr) && bind.mode == :assign
        next unless bind.name.is_a?(String) && !local_names.include?(bind.name)
        ti = bind.type_info rescue nil
        next unless ti.is_a?(Type) && ti.string?
        carry_names << bind.name
        LoopFrameAnalysis.promote_value_to_heap!(bind.value)
      end
    end
    carry_names
  end

  # Returns carry variable names that are directly returned (for heap_carry_return metadata).
  private_class_method def self.e2_carry_return_vars(fn, carry_names)
    return Set.new if carry_names.empty?
    ret_t = fn.return_type
    ret_t = ret_t.is_a?(Type) ? ret_t : (Type.new(ret_t) rescue nil)
    return Set.new unless ret_t&.string?
    result = Set.new
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::Identifier)
      result << node.value.name if carry_names.include?(node.value.name)
    end
    result
  end

  # True if a return-position expression references the named variable.
  private_class_method def self.e2_return_refs?(node, var_name)
    case node
    when AST::Identifier then node.name == var_name
    when AST::StructLit, AST::UnionVariantLit
      node.fields.any? { |_, fval| e2_return_refs?(fval, var_name) }
    else false
    end
  end

  # Find the first Identifier matching var_name across all return node values.
  private_class_method def self.e2_find_return_ident(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = e2_extract_ident(ret.value, var_name)
      return ident if ident
    end
    nil
  end

  private_class_method def self.e2_extract_ident(node, var_name)
    case node
    when AST::Identifier
      node.name == var_name ? node : nil
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_value { |v| r = e2_extract_ident(v, var_name); return r if r }
      nil
    else nil
    end
  end

  # Set both storage and provenance to :heap on a declaration node.
  private_class_method def self.e2_stamp_full!(node)
    node.storage = :heap if node.respond_to?(:storage=)
    ti = node.type_info rescue nil
    ti.provenance = :heap if ti.is_a?(Type)
  end

  # Also stamp the SymbolEntry (scope entry) reached via the return identifier.
  private_class_method def self.e2_stamp_symbol_via_return_ident!(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = e2_extract_ident(ret.value, var_name)
      next unless ident&.symbol
      ident.symbol.storage = :heap
      sym_type = ident.symbol.type
      sym_type.provenance = :heap if sym_type.is_a?(Type)
    end
  end

  # Extract the root Identifier from a field/index chain (for assign_escape LHS).
  private_class_method def self.e2_root_ident(node)
    case node
    when AST::GetField, AST::GetIndex then e2_root_ident(node.target)
    when AST::Identifier              then node
    else nil
    end
  end
end
