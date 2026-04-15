# src/mir_pass.rb - MIR transformation pass
#
# Runs after annotation. Classifies cleanup bindings, stamps fn.cleanup_bindings,
# inserts MIR promotion/suppress nodes, and propagates heap provenance.
#
# Dependencies are defined in control_flow.rb (required first) and promotion_plan.rb.

require_relative "promotion_plan"

class MIRPass
  # cleanup_bindings: { fn_name => { var_name => entry_hash } }
  # Exposed for specs that test classification directly.
  attr_reader :cleanup_bindings

  def initialize(fn_nodes:, schema_lookup:)
    @fn_nodes = fn_nodes
    @schema_lookup = schema_lookup
    @cleanup_bindings = {}
  end

  # Computes plans, classifies bindings, inserts MIR nodes, and stamps AST.
  # Phase 0 hoists heap-promoted temporaries (HPTs) into VarDecl nodes so that
  # existing classify_binding + cleanup_bindings infrastructure handles their cleanup.
  # PromotionClassifier must run before cleanup classification because its Phase 0
  # (scan_for_hpt_downgrade) clears heap provenance on return sub-expressions
  # that the classifier depends on.
  def transform!(ast)
    # Recompute fn.return_provenance for FuncCall returns and transitive chains.
    # visit_ReturnNode only handles identifier/COPY/StructLit returns; this catches
    # the rest. Must run before apply_transitive_heap_promotion! which reads the flag.
    recompute_fn_return_provenance!

    # T4: Propagate heap return_provenance from callee to caller binding type_info.
    # Covers transitive promotion (wrapper() -> makeList()) before cleanup classification.
    apply_transitive_heap_promotion!(ast.statements)

    # Phase 1.5c: upgrade loop-carry string variables to heap.
    # Outer string variables reassigned inside a rewinding loop need heap
    # allocation so the carry value survives the per-iteration frame rewind.
    # Must run before Phase 0 (HPT) and Phase 2 (CleanupClassifier) so that
    # heap_carry_return flags are visible to both.
    @fn_nodes.each do |_name, fn|
      upgrade_loop_string_carries_to_heap!(fn) if fn&.body
    end

    # Phase 1.5d: mark call sites to heap-carry-return functions as heap-provenance.
    # After Phase 1.5c, functions with heap_carry_return=true return heap strings
    # (caller must free).  Propagate heap_provenance to their call-site expressions
    # so Phase 0 (HPT hoisting) can register cleanup at the call site.
    carry_return_fns = @fn_nodes.select { |_, f|
      f.respond_to?(:heap_carry_return) && f.heap_carry_return
    }.keys.to_set
    unless carry_return_fns.empty?
      @fn_nodes.each do |_name, fn|
        next unless fn&.body
        mark_heap_carry_call_sites!(fn, carry_return_fns)
      end
    end

    promotion_plans = {}

    # Phase 1: classify promotions for all functions (triggers HPT downgrade).
    @fn_nodes.each do |name, fn|
      promotion_plans[name] = PromotionClassifier.classify(fn, schema_lookup: @schema_lookup)
    end

    # Phase 1.5: upgrade always-escaped collections to heap at declaration.
    # If a collection variable is returned on ALL return paths, allocate it on the
    # heap from the start instead of frame-then-promote. This eliminates the
    # MIR::Promote + runtime promoteList for these variables.
    promotion_plans.each do |name, plan|
      next unless plan[:var_promotes]&.any?
      fn = @fn_nodes[name]
      upgrade_always_escaped_to_heap!(fn, plan) if fn&.body
    end

    # Phase 1.5b: upgrade BG-captured variables to heap at declaration.
    # BG blocks capture outer variables into a separate fiber. Frame-allocated
    # data would be invalidated by frame rewind, so captured collections and
    # strings are promoted at runtime. Upgrading to heap at declaration
    # eliminates the runtime promote.
    @fn_nodes.each do |name, fn|
      upgrade_bg_captures_to_heap!(fn) if fn&.body
    end

    # Phase 1.5e: upgrade frame vars returned from heap-pointer functions to heap.
    # RETURNS %Struct functions must return heap-allocated values; upgrade at
    # declaration so the allocator is finalized before CleanupClassifier runs.
    @fn_nodes.each do |name, fn|
      upgrade_heap_ptr_returns_to_heap!(fn) if fn&.body
    end

    # Phase 1.5f: upgrade frame collections assigned to heap targets to heap.
    # When a frame-allocated collection is assigned to a field/index of a
    # heap-allocated struct/array, allocate it on heap at declaration instead
    # of emitting a runtime MIR::Promote. Replaces handle_assign_escape from
    # the annotator; runs post-MIR so allocators are fully resolved.
    @fn_nodes.each do |name, fn|
      upgrade_assign_escapes_to_heap!(fn) if fn&.body
    end

    # Phase 2: classify cleanup bindings (uses cleared provenance from Phase 1).
    @fn_nodes.each do |name, fn|
      @cleanup_bindings[name] = CleanupClassifier.classify(fn, fn_nodes: @fn_nodes, schema_lookup: @schema_lookup)
    end

    # Phase 2.5: set mark_per_iter on all loops (requires finalised allocators from Phase 2).
    LoopFrameAnalysis.analyze!(@fn_nodes)

    # Phase 3: insert MIR nodes + stamp AST.
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      transform_function!(stmt, promotion_plans[stmt.name])
    end

  end

  private

  # Upgrade always-escaped collection variables to heap at declaration.
  # A variable is always-escaped if it's in var_promotes AND referenced in
  # every return node. For those, heap allocation at declaration is correct
  # and cheaper than frame-then-promote.
  # Performance optimization: allocate on heap from the start instead of frame+promote.
  # NOT a correctness requirement. OwnershipDataflow marks returned values as :moved
  # regardless of allocator. Without this, programs work but do runtime promotions.
  def upgrade_always_escaped_to_heap!(fn, plan)
    return_nodes = []
    AST.walk_body(fn.body) { |n| return_nodes << n if n.is_a?(AST::ReturnNode) }
    return if return_nodes.empty?

    always_escaped = plan[:var_promotes].select do |vp|
      return_nodes.all? { |ret| ret.value && return_references_var?(ret.value, vp[:var]) }
    end
    return if always_escaped.empty?

    always_names = Set.new
    always_escaped.each do |vp|
      ident = find_return_identifier(return_nodes, vp[:var])
      next unless ident

      # Upgrade declaration node
      decl = ident.symbol&.reg
      if decl&.respond_to?(:storage=)
        decl.storage = :heap
      end
      decl_ti = decl&.type_info rescue nil
      if decl_ti.is_a?(Type)
        decl_ti.provenance = :heap
      end

      # Upgrade scope entry
      if ident.symbol
        ident.symbol.storage = :heap
        sym_type = ident.symbol.type
        if sym_type.is_a?(Type)
          sym_type.provenance = :heap
        end
      end

      always_names << vp[:var]
    end

    # Remove always-escaped vars from promotion plan (no MIR::Promote needed)
    plan[:var_promotes] = plan[:var_promotes].reject { |vp| always_names.include?(vp[:var]) }
  end

  # Check if a return value expression references a variable by name.
  def return_references_var?(node, var_name)
    case node
    when AST::Identifier then node.name == var_name
    when AST::StructLit, AST::UnionVariantLit
      node.fields.any? { |_, fval| return_references_var?(fval, var_name) }
    else false
    end
  end

  # Find an Identifier node for a variable name across all return nodes.
  def find_return_identifier(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = extract_identifier(ret.value, var_name)
      return ident if ident
    end
    nil
  end

  # Extract an Identifier node matching var_name from a return value expression.
  def extract_identifier(node, var_name)
    case node
    when AST::Identifier
      node.name == var_name ? node : nil
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_value { |fval| r = extract_identifier(fval, var_name); return r if r }
      nil
    else nil
    end
  end

  # Performance optimization: allocate BG-captured collections on heap from the start.
  # NOT a correctness requirement. OwnershipDataflow marks resource captures as :moved
  # regardless of allocator. Without this, programs work but do runtime promotions.
  #
  # Only collections (list/map) benefit: their allocator controls backing storage.
  # Strings still need MIR::Promote(:bg_string) because the data comes from
  # external sources and must be physically duped to heap at capture time.
  def upgrade_bg_captures_to_heap!(fn)
    # Collect captured collection variable names needing escape promotion.
    bg_capture_names = Set.new
    AST.walk_body(fn.body) do |stmt|
      each_bg_in_stmt(stmt) do |bg|
        captured = bg.capture_analysis&.captures
        next unless captured&.any?
        captured.each do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          next unless t && !t.needs_pointer_passing?
          next unless t.list_collection? || (t.map? && !t.numeric_map?) || t.pool? || t.set_collection?
          bg_capture_names << name
        end
      end
    end
    return if bg_capture_names.empty?

    # Track upgraded names so insert_bg_escape_promote! skips them.
    @bg_heap_upgraded ||= Set.new
    @bg_heap_upgraded.merge(bg_capture_names)

    # Find declarations and upgrade to heap.
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
      var_name = node.name.is_a?(String) ? node.name : node.name.to_s
      next unless bg_capture_names.include?(var_name)

      node.storage = :heap if node.respond_to?(:storage=)
      ti = node.type_info rescue nil
      if ti.is_a?(Type)
        ti.provenance = :heap
      end
    end
  end

  # Upgrade frame variables returned from heap-pointer functions to heap at declaration.
  # When RETURNS %Struct, every RETURN identifier must be heap-allocated so the
  # returned pointer is valid after the frame is rewound.
  def upgrade_heap_ptr_returns_to_heap!(fn)
    ret_type = fn.return_type
    ret_type = ret_type.is_a?(Type) ? ret_type : (Type.new(ret_type) rescue nil)
    return unless ret_type&.heap?

    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::Identifier)
      ident = node.value
      next unless ident.symbol
      next unless ident.symbol.storage == :frame || ident.symbol.storage == :stack
      next unless ident.symbol.type && (ident.symbol.type.is_a?(Type) ? ident.symbol.type : (Type.new(ident.symbol.type) rescue nil))&.requires_move?

      ident.symbol.storage = :heap
      decl = ident.symbol.reg
      if decl&.respond_to?(:storage=)
        decl.storage = :heap
        # Also upgrade the initializer value's storage so lower_struct_lit
        # generates HeapCreate instead of a plain StructInit.
        decl.value.storage = :heap if decl.respond_to?(:value) && decl.value&.respond_to?(:storage=)
      end
    end
  end

  # Upgrade frame collections assigned directly to heap struct/array fields to heap.
  # When `heap_struct.field = frame_list` or `heap_arr[i] = frame_list`, the list
  # must be heap-allocated so it survives beyond the current frame. Runs after
  # BG-capture upgrade so allocators are stable before CleanupClassifier runs.
  def upgrade_assign_escapes_to_heap!(fn)
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::Assignment)
      rhs = node.value
      next unless rhs.is_a?(AST::Identifier) && rhs.symbol

      # RHS must be frame/stack allocated
      rhs_storage = rhs.symbol.storage
      next unless rhs_storage == :frame || rhs_storage == :stack

      # RHS type must require explicit cleanup (non-copy heap collection)
      rhs_ti = rhs.symbol.type
      rhs_ti = rhs_ti.is_a?(Type) ? rhs_ti : (Type.new(rhs_ti) rescue nil)
      next unless rhs_ti&.requires_move?

      # LHS root must be heap-allocated
      lhs_root = extract_root_ident(node.name)
      next unless lhs_root.is_a?(AST::Identifier) && lhs_root.symbol
      next unless [:heap, :multiowned, :shared].include?(lhs_root.symbol.storage)

      # Upgrade: scope entry + declaration node.
      # type_info.provenance is intentionally NOT mutated here -- it may be a
      # shared Type object. classify_heap_struct_plain consults the schema via
      # node.storage alone, so @storage_override is the only write needed.
      rhs.symbol.storage = :heap
      decl = rhs.symbol.reg
      decl.storage = :heap if decl&.respond_to?(:storage=)
    end
  end

  def extract_root_ident(node)
    case node
    when AST::GetField, AST::GetIndex then extract_root_ident(node.target)
    when AST::Identifier then node
    else nil
    end
  end

  # Upgrade outer string variables used as loop-carry vars to heap.
  # These are outer string variables reassigned with frame-allocating expressions
  # inside a loop that has per-iteration rewinds (i.e., has non-escaping frame locals).
  # Without this promotion, the carry var's old frame value would be freed by the
  # per-iter rewind, leaving a dangling pointer.
  # Must run before Phase 2 (CleanupClassifier) so :heap provenance is visible.
  def upgrade_loop_string_carries_to_heap!(fn)
    carry_names = Set.new

    AST.walk_body(fn.body) do |node|
      body = case node
      when AST::WhileLoop  then (node.tight ? nil : node.do_branch)
      when AST::ForRange   then node.body
      when AST::ForEach    then node.body
      end
      next unless body

      local_names = LoopFrameAnalysis.collect_local_names(body)
      non_escaping = LoopFrameAnalysis.local_frame_decls(body, local_names).reject { |d|
        LoopFrameAnalysis.escapes_to_outer?(d.name.to_s, body, local_names)
      }
      next unless non_escaping.any?  # only when loop WILL have mark_per_iter

      frame_local_names = non_escaping.map { |d| d.name.to_s }.to_set

      # Identify carry vars: any outer string var reassigned inside a mark_per_iter loop.
      # The per-iter rewind corrupts ANY string value produced inside the loop body
      # (concats, method calls, function calls all use frameAlloc by default).
      # Promote ALL such reassignments to heap so the value survives the rewind.
      AST.walk_body(body) do |bind|
        next unless bind.is_a?(AST::BindExpr) && bind.mode == :assign
        next unless bind.name.is_a?(String) && !local_names.include?(bind.name)
        ti = bind.type_info rescue nil
        next unless ti.is_a?(Type) && ti.string?
        carry_names << bind.name
        LoopFrameAnalysis.promote_value_to_heap!(bind.value)
      end
    end
    return if carry_names.empty?

    # Promote initial declarations of carry vars to heap.
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
      var_name = node.name.is_a?(String) ? node.name : node.name.to_s
      next unless carry_names.include?(var_name)
      node.storage = :heap if node.respond_to?(:storage=)
      ti = node.type_info rescue nil
      if ti.is_a?(Type)
        ti.provenance = :heap
      end
      if node.respond_to?(:value) && node.value.respond_to?(:storage=)
        node.value.storage = :heap
      end
    end

    # If the function returns a carry var directly (heap string), mark it so
    # collect_return_escapes can add a moved guard and SuppressCleanup before return.
    ret_type = fn.return_type.is_a?(Type) ? fn.return_type : (fn.return_type ? Type.new(fn.return_type) : Type.new(:Void))
    if ret_type.string?
      carry_return_names = Set.new
      AST.walk_body(fn.body) do |node|
        next unless node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::Identifier)
        carry_return_names << node.value.name if carry_names.include?(node.value.name)
      end
      unless carry_return_names.empty?
        fn.heap_carry_return = true
        fn.heap_carry_return_vars = carry_return_names
      end
    end
  end

  # Phase 1.5d: walk fn body and set heap_provenance on call-site expressions
  # whose callee is in carry_fns (set of function names with heap_carry_return=true).
  # This allows Phase 0 (HPT hoisting) to register cleanup at call sites.
  # Also upgrades direct bind declarations whose RHS is a carry call, so that
  # CleanupClassifier (Phase 2) sees heap_provenance on the binding itself.
  def mark_heap_carry_call_sites!(fn, carry_fns)
    AST.walk_body(fn.body) do |stmt|
      # For direct binds whose value is a carry call, upgrade the binding type too.
      if (stmt.is_a?(AST::VarDecl) || (stmt.is_a?(AST::BindExpr) && stmt.mode == :decl))
        val = stmt.value
        if val.is_a?(AST::FuncCall) || val.is_a?(AST::MethodCall)
          fn_name = val.is_a?(AST::FuncCall) ? val.name.to_s : val.name.to_s
          if carry_fns.include?(fn_name)
            # Upgrade the call's type_info
            call_ti = val.type_info rescue nil
            call_ti.provenance = :heap if call_ti.is_a?(Type) && !call_ti.heap_provenance?
            # Upgrade the binding's full_type so CleanupClassifier sees heap_provenance
            bind_ti = stmt.type_info rescue nil
            bind_ti.provenance = :heap if bind_ti.is_a?(Type) && !bind_ti.heap_provenance?
            bt2 = stmt.respond_to?(:full_type) ? stmt.full_type : nil
            bt2.provenance = :heap if bt2.is_a?(Type) && !bt2.heap_provenance?
          end
        end
        next  # no need to recurse into sub-expressions for declaration bind values
      end
      exprs = stmt_top_level_exprs(stmt)
      exprs.each { |e| mark_heap_expr_if_carry!(e, carry_fns) }
    end
  end

  def stmt_top_level_exprs(stmt)
    case stmt
    when AST::VarDecl, AST::BindExpr then [stmt.value]
    when AST::Assignment              then [stmt.value]
    when AST::ReturnNode              then [stmt.value]
    when AST::Assert                  then [stmt.condition, stmt.message]
    when AST::FuncCall, AST::MethodCall then [stmt]
    when AST::IfStatement             then [stmt.condition]
    when AST::MatchStatement          then [stmt.expr]
    when AST::ForEach                 then [stmt.collection]
    else []
    end.compact
  end

  def mark_heap_expr_if_carry!(node, carry_fns)
    return unless node
    case node
    when AST::FuncCall
      fn_name = node.name.to_s
      if carry_fns.include?(fn_name)
        ti = node.type_info rescue nil
        ti.provenance = :heap if ti.is_a?(Type) && !ti.heap_provenance?
      end
      node.args&.each { |a| mark_heap_expr_if_carry!(a, carry_fns) }
    when AST::MethodCall
      fn_name = node.name.to_s
      if carry_fns.include?(fn_name)
        ti = node.type_info rescue nil
        ti.provenance = :heap if ti.is_a?(Type) && !ti.heap_provenance?
      end
      mark_heap_expr_if_carry!(node.object, carry_fns)
      node.args&.each { |a| mark_heap_expr_if_carry!(a, carry_fns) }
    when AST::BinaryOp
      mark_heap_expr_if_carry!(node.left, carry_fns)
      mark_heap_expr_if_carry!(node.right, carry_fns)
    when AST::UnaryOp
      mark_heap_expr_if_carry!(node.right, carry_fns)
    when AST::GetField
      mark_heap_expr_if_carry!(node.target, carry_fns)
    when AST::GetIndex
      mark_heap_expr_if_carry!(node.target, carry_fns)
      mark_heap_expr_if_carry!(node.index, carry_fns)
    end
  end

  def transform_function!(fn, promo)
    bindings = @cleanup_bindings[fn.name]
    has_bindings = bindings && !bindings.empty?
    promo = nil if promo&.empty?

    fn.has_promotion = true if promo

    has_bg_escapes = body_has_bg_escape_promotes?(fn.body)
    has_catch = fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?

    # BG scope-exit annotation runs unconditionally: the function may have no
    # bindings/promotions but still contain BG blocks returning frame values.
    annotate_bg_exits_in_body!(fn.body)

    return unless has_bindings || promo || has_bg_escapes || has_catch

    # Borrow checking: verify no moves of borrowed variables inside WITH blocks.
    bc_errors = BorrowChecker.check(fn, schema_lookup: @schema_lookup)
    unless bc_errors.empty?
      raise "[Borrow Error] #{bc_errors.first}"
    end

    # Pre-mark bindings captured by BG blocks so has_moved_guard is correct
    # BEFORE cleanup_decisions! runs and Drops snapshot cleanup_entry.
    pre_mark_bg_resource_captures!(fn, bindings) if has_bindings

    # Ownership dataflow refines cleanup decisions: determines WHETHER cleanup
    # is needed and WHETHER a moved guard is required, based on per-path analysis.
    # Also runs UseAfterMoveChecker (Rule 1: no use after move).
    @last_dataflow = nil
    if has_bindings
      can_fail_fns = Set.new
      @fn_nodes.each { |name, f| can_fail_fns << name if f.can_fail }
      @last_dataflow = OwnershipDataflow.analyze(fn, can_fail_fns: can_fail_fns, schema_lookup: @schema_lookup)
      @last_dataflow.cleanup_decisions!(fn, bindings)
    end

    # Patch heap carry return vars: refine_moved_guards! (called inside cleanup_decisions!)
    # sets has_moved_guard=false for string vars because strings are Copy types and
    # are never GIVE'd in OwnershipDataflow.  But carry return vars ARE transferred to the
    # caller implicitly via RETURN.  Override the flag so MIR::Drop emits a guarded defer
    # and collect_return_escapes emits SuppressCleanup before the return.
    if fn.respond_to?(:heap_carry_return_vars) && fn.heap_carry_return_vars&.any? && bindings
      fn.heap_carry_return_vars.each do |var_name|
        entry = bindings[var_name.to_s]
        next unless entry && entry[:needs_cleanup]
        entry[:has_moved_guard] = true
      end
    end

    # Sync frame→heap alloc in entries where LoopFrameAnalysis (Phase 2.5) upgraded
    # the type_info.  CleanupClassifier may have classified as :frame, but the node's
    # type_info now says heap_provenance? = true.  Walk the body once to apply the fix.
    if has_bindings
      AST.walk_body(fn.body) do |node|
        name = case node
               when AST::VarDecl  then node.name.to_s
               when AST::BindExpr then node.mode == :decl ? node.name.to_s : nil
               else nil
               end
        next unless name
        entry = bindings[name]
        next unless entry && entry[:alloc] == :frame
        ti = node.type_info rescue nil
        bindings[name] = entry.merge(alloc: :heap) if ti.is_a?(Type) && ti.heap_provenance?
      end
    end

    # Stamp cleanup_bindings on the FunctionDef so MIRLowering can read
    # allocator + cleanup info without relying on OLD MIR::Alloc/Drop siblings.
    fn.cleanup_bindings = bindings

    # Stamp has_cleanup / cleanup_alloc on each decl node for spec/external compatibility.
    # (These fields are no longer read by MIRLowering; cleanup is driven by cleanup_bindings.)
    stamp_decl_cleanup_fields!(fn.body, bindings) if has_bindings

    # Stamp field pre-cleanup info directly on Assignment nodes.
    CleanupClassifier.stamp_field_pre_cleanups!(fn.body, bindings, schema_lookup: @schema_lookup) if has_bindings

    @fn_has_catch = has_catch
    @current_transform_fn = fn
    fn.body = transform_body(fn.body, bindings, promo)
    @current_transform_fn = nil

    # Transform catch clause bodies so MIR::Promote(:catch_string_dupe) is
    # inserted before string returns in error recovery paths.
    if has_catch
      fn.catch_clauses.each do |clause|
        clause[:body] = transform_body(clause[:body], nil, nil) if clause[:body]
      end
      if fn.default_catch.is_a?(Array)
        fn.default_catch = transform_body(fn.default_catch, nil, nil)
      end
    end
    @fn_has_catch = false

    # Build moved_guard_info map: { var_name => bool } for all bindings.
    stamp_moved_guard_info!(fn, bindings) if has_bindings

  end

  # Pre-mark bindings that are captured by BG blocks as needing moved guards.
  # This runs BEFORE refine_moved_guards! so that when Drops are later created
  # (which snapshot cleanup_entry = entry.dup), the has_moved_guard flag is
  # already correct. Without this, insert_bg_resource_suppress! would mutate
  # bindings AFTER Drops were created, causing a split between the Drop's
  # snapshot and the binding's current state.
  def pre_mark_bg_resource_captures!(fn, bindings)
    walk_for_bg_captures(fn.body, bindings)
  end

  def walk_for_bg_captures(stmts, bindings)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      each_bg_in_stmt(stmt) do |bg|
        resource_captures = bg.capture_analysis&.resource_captures
        next unless resource_captures&.any?
        resource_captures.each do |name|
          entry = bindings&.dig(name)
          next unless entry && entry[:needs_cleanup]
          entry[:has_moved_guard] = true
        end
      end
      # Recurse into nested control flow.
      case stmt
      when AST::IfStatement
        walk_for_bg_captures(stmt.then_branch, bindings)
        walk_for_bg_captures(stmt.else_branch, bindings)
      when AST::WhileLoop
        walk_for_bg_captures(stmt.do_branch, bindings)
      when AST::ForRange, AST::ForEach
        walk_for_bg_captures(stmt.body, bindings)
      when AST::MatchStatement
        stmt.cases&.each { |c| walk_for_bg_captures(c[:body], bindings) }
        walk_for_bg_captures(stmt.default_case, bindings)
      when AST::WithBlock
        walk_for_bg_captures(stmt.body, bindings)
      when AST::DoBlock
        stmt.branches&.each { |b| walk_for_bg_captures(b[:body], bindings) }
      when AST::BgBlock, AST::BgStreamBlock
        walk_for_bg_captures(stmt.body, bindings)
      end
    end
  end

  # Recursively transform a statement list, inserting MIR nodes.
  # Returns a new array (does not mutate the input).
  def transform_body(stmts, bindings, promo)
    return stmts unless stmts.is_a?(Array)
    result = []
    stmts.each do |stmt|
      # Recurse into nested control flow first.
      recurse_branches!(stmt, bindings, promo)

      # Insert Return (escape markers) + Promote before ReturnNode.
      if stmt.is_a?(AST::ReturnNode)
        insert_return!(result, stmt, bindings, fn_node: @current_transform_fn)
        insert_promotion!(result, stmt, promo)
        # Catch string dupe: heap-dupe string returns so both success and
        # error paths have consistent allocation for caller cleanup.
        insert_catch_string_dupe!(result, stmt) if @fn_has_catch
      end

      # Stamp cleanup info on reassignment / match-as nodes.
      stamp_reassign_cleanup!(stmt, bindings)
      stamp_match_as_cleanup!(stmt, bindings)

      # Insert MIR::Promote before container stores that need frame-to-heap promotion.
      insert_container_promote!(result, stmt)

      # BG escape promotions: frame-allocated captures must be promoted to heap.
      insert_bg_escape_promote!(result, stmt)

      # BG scope-exit promotion: annotate BgBlocks with what their exit value needs.
      # Must run after recurse_branches! so the BgBlock body is already transformed.
      each_bg_in_stmt(stmt) do |bg|
        if bg.is_a?(AST::BgBlock)
          annotate_bg_exit_promote!(bg)
        elsif bg.is_a?(AST::BgStreamBlock)
          annotate_yield_string_dupes!(bg)
        end
      end

      # OrRescue fallback dupe: when success path is heap-promoted and fallback
      # is a struct literal, string fields need heap-duping for consistent cleanup.
      insert_or_fallback_dupe!(result, stmt)

      # Emit the original statement.
      result << stmt

      # Insert MIR verification nodes for reassignment and field pre-cleanup.
      if stmt.is_a?(AST::BindExpr) && stmt.reassign_cleanup
        result << MIR::ReassignCleanup.new(stmt.token, stmt.name.to_s, stmt.reassign_cleanup[:alloc])
      end
      if stmt.is_a?(AST::Assignment) && stmt.field_pre_cleanup
        target = stmt.name
        target_name = target.is_a?(AST::GetField) && target.target.respond_to?(:name) ? target.target.name.to_s : nil
        result << MIR::FieldCleanup.new(stmt.token, target_name, target.field, stmt.field_pre_cleanup[:alloc]) if target_name
      end

      # Insert SuppressCleanup after statements that consume bindings.
      insert_suppress_cleanup!(result, stmt, bindings)

      # BG blocks that capture resources transfer ownership — suppress outer cleanup.
      insert_bg_resource_suppress!(result, stmt, bindings)
    end
    result
  end

  # Recurse into control flow branches to transform nested bodies.
  def recurse_branches!(stmt, bindings, promo)
    case stmt
    when AST::IfStatement
      stmt.then_branch = transform_body(stmt.then_branch, bindings, promo) if stmt.then_branch
      stmt.else_branch = transform_body(stmt.else_branch, bindings, promo) if stmt.else_branch
    when AST::WhileLoop
      stmt.do_branch = transform_body(stmt.do_branch, bindings, promo) if stmt.do_branch
    when AST::ForRange, AST::ForEach
      stmt.body = transform_body(stmt.body, bindings, promo) if stmt.body
    when AST::MatchStatement
      stmt.cases&.each { |c| c[:body] = transform_body(c[:body], bindings, promo) if c[:body] }
      if stmt.default_case
        stmt.default_case = transform_body(stmt.default_case, bindings, promo)
      end
    when AST::WithBlock
      stmt.body = transform_body(stmt.body, bindings, promo) if stmt.body
    when AST::DoBlock
      stmt.branches&.each do |b|
        b[:body] = transform_body(b[:body], bindings, promo) if b[:body]
      end
    when AST::BgBlock, AST::BgStreamBlock
      stmt.body = transform_body(stmt.body, bindings, promo) if stmt.body
    end
    # Process BgBlock bodies found in expression positions (MethodCall/FuncCall
    # args, VarDecl/BindExpr values). AST.walk_body misses these since it doesn't
    # recurse into call arguments. Only BgBlock (outer consumer fiber) -- not
    # BgStreamBlock (generator fiber has special YIELD handling).
    case stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      val = stmt.respond_to?(:value) ? stmt.value : nil
      if val.is_a?(AST::BgBlock) && val.body
        val.body = transform_body(val.body, bindings, promo)
      end
    when AST::MethodCall, AST::FuncCall
      stmt.args&.each do |a|
        if a.is_a?(AST::BgBlock) && a.body
          a.body = transform_body(a.body, bindings, promo)
        end
      end
    end
  end

  # Insert MIR::SuppressCleanup after statements that consume ownership of
  # tracked bindings. Replaces the transpiler's emit_move_suppression and
  # emit_consumed_moves methods.
  def insert_suppress_cleanup!(result, stmt, bindings)
    return unless bindings
    return if stmt.is_a?(AST::ReturnNode) # handled by insert_return!

    names = collect_consumed_names(stmt, bindings)
    names.each do |name|
      result << MIR::SuppressCleanup.new(stmt.token, name)
    end
  end

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values (VarDecl, BindExpr, Assignment), MethodCall args,
  # FuncCall args. Yields each BgBlock/BgStreamBlock found.
  def each_bg_in_stmt(stmt, &block)
    case stmt
    when AST::BgBlock, AST::BgStreamBlock
      yield stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      _walk_expr_for_bg(stmt.value, &block)
    when AST::FuncCall
      stmt.args&.each { |a| _walk_expr_for_bg(a, &block) }
    when AST::MethodCall
      stmt.args&.each { |a| _walk_expr_for_bg(a, &block) }
    end
  end

  def _walk_expr_for_bg(expr, &block)
    return unless expr
    case expr
    when AST::BgBlock, AST::BgStreamBlock
      yield expr
    when AST::FuncCall
      expr.args&.each { |a| _walk_expr_for_bg(a, &block) }
    when AST::MethodCall
      _walk_expr_for_bg(expr.object, &block)
      expr.args&.each { |a| _walk_expr_for_bg(a, &block) }
    end
  end

  # Insert MIR::SuppressCleanup for resources captured by BG blocks.
  # When a BG fiber captures a resource (TCP fd, etc.), ownership transfers
  # to the fiber — the outer scope's defer must not close it.
  #
  # Resource variables always emit a guarded_defer (moved guard pattern)
  # regardless of scope depth. We must insert SuppressCleanup whenever a
  # BG block captures a resource — even for inner-scope variables that
  # don't appear in the function-level bindings hash.
  def insert_bg_resource_suppress!(result, stmt, bindings)
    each_bg_in_stmt(stmt) do |bg|
      resource_captures = bg.capture_analysis&.resource_captures
      next unless resource_captures&.any?
      resource_captures.each do |name|
        entry = bindings&.dig(name)
        # When dataflow says always-moved (needs_cleanup=false), no Drop was
        # inserted - the fiber is the sole owner. No suppress needed.
        next if entry && !entry[:needs_cleanup]
        # has_moved_guard was already set by pre_mark_bg_resource_captures!
        result << MIR::SuppressCleanup.new(stmt.token, name)
      end
    end
  end

  # Quick check: does the function body contain any BG/stream blocks with
  # captures needing escape promotion? Used to ensure transform_body runs
  # even for functions with no cleanup bindings.
  def body_has_bg_escape_promotes?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |stmt|
      found = false
      each_bg_in_stmt(stmt) do |bg|
        captured = bg.capture_analysis&.captures
        next unless captured&.any?
        found = true if captured.any? do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          t && t.needs_escape_promotion? && !t.needs_pointer_passing? && !@bg_heap_upgraded&.include?(name)
        end
      end
      found
    end
  end

  # Annotate a BgBlock with the scope-exit promotion its last expression needs.
  # Mirrors the logic insert_promotion!/insert_catch_string_dupe! apply to
  # function ReturnNodes, but for the BG fiber's implicit return value.
  # Currently handles strings; struct field promotion is left for future work.
  # Walk a statement list looking for BgBlocks (in expression position) and
  # annotate each with the scope-exit promotion its last expression needs.
  # Must run unconditionally — the outer function may have no bindings/promotions
  # but still contain BG blocks that return frame-allocated values.
  def annotate_bg_exits_in_body!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      each_bg_in_stmt(stmt) { |bg| annotate_bg_exit_promote!(bg) if bg.is_a?(AST::BgBlock) }
      # Recurse into control-flow branches.
      case stmt
      when AST::IfStatement
        annotate_bg_exits_in_body!(stmt.then_branch)
        annotate_bg_exits_in_body!(stmt.else_branch)
      when AST::WhileLoop
        annotate_bg_exits_in_body!(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        annotate_bg_exits_in_body!(stmt.body)
      when AST::MatchStatement
        stmt.cases&.each { |c| annotate_bg_exits_in_body!(c[:body]) }
        annotate_bg_exits_in_body!(stmt.default_case)
      when AST::WithBlock
        annotate_bg_exits_in_body!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| annotate_bg_exits_in_body!(b[:body]) }
      end
    end
  end

  def annotate_bg_exit_promote!(bg_node)
    body = bg_node.body
    return unless body.is_a?(Array)

    # Walk backward past MIR marker nodes to find the last real expression.
    last_expr = nil
    body.reverse_each do |stmt|
      next if stmt.is_a?(MIR::Alloc) || stmt.is_a?(MIR::Drop) ||
              stmt.is_a?(MIR::SuppressCleanup) || stmt.is_a?(MIR::Return) ||
              stmt.is_a?(MIR::Promote) || stmt.is_a?(MIR::AllocMark) ||
              stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::MoveMark)
      last_expr = stmt.is_a?(AST::ThenChain) ? stmt.steps.last&.dig(:expr) : stmt
      break
    end

    return unless last_expr
    return if last_expr.is_a?(AST::Assignment)

    ft = last_expr.respond_to?(:full_type) ? last_expr.full_type : nil
    return unless ft
    t = ft.is_a?(Type) ? ft : Type.new(ft)
    return if t.void?

    bg_node.exit_promote = { strategy: :string_dupe } if bg_exit_needs_string_dupe?(last_expr, t)
  end

  # Returns true when a BG block's last expression is a frame-allocated string
  # that will be invalidated when the fiber's frame is rewound on exit.
  # - rodata strings (literals) live in the binary — safe without dupe.
  # - heap strings are already owned by the caller — no dupe needed.
  # - frame strings (from allocating stdlib calls or frame-provenance types) must be duped.
  def bg_exit_needs_string_dupe?(expr, t)
    return false unless t.string?
    return false if t.heap? || t.rodata?
    return true  if t.frame?
    # No explicit provenance: check the stdlib def for frame allocation.
    if expr.respond_to?(:matched_stdlib_def)
      msd = expr.matched_stdlib_def
      return true if msd.is_a?(Hash) && msd[:return_alloc] == :frame
    end
    false
  end

  # Annotate YieldExpr nodes inside a BgStreamBlock that yield frame-allocated strings.
  # Sets yield_node.yield_dupe = true; the lowerer then wraps the push arg in a heap dupe.
  def annotate_yield_string_dupes!(stream_node)
    walk_stream_yields(stream_node.body)
  end

  def walk_stream_yields(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      if stmt.is_a?(AST::YieldExpr)
        ft = stmt.expr.respond_to?(:full_type) ? stmt.expr.full_type : nil
        t = ft.is_a?(Type) ? ft : (ft ? Type.new(ft) : nil)
        stmt.yield_dupe = true if t && bg_exit_needs_string_dupe?(stmt.expr, t)
      else
        case stmt
        when AST::WhileLoop    then walk_stream_yields(stmt.do_branch)
        when AST::ForRange, AST::ForEach then walk_stream_yields(stmt.body)
        when AST::IfStatement
          walk_stream_yields(stmt.then_branch)
          walk_stream_yields(stmt.else_branch)
        when AST::BgStreamBlock  # stop at nested stream boundaries
        end
      end
    end
  end

  # Insert MIR::Promote for frame-allocated variables captured by BG/stream fibers.
  # Lists get :list strategy (in-place promoteList). Strings get :bg_string
  # strategy (transpiler emits dupe inside the BG block where the allocator is available).
  def insert_bg_escape_promote!(result, stmt)
    each_bg_in_stmt(stmt) do |bg|
      captured = bg.capture_analysis&.captures
      next unless captured&.any?
      captured.each do |name, type_obj|
        t = type_obj ? Type.new(type_obj) : nil
        next unless t && t.needs_escape_promotion?
        next if t.needs_pointer_passing?
        next if @bg_heap_upgraded&.include?(name)  # Already heap from Phase 1.5b
        if t.list_collection?
          result << MIR::Promote.new(bg.token, name, t.zig_type, :list, nil)
        else
          # :bg_string: annotate directly on BgBlock (no MIR::Promote needed)
          bg.capture_string_dupes ||= Set.new
          bg.capture_string_dupes.add(name)
        end
      end
    end
  end

  # Annotate the ReturnNode when a catch function returns a string type.
  # Both success and error paths must return heap-backed strings for
  # consistent caller cleanup. Annotation on the node replaces the old
  # MIR::Promote(:catch_string_dupe) pending-flag mechanism.
  def insert_catch_string_dupe!(result, ret_node)
    return unless ret_node.value
    ft = ret_node.value.respond_to?(:full_type) ? ret_node.value.full_type : nil
    return unless ft
    t = Type.new(ft)
    return unless t.string?
    ret_node.catch_string_dupe_ret = true
  end

  # Annotate an OrRescue node where the success path is heap-promoted and the
  # fallback is a struct literal. Sets or_fallback_dupe on the BinaryOp so the
  # transpiler heap-dupes string fields in the fallback to match cleanup semantics.
  def insert_or_fallback_dupe!(result, stmt)
    or_node = find_or_rescue_in_value(stmt)
    return unless or_node
    return unless or_node.right.is_a?(AST::StructLit)
    return unless or_rescue_needs_fallback_dupe?(or_node)
    # Annotate directly on BinaryOp node (no MIR::Promote needed)
    or_node.or_fallback_dupe = true
  end

  # Walk into a statement's value expression to find an OrRescue node.
  def find_or_rescue_in_value(stmt)
    expr = case stmt
           when AST::VarDecl, AST::BindExpr then stmt.value
           when AST::Assignment then stmt.value
           when AST::ReturnNode then stmt.value
           else nil
           end
    find_or_rescue_expr(expr)
  end

  def find_or_rescue_expr(expr)
    return nil unless expr
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      return expr
    end
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR
      return find_or_rescue_expr(expr.left)
    end
    nil
  end

  # Check if an OrRescue's success path is heap-promoted (same logic as
  # the transpiler's has_heap_promoted_call? but at MIR insertion time).
  def or_rescue_needs_fallback_dupe?(or_node)
    return false unless or_node.is_a?(AST::BinaryOp) && or_node.op == :OR_RESCUE
    left = or_node.left
    ti = left.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    return true if ti&.heap_provenance?
    if left.is_a?(AST::BinaryOp) && (left.op == :OR || left.op == :OR_RESCUE)
      return or_rescue_needs_fallback_dupe_left?(left)
    end
    false
  end

  def or_rescue_needs_fallback_dupe_left?(expr)
    return false unless expr
    ti = expr.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    return true if ti&.heap_provenance?
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return or_rescue_needs_fallback_dupe_left?(expr.left)
    end
    false
  end

  # Collect names of bindings consumed by a statement.
  # Three consumption paths:
  #   1. Direct RHS: identifier used as value in assignment/declaration
  #   2. Standalone GIVE: `GIVE x;` as a statement
  #   3. Nested: identifier passed as TAKES/GIVE arg or used as struct field
  def collect_consumed_names(stmt, bindings)
    names = Set.new

    # 1. Direct RHS consumption
    rhs = case stmt
          when AST::VarDecl    then stmt.value
          when AST::BindExpr   then stmt.value
          when AST::Assignment then stmt.value
          else nil
          end

    if rhs
      is_move = rhs.is_a?(AST::MoveNode)
      ident = is_move ? rhs.value : rhs
      add_if_consumed(ident, names, bindings, is_move) if ident.is_a?(AST::Identifier)
    end

    # 2. Standalone GIVE: `GIVE x;` as a bare statement
    if stmt.is_a?(AST::MoveNode) && stmt.value.is_a?(AST::Identifier)
      add_if_consumed(stmt.value, names, bindings, true)
    end

    # 2. Nested consumption (StructLit fields, FuncCall/MethodCall TAKES args)
    value_expr = case stmt
                 when AST::VarDecl, AST::BindExpr then stmt.value
                 when AST::Assignment then stmt.value
                 else stmt
                 end
    value_expr = value_expr.value if value_expr.is_a?(AST::MoveNode)
    walk_consumed(value_expr, names, bindings)

    names
  end

  # Recursively walk an expression to find consumed identifiers in
  # StructLit fields and FuncCall/MethodCall TAKES/GIVE args.
  def walk_consumed(node, names, bindings)
    return unless node
    case node
    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      walk_consumed(node.value, names, bindings)
    when AST::StructLit
      node.fields.each_value do |v|
        if v.is_a?(AST::Identifier)
          add_if_consumed(v, names, bindings, false)
        else
          walk_consumed(v, names, bindings)
        end
      end
    when AST::FuncCall, AST::MethodCall
      node.args.each do |a|
        if a.is_a?(AST::MoveNode) && a.value.is_a?(AST::Identifier)
          add_if_consumed(a.value, names, bindings, true)
        elsif a.respond_to?(:was_moved) && a.was_moved && a.is_a?(AST::Identifier)
          add_if_consumed(a, names, bindings, true)
        end
      end
    end
  end

  # Add identifier to consumed set if it has a moved guard and passes
  # Copy-type filters. RC types only consume on explicit GIVE (MoveNode).
  def add_if_consumed(ident, names, bindings, is_move)
    name = ident.name.to_s
    entry = bindings[name]
    return unless entry && entry[:has_moved_guard] && entry[:needs_cleanup]

    ti = ident.type_info
    return if ti&.string?

    # RC types: only consume on explicit GIVE
    if ti && (ti.any_rc? rescue false)
      names << name if is_move
      return
    end

    names << name
  end

  # Stamp reassign_cleanup on BindExpr :assign nodes that overwrite non-Copy variables.
  def stamp_reassign_cleanup!(stmt, bindings)
    return unless bindings
    return unless stmt.is_a?(AST::BindExpr) && stmt.mode == :assign

    entry = bindings[stmt.name.to_s]
    return unless entry && entry[:needs_cleanup] && entry[:kind] != :resource

    ti = stmt.type_info
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    zig_type = ti ? (Type.new(ti.resolved).zig_type rescue ti.resolved.to_s) : "UNKNOWN"
    stmt.reassign_cleanup = { kind: entry[:kind], alloc: entry[:alloc], zig_type: zig_type }
  end

  # Insert MIR nodes for MATCH-AS cleanup into case bodies.
  # Previously stamp-only; now inserts MIR::Alloc + MIR::Drop + MIR::SuppressCleanup
  # so the checker verifies match_as cleanup like any other binding.
  def stamp_match_as_cleanup!(stmt, bindings)
    return unless bindings
    return unless stmt.is_a?(AST::MatchStatement)
    return unless stmt.expr.is_a?(AST::Identifier) && stmt.expr.was_moved

    src_entry = bindings[stmt.expr.name.to_s]
    has_as_cleanup = false

    stmt.cases&.each do |c|
      next unless c[:binding]
      as_entry = bindings[c[:binding].to_s]
      next unless as_entry && as_entry[:needs_cleanup]

      has_as_cleanup = true

      # Insert MIR nodes at the start of case body for checker coverage.
      # Order: source suppression, then AS binding Alloc + Drop.
      mir_prefix = []
      if src_entry && src_entry[:needs_cleanup]
        mir_prefix << MIR::SuppressCleanup.new(stmt.token, stmt.expr.name.to_s)
      end
      mir_prefix << MIR::Alloc.new(stmt.token, c[:binding].to_s, as_entry[:kind], as_entry[:alloc])
      drop = MIR::Drop.new(
        stmt.token, c[:binding].to_s, as_entry[:kind], as_entry[:alloc],
        true, nil, nil, nil
      )
      drop.cleanup_entry = as_entry
      mir_prefix << drop
      c[:body] = mir_prefix + (c[:body] || [])
    end

    # Ensure source has moved guard so _moved variable exists for suppression.
    # Only set if the source still needs cleanup (dataflow may have eliminated it).
    src_entry[:has_moved_guard] = true if has_as_cleanup && src_entry && src_entry[:needs_cleanup]
  end

  # Insert MIR::Promote before indexed Assignment nodes where the container's
  # INDEX_OPS :set has takes_value and the value type needs frame-to-heap
  # promotion. Driven by the INDEX_OPS registry in std_lib.rb.
  def insert_container_promote!(result, stmt)
    return unless stmt.is_a?(AST::Assignment)
    return unless stmt.name.is_a?(AST::GetIndex)
    target_node = stmt.name.target

    # Look up the INDEX_OPS :set entry for this container type.
    target_ti = target_node.type_info rescue nil
    target_ti = Type.new(target_ti) if target_ti && !target_ti.is_a?(Type)
    set_op = resolve_container_set_op(target_ti)
    return unless set_op && set_op[:takes_value]

    # Check if the value type needs frame-to-heap promotion.
    # Strings are handled by the :dupe_string_literal transform in the lowerer;
    # :container_promote only fires for !string? values.
    val_ti = stmt.value.type_info rescue nil
    return unless val_ti
    val_ti = Type.new(val_ti) if val_ti && !val_ti.is_a?(Type)
    return unless val_ti.needs_promotion?(@schema_lookup) && !val_ti.string?

    # Annotate directly on Assignment node (no MIR::Promote needed)
    stmt.container_promote_zig_type = val_ti.zig_type
  end

  # Resolve the INDEX_OPS :set entry for a container type.
  def resolve_container_set_op(type_info)
    return nil unless type_info
    kind = container_kind(type_info)
    return nil unless kind
    INDEX_OPS.dig(kind, :set)
  end

  # Map a type to its INDEX_OPS container kind symbol.
  def container_kind(type_info)
    type_info&.dispatch_key
  end


  # Build moved_guard_info: { var_name => bool } for all bindings.
  def stamp_moved_guard_info!(fn, bindings)
    info = {}
    bindings.each do |name, entry|
      info[name] = true if entry[:has_moved_guard] && entry[:needs_cleanup]
    end
    fn.moved_guard_info = info unless info.empty?
  end

  # Insert MIR::Promote before a return statement and annotate the
  # ReturnNode for struct-level promotion wrapping.
  #
  # Defer suppression for escaped variables is handled by MIR::Return
  # (inserted by insert_return!) and consumed by the transpiler's
  # collect_escaping_identifiers in the ReturnNode handler.
  def insert_promotion!(result, ret_node, promo)
    return unless promo && !promo.empty?

    filtered = PromotionClassifier.filter_for_return(promo, ret_node.value)

    # Per-variable promotions.
    (filtered[:var_promotes] || []).each do |vp|
      strategy = classify_promote_strategy(vp[:zig_type])
      result << MIR::Promote.new(ret_node.token, vp[:var], vp[:zig_type], strategy, nil)
    end

    # Struct-level field promotion: annotate the ReturnNode directly so
    # lower_return can apply promotion without global pending-flag state.
    if filtered[:struct_promote] && PromotionClassifier.needs_promote?(filtered, ret_node)
      ret_node.promote_ret_wrap = :var
      ret_node.ret_field_promote_data = {
        zig_type: filtered[:struct_promote],
        fields:   filtered[:unhandled_promote_fields]
      }
    elsif filtered[:var_promotes]&.any?
      ret_node.promote_ret_wrap = :const
    end
  end

  # Insert MIR::Return before a ReturnNode to mark which local variables'
  # ownership escapes to the caller. The checker uses this to know that
  # escaped vars don't need local cleanup.
  def insert_return!(result, ret_node, bindings, fn_node: nil)
    return unless bindings
    escaped = collect_return_escapes(ret_node, bindings, fn_node: fn_node)
    return if escaped.empty?
    result << MIR::Return.new(ret_node.token, escaped)
    # Insert SuppressCleanup for each escaped var so the transpiler doesn't
    # need to re-compute escape analysis.
    escaped.each do |name|
      result << MIR::SuppressCleanup.new(ret_node.token, name)
    end
  end

  # Walk a return expression and collect variable names whose ownership
  # transfers to the caller. Mirrors transpiler's collect_escaping_identifiers
  # but filters to bindings with has_moved_guard (those needing suppression).
  def collect_return_escapes(ret_node, bindings, fn_node: nil)
    return [] unless ret_node.value
    ids = collect_escaping_ids(ret_node.value)
    ids.map { |id| id.name.to_s }
       .select { |n| bindings[n]&.dig(:has_moved_guard) && bindings[n]&.dig(:needs_cleanup) }
       .uniq
  end

  def collect_escaping_ids(node)
    return [] unless node
    case node
    when AST::Identifier then [node]
    when AST::MoveNode   then collect_escaping_ids(node.value)
    when AST::StructLit  then node.fields.values.flat_map { |v| collect_escaping_ids(v) }
    when AST::FuncCall, AST::MethodCall
      node.args.select { |a| a.respond_to?(:was_moved) && a.was_moved }
               .flat_map { |a| collect_escaping_ids(a) }
    when AST::CopyNode, AST::CloneNode then []
    else []
    end
  end

  def classify_promote_strategy(zig_type)
    return :generic unless zig_type
    if zig_type.include?("ArrayListUnmanaged")
      :list
    elsif zig_type.include?("StringMap")
      :string_map
    else
      :generic
    end
  end

  # Recomputes fn.return_provenance for all functions after annotation.
  # visit_ReturnNode sets it for identifier/COPY/StructLit returns but misses:
  #   - RETURN someCall() where someCall is heap-returning
  #   - RETURN obj.field where obj came from a heap-returning call
  #   - Transitive chains (wrapper -> makeList) especially for forward references
  # Fixed-point over @fn_nodes; no call graph needed (slightly less efficient but
  # avoids pulling annotator state into MIRPass).
  # Must run before apply_transitive_heap_promotion! which reads return_provenance.
  def recompute_fn_return_provenance!
    heap_fn = ->(fn) { fn.return_provenance == :heap }

    changed = true
    while changed
      changed = false
      @fn_nodes.each do |_, fn|
        next unless fn&.body
        next if heap_fn.call(fn)

        returns = []
        AST.walk_body(fn.body) { |n| returns << n if n.is_a?(AST::ReturnNode) }

        promoted = returns.any? do |ret|
          next false unless ret.value

          # Direct FuncCall or MethodCall return
          callee_name = case ret.value
                        when AST::FuncCall   then ret.value.name
                        when AST::MethodCall then ret.value.name
                        end
          if callee_name
            cfn = @fn_nodes[callee_name]
            next(cfn && heap_fn.call(cfn))
          end

          # GetField return: RETURN obj.field where obj came from a heap-returning call
          if ret.value.is_a?(AST::GetField)
            root = ret.value
            root = root.target while root.is_a?(AST::GetField) || root.is_a?(AST::GetIndex)
            if root.is_a?(AST::Identifier) && root.symbol
              decl = root.symbol.reg
              decl_val = decl.respond_to?(:value) ? decl.value : nil
              callee_name2 = case decl_val
                             when AST::FuncCall   then decl_val.name
                             when AST::MethodCall then decl_val.name
                             end
              cfn = callee_name2 && @fn_nodes[callee_name2]
              if cfn && heap_fn.call(cfn)
                ret_type = ret.value.respond_to?(:full_type) ? (Type.new(ret.value.full_type) rescue nil) : nil
                next(ret_type&.string? || ret_type&.collection? || ret_type&.map?)
              end
            end
          end

          # Identifier return: RETURN var where var is a frame collection needing escape
          if ret.value.is_a?(AST::Identifier)
            ti = ret.value.type_info
            ti = Type.new(ti) if ti && !ti.is_a?(Type)
            next(ti&.needs_escape_promotion? && !ti&.string? && !ti&.heap_provenance?)
          end

          false
        end

        if promoted
          fn.return_provenance = :heap
          changed = true
        end
      end
    end
  end

  # T4: Propagates return_provenance=:heap from callees to caller binding type_info.
  # Covers transitive promotion (e.g. wrapper() -> makeList()) before CleanupClassifier
  # runs. Runs at the start of transform! so classification sees the propagated provenance.
  def apply_transitive_heap_promotion!(nodes)
    current_fn = nil
    AST.walk_body(nodes) do |node|
      case node
      when AST::FunctionDef
        current_fn = node
      when AST::VarDecl, AST::BindExpr
        val = node.value
        callee = val.is_a?(AST::FuncCall) ? @fn_nodes[val.name] : nil
        if callee && (callee.return_provenance == :heap)
          node.type_info.provenance = :heap if node.type_info.is_a?(Type)
          if node.is_a?(AST::BindExpr) && node.mode == :assign
            decl = find_decl_in_fn(current_fn&.body, node.name)
            if decl&.respond_to?(:type_info) && decl.type_info.is_a?(Type)
              decl.type_info.provenance = :heap
            end
          end
        end
      when AST::Assignment
        val = node.value
        callee = val.is_a?(AST::FuncCall) ? @fn_nodes[val.name] : nil
        if callee && (callee.return_provenance == :heap)
          target = node.name
          sym = target.respond_to?(:symbol) ? target.symbol : nil
          decl = sym&.reg
          if decl&.respond_to?(:type_info) && decl.type_info.is_a?(Type)
            decl.type_info.provenance = :heap
          end
        end
      end
    end
  end

  def find_decl_in_fn(body, var_name)
    return nil unless body
    body.each do |node|
      case node
      when AST::VarDecl
        return node if node.name == var_name
      when AST::BindExpr
        return node if node.name == var_name && node.mode == :decl
      end
    end
    nil
  end

  # Stamp has_cleanup and cleanup_alloc on each VarDecl/BindExpr that needs cleanup.
  # These fields are no longer read by MIRLowering (which uses cleanup_bindings instead),
  # but are preserved for spec compatibility and external tooling.
  def stamp_decl_cleanup_fields!(body, bindings)
    AST.walk_body(body) do |node|
      name = case node
             when AST::VarDecl  then node.name.to_s
             when AST::BindExpr then node.mode == :decl ? node.name.to_s : nil
             else nil
             end
      next unless name
      entry = bindings[name]
      next unless entry && entry[:needs_cleanup] && !entry[:match_as]
      node.cleanup_alloc = entry[:alloc]
      node.has_cleanup = true
    end
  end

end
