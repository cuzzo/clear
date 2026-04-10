# static_leak_checker.rb -- Pre-MIR ownership verification.
#
# Runs BEFORE MIRLowering on the AST+markers. Checks that require AST
# structure or schema lookup live here. Structural checks (LEAK, ORPHAN,
# ESCAPE, FRAME_ESCAPE, ALLOC_MISMATCH, CLASSIFIER_GAP, etc.) have
# migrated to MIRChecker which runs on the post-lowering MIR tree.
#
# Checks performed:
#   FIELD_LEAK     -- field reassignment without pre-cleanup (old value leaks)
#   BG_ESCAPE      -- BG block captures frame-allocated var without promotion
#   HPT_LEAK       -- heap-returning call not hoisted into VarDecl
#   ALLOC_MISMATCH -- error path changes allocator identity (INV-9)

class StaticLeakChecker
  attr_reader :errors

  def initialize(fn_node, bindings:, can_fail_fns: nil, schema_lookup: nil)
    @fn = fn_node
    @bindings = bindings || {}
    @schema_lookup = schema_lookup
    @errors = []
  end

  # Pre-MIR verification. Returns array of error strings.
  # Structural checks (LEAK, ORPHAN, ESCAPE, etc.) are in MIRChecker.
  def check!
    @errors = []

    # Collect MIR events from the post-MIR body.
    allocs = {}
    promotes = {}
    collect_mir_nodes(@fn.body, allocs, promotes)
    # Walk catch clause bodies for MIR nodes (e.g., MIR::Promote for catch_string_dupe).
    (@fn.catch_clauses || []).each do |clause|
      collect_mir_nodes(clause[:body], allocs, promotes) if clause[:body]
    end
    if @fn.default_catch.is_a?(Array)
      collect_mir_nodes(@fn.default_catch, allocs, promotes)
    end

    # Field ownership verification (requires schema lookup for type info).
    if @schema_lookup
      check_field_ownership!(@fn.body)
    end

    # BG capture promotion checks.
    check_bg_capture_promotes!(@fn.body, promotes)

    # Safety net: catch heap-returning calls that HPT hoisting missed.
    check_unhoisted_heap_calls!(@fn.body)

    # INV-9: error paths must not change allocator identity.
    check_error_path_consistency!(allocs)

    @errors
  end

  private

  def collect_mir_nodes(stmts, allocs, promotes)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::Alloc  then (allocs[stmt.name] ||= []) << stmt
      when MIR::Promote then (promotes[stmt.name || :"__container_promote_#{promotes.size}"] ||= []) << stmt
      when AST::IfStatement
        collect_mir_nodes(stmt.then_branch, allocs, promotes)
        collect_mir_nodes(stmt.else_branch, allocs, promotes)
      when AST::WhileLoop
        collect_mir_nodes(stmt.do_branch, allocs, promotes)
      when AST::ForRange, AST::ForEach
        collect_mir_nodes(stmt.body, allocs, promotes)
      when AST::MatchStatement
        stmt.cases&.each { |c| collect_mir_nodes(c[:body], allocs, promotes) }
        collect_mir_nodes(stmt.default_case, allocs, promotes)
      when AST::WithBlock
        collect_mir_nodes(stmt.body, allocs, promotes)
      when AST::DoBlock
        stmt.branches&.each { |b| collect_mir_nodes(b[:body], allocs, promotes) }
      when AST::BgBlock, AST::BgStreamBlock
        collect_mir_nodes(stmt.body, allocs, promotes)
      when MIR::IfStmt
        collect_mir_nodes(stmt.then_body, allocs, promotes)
        collect_mir_nodes(stmt.else_body, allocs, promotes)
      when MIR::WhileStmt, MIR::ForStmt
        collect_mir_nodes(stmt.body, allocs, promotes)
      when MIR::BlockExpr, MIR::ScopeBlock
        collect_mir_nodes(stmt.body, allocs, promotes)
      when MIR::DeferStmt, MIR::ErrDeferStmt
        collect_mir_nodes(Array(stmt.body), allocs, promotes)
      when MIR::SwitchStmt
        stmt.arms&.each { |a| collect_mir_nodes(a[:body], allocs, promotes) }
        collect_mir_nodes(stmt.default_body, allocs, promotes)
      end
    end
  end

  # Verify that every field assignment to an owned field has pre-cleanup.
  # Without pre-cleanup, the old field value leaks when overwritten.
  # Handles both direct (x.field = v) and nested (x.outer.inner = v) assignments.
  def check_field_ownership!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      if stmt.is_a?(AST::Assignment) && stmt.name.is_a?(AST::GetField)
        # Walk the GetField chain to find the root identifier.
        root = stmt.name.target
        field_path = [stmt.name.field]
        while root.is_a?(AST::GetField)
          field_path.unshift(root.field)
          root = root.target
        end

        if root.is_a?(AST::Identifier)
          field_ti = stmt.name.type_info rescue nil
          field_ti = Type.new(field_ti) if field_ti && !field_ti.is_a?(Type)

          target_entry = @bindings[root.name.to_s]
          needs_field_cleanup = false

          if field_ti&.needs_cleanup?(@schema_lookup)
            needs_field_cleanup = true
          elsif field_ti&.string? && target_entry && target_entry[:alloc] == :heap
            needs_field_cleanup = true
          end

          if needs_field_cleanup && !stmt.field_pre_cleanup
            line = stmt.token&.line || "?"
            @errors << "[FIELD_LEAK] #{@fn.name}::#{root.name}.#{field_path.join('.')} " \
                       "(line #{line}) -- field reassignment without pre-cleanup (old value leaks)"
          end
        end
      end

      # Recurse into control flow
      case stmt
      when AST::IfStatement
        check_field_ownership!(stmt.then_branch)
        check_field_ownership!(stmt.else_branch)
      when AST::WhileLoop
        check_field_ownership!(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        check_field_ownership!(stmt.body)
      when AST::MatchStatement
        stmt.cases&.each { |c| check_field_ownership!(c[:body]) }
        check_field_ownership!(stmt.default_case)
      when AST::WithBlock
        check_field_ownership!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| check_field_ownership!(b[:body]) }
      end
    end
  end

  def error(kind, name, msg)
    line = @fn.token&.line || "?"
    "[#{kind}] #{@fn.name}::#{name} (line #{line}) -- #{msg}"
  end

  # BG blocks that capture frame-allocated variables needing escape promotion
  # must have a corresponding MIR::Promote. Without promotion the fiber
  # outlives the parent frame -- use-after-free.
  def check_bg_capture_promotes!(stmts, promotes)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      # Walk into all expression positions where BG blocks can appear.
      each_bg_in_stmt(stmt) do |bg|
        captures = bg.capture_analysis&.captures
        captures&.each do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          next unless t && t.needs_escape_promotion? && !t.needs_pointer_passing?
          unless promotes.key?(name) || promotes.key?(name.to_s) || promotes.key?(name.to_sym)
            @errors << error(:FRAME_ESCAPE, name,
              "BG capture needs escape promotion but no MIR::Promote found (use-after-free)")
          end
        end
      end
      # Recurse into nested control flow.
      case stmt
      when AST::IfStatement
        check_bg_capture_promotes!(stmt.then_branch, promotes)
        check_bg_capture_promotes!(stmt.else_branch, promotes)
      when AST::WhileLoop then check_bg_capture_promotes!(stmt.do_branch, promotes)
      when AST::ForRange, AST::ForEach then check_bg_capture_promotes!(stmt.body, promotes)
      when AST::MatchStatement
        stmt.cases&.each { |c| check_bg_capture_promotes!(c[:body], promotes) }
        check_bg_capture_promotes!(stmt.default_case, promotes)
      when AST::WithBlock then check_bg_capture_promotes!(stmt.body, promotes)
      when AST::DoBlock
        stmt.branches&.each { |b| check_bg_capture_promotes!(b[:body], promotes) }
      # MIR control-flow nodes
      when MIR::IfStmt
        check_bg_capture_promotes!(stmt.then_body, promotes)
        check_bg_capture_promotes!(stmt.else_body, promotes)
      when MIR::ForStmt, MIR::WhileStmt then check_bg_capture_promotes!(stmt.body, promotes)
      when MIR::BlockExpr, MIR::ScopeBlock then check_bg_capture_promotes!(stmt.body, promotes)
      when MIR::SwitchStmt
        stmt.arms&.each { |a| check_bg_capture_promotes!(a[:body], promotes) }
        check_bg_capture_promotes!(stmt.default_body, promotes)
      end
    end
  end

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values, MethodCall args, FuncCall args.
  def each_bg_in_stmt(stmt, &block)
    case stmt
    when AST::BgBlock, AST::BgStreamBlock
      yield stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      _walk_expr_for_bg(stmt.respond_to?(:value) ? stmt.value : nil, &block)
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

  # Safety net: walk the post-MIR AST looking for FuncCall/MethodCall nodes
  # with heap_provenance that are NOT inside a VarDecl/BindExpr value (i.e.,
  # not hoisted by hoist_heap_temps!). Catches gaps if new AST positions are
  # added without corresponding HPT hoisting support.
  def check_unhoisted_heap_calls!(stmts, inside_bind_value: false)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::VarDecl, AST::BindExpr
        # The value of a VarDecl/BindExpr is a "bind position" -- HPT calls
        # here are either the bind target itself or already hoisted.
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.value
      when AST::ReturnNode
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.value
      when AST::Assignment
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.value
      when AST::FuncCall, AST::MethodCall
        scan_expr_for_unhoisted_heap!(stmt, inside_bind_value: false)
      when AST::IfStatement
        scan_expr_for_unhoisted_heap!(stmt.condition, inside_bind_value: false) if stmt.condition
        check_unhoisted_heap_calls!(stmt.then_branch)
        check_unhoisted_heap_calls!(stmt.else_branch)
      when AST::WhileLoop
        # WHILE conditions are rejected by check_no_heap_call_in_while_condition! in MIRPass.
        check_unhoisted_heap_calls!(stmt.do_branch)
      when AST::ForRange
        check_unhoisted_heap_calls!(stmt.body)
      when AST::ForEach
        scan_expr_for_unhoisted_heap!(stmt.collection, inside_bind_value: false) if stmt.collection
        check_unhoisted_heap_calls!(stmt.body)
      when AST::MatchStatement
        scan_expr_for_unhoisted_heap!(stmt.expr, inside_bind_value: false) if stmt.expr
        stmt.cases&.each do |c|
          scan_expr_for_unhoisted_heap!(c[:value], inside_bind_value: false) if c[:value]
          check_unhoisted_heap_calls!(c[:body])
        end
        check_unhoisted_heap_calls!(stmt.default_case)
      when AST::Assert
        scan_expr_for_unhoisted_heap!(stmt.condition, inside_bind_value: false) if stmt.condition
        scan_expr_for_unhoisted_heap!(stmt.message, inside_bind_value: false) if stmt.message
      when AST::WithBlock
        check_unhoisted_heap_calls!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| check_unhoisted_heap_calls!(b[:body]) }
      when AST::BgBlock, AST::BgStreamBlock
        check_unhoisted_heap_calls!(stmt.body)
      # MIR control-flow nodes
      when MIR::IfStmt
        check_unhoisted_heap_calls!(stmt.then_body)
        check_unhoisted_heap_calls!(stmt.else_body)
      when MIR::ForStmt, MIR::WhileStmt
        check_unhoisted_heap_calls!(stmt.body)
      when MIR::BlockExpr, MIR::ScopeBlock
        check_unhoisted_heap_calls!(stmt.body)
      when MIR::SwitchStmt
        stmt.arms&.each { |a| check_unhoisted_heap_calls!(a[:body]) }
        check_unhoisted_heap_calls!(stmt.default_body)
      when MIR::Let
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.respond_to?(:value)
      when MIR::ExprStmt
        scan_expr_for_unhoisted_heap!(stmt.expr, inside_bind_value: false) if stmt.respond_to?(:expr)
      end
    end
  end

  # Walk an expression tree looking for unhoisted heap-returning calls.
  def scan_expr_for_unhoisted_heap!(node, inside_bind_value: false)
    return unless node
    case node
    when AST::FuncCall, AST::MethodCall
      ti = node.type_info rescue nil
      ti = ti.is_a?(Type) ? ti : nil
      if ti&.heap_provenance? && !inside_bind_value && !node.was_moved
        line = node.token&.line || "?"
        call_name = node.is_a?(AST::MethodCall) ? node.method_name : node.name
        @errors << "[UNHOISTED_HEAP_CALL] #{@fn.name} (line #{line}) -- " \
                   "heap-returning call '#{call_name}' not hoisted to a VarDecl (leak)"
      end
      # Recurse into args.
      node.args.each { |a| scan_expr_for_unhoisted_heap!(a, inside_bind_value: false) }
      if node.is_a?(AST::MethodCall)
        scan_expr_for_unhoisted_heap!(node.object, inside_bind_value: false)
      end
    when AST::BinaryOp
      scan_expr_for_unhoisted_heap!(node.left, inside_bind_value: inside_bind_value)
      scan_expr_for_unhoisted_heap!(node.right, inside_bind_value: inside_bind_value)
    when AST::GetField
      scan_expr_for_unhoisted_heap!(node.target, inside_bind_value: false)
    when AST::GetIndex
      scan_expr_for_unhoisted_heap!(node.target, inside_bind_value: false)
      scan_expr_for_unhoisted_heap!(node.index, inside_bind_value: false)
    when AST::MoveNode
      scan_expr_for_unhoisted_heap!(node.value, inside_bind_value: inside_bind_value)
    when AST::StructLit, AST::UnionVariantLit
      node.fields&.each_value { |v| scan_expr_for_unhoisted_heap!(v, inside_bind_value: inside_bind_value) }
    when AST::ListLit
      node.items&.each { |v| scan_expr_for_unhoisted_heap!(v, inside_bind_value: inside_bind_value) }
    end
  end

  # INV-9: Error paths must not change the allocator identity of live bindings.
  # If a binding has MIR::Alloc with allocator A, and a catch/default clause
  # reassigns it with a value from allocator B != A, the cleanup path uses the
  # wrong allocator -- either leak or UAF.
  def check_error_path_consistency!(allocs)
    catch_bodies = []
    (@fn.catch_clauses || []).each { |c| catch_bodies << c[:body] if c[:body] }
    catch_bodies << @fn.default_catch if @fn.default_catch.is_a?(Array)
    return if catch_bodies.empty?

    catch_bodies.each do |body|
      collect_error_path_reassigns(body) do |name, new_alloc, line|
        alloc_nodes = allocs[name]
        next unless alloc_nodes
        alloc_nodes.each do |alloc_node|
          if alloc_node.alloc != new_alloc
            @errors << "[ALLOC_MISMATCH] #{@fn.name}::#{name} (line #{line}) -- " \
              "catch reassigns with :#{new_alloc} but original alloc is :#{alloc_node.alloc} (INV-9)"
          end
        end
      end
    end
  end

  # Walk a catch clause body yielding (name, new_alloc, line) for each
  # reassignment to an existing binding.
  def collect_error_path_reassigns(stmts, &block)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::BindExpr
        if stmt.mode == :assign
          new_alloc = infer_value_allocator(stmt.value)
          yield stmt.name.to_s, new_alloc, (stmt.token&.line || "?") if new_alloc
        end
      when AST::Assignment
        if stmt.name.is_a?(AST::Identifier)
          new_alloc = infer_value_allocator(stmt.value)
          yield stmt.name.name.to_s, new_alloc, (stmt.token&.line || "?") if new_alloc
        end
      when AST::IfStatement
        collect_error_path_reassigns(stmt.then_branch, &block)
        collect_error_path_reassigns(stmt.else_branch, &block)
      when AST::MatchStatement
        stmt.cases&.each { |c| collect_error_path_reassigns(c[:body], &block) }
        collect_error_path_reassigns(stmt.default_case, &block)
      end
    end
  end

  # Infer the allocator a value expression would use.
  # Returns :heap, :frame, or nil (unknown).
  def infer_value_allocator(expr)
    return nil unless expr
    ti = expr.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    return :heap if ti&.heap_provenance?
    storage = expr.respond_to?(:storage) ? expr.storage : nil
    return storage if storage == :heap || storage == :frame
    nil
  end

end
