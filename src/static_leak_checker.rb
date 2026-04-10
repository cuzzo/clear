# static_leak_checker.rb -- Pre-MIR ownership verification.
#
# Runs BEFORE MIRLowering on the AST+markers. Checks that require AST
# structure or schema lookup live here. Structural checks (LEAK, ORPHAN,
# ESCAPE, FRAME_ESCAPE, ALLOC_MISMATCH, BG_ESCAPE, etc.) have migrated
# to MIRChecker which runs on the post-lowering MIR tree.
#
# Checks performed:
#   FIELD_LEAK     -- field reassignment without pre-cleanup (old value leaks)
#   HPT_LEAK       -- heap-returning call not hoisted into VarDecl

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

    # Field ownership verification (requires schema lookup for type info).
    if @schema_lookup
      check_field_ownership!(@fn.body)
    end

    # Safety net: catch heap-returning calls that HPT hoisting missed.
    check_unhoisted_heap_calls!(@fn.body)

    @errors
  end

  private

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

  # Safety net: walk the post-MIR AST looking for FuncCall/MethodCall nodes
  # with heap_provenance that are NOT inside a VarDecl/BindExpr value (i.e.,
  # not hoisted by hoist_heap_temps!). Catches gaps if new AST positions are
  # added without corresponding HPT hoisting support.
  def check_unhoisted_heap_calls!(stmts, inside_bind_value: false)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::VarDecl, AST::BindExpr
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

end
