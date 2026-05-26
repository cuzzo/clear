# typed: true
# Hoist -- lift anonymous allocating expressions into temp bindings.
#
# Runs after annotation, before escape analysis. An allocating expression
# that is not already the value of a declaration has no SymbolEntry --
# so escape analysis cannot record a definitive decision for it on
# symbol.storage, and would be forced into a renegade node.storage
# write. This pass rewrites such an expression into
#   __hoist_N = <expr>
# a real declaration with a SymbolEntry attached, so every allocating
# thing escape analysis sees is a symbol-bearing binding.
#
# Scope: anonymous allocating expressions in escape positions (return, yield,
# enclosing/container stores) are lifted to real declarations. Escape analysis
# then marks only bindings; it never promotes expression nodes.
require "sorbet-runtime"
require "set"
require_relative "mir"
require_relative "cleanup_entry"
require_relative "pass_state"
require_relative "../ast/ast"
require_relative "../ast/type"

module Hoist
  extend T::Sig
  module_function

  ELEMENT_STORE = T.let(%w[append insert push put].freeze, T::Array[String])

  sig { params(ast: T.untyped, schema_lookup: T.nilable(Proc)).void }
  def apply!(ast, schema_lookup: nil)
    MIRPassState.require!(ast, :string_concat_rewritten, consumer: "Hoist")
    ctr = T.let([0], T::Array[Integer])
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      next if synthesized_body?(stmt)
      hoist_body!(stmt.body, ctr, schema_lookup, return_type: stmt.return_type)
    end
    MIRPassState.for!(ast).mark!(:hoisted)
  end

  # THUNK bodies are not lowered as normal statement lists. They are consumed
  # by ThunkTransform from the recurrence plan and emitted as a synthesized
  # frame machine, so normal-body hoists would create bindings that the
  # synthesized body cannot see.
  sig { params(fn: T.untyped).returns(T::Boolean) }
  def synthesized_body?(fn)
    (fn.respond_to?(:thunk_plan) && fn.thunk_plan) ||
      (fn.respond_to?(:mutual_thunk_plan) && fn.mutual_thunk_plan)
  end

  # Walk a statement list. For each statement, lift the hoistable
  # sub-expressions into temp decls inserted immediately before it.
  sig { params(body: T.untyped, ctr: T::Array[Integer], schema_lookup: T.nilable(Proc), return_type: T.untyped).void }
  def hoist_body!(body, ctr, schema_lookup, return_type: nil)
    return unless body.is_a?(Array)
    i = 0
    while i < body.length
      stmt = body[i]
      hoists = T.let([], T::Array[T.untyped])
      collect_stmt_hoists!(stmt, hoists, ctr, schema_lookup, return_type: return_type)
      hoists.each_with_index { |decl, j| body.insert(i + j, decl) }
      i += hoists.length
      # Recurse into nested statement bodies (control flow). Nested
      # functions / lambdas / BG blocks are separate frames -- each is
      # reached as its own AST::FunctionDef or handled separately.
      child_bodies(stmt).each { |b| hoist_body!(b, ctr, schema_lookup, return_type: return_type) }
      i += 1
    end
  end

  sig { params(stmt: T.untyped).returns(T::Array[T.untyped]) }
  def child_bodies(stmt)
    case stmt
    when AST::ForRange, AST::ForEach           then [stmt.body]
    when AST::WhileLoop, AST::WhileBindLoop    then [stmt.do_branch]
    when AST::IfStatement                     then [stmt.then_branch, stmt.else_branch].compact
    when AST::MatchStatement                  then stmt.cases.map(&:body) + [stmt.default_case].compact
    when AST::WithBlock                       then [stmt.body]
    when AST::DoBlock                         then stmt.branches.map { |b| b[:body] }.compact
    when AST::BgBlock, AST::BgStreamBlock      then [stmt.body]
    else []
    end
  end

  # Find element-store method calls in this statement's expression tree.
  # Composite element stores are escaping positions; hoist allocating
  # argument fragments so the escape pass sees bindings.
  sig { params(stmt: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer], schema_lookup: T.nilable(Proc), return_type: T.untyped).void }
  def collect_stmt_hoists!(stmt, hoists, ctr, schema_lookup, return_type: nil)
    each_call(stmt) do |call|
      next if call.is_a?(AST::MethodCall) && ELEMENT_STORE.include?(call.name.to_s)
      call.args.each_with_index do |arg, idx|
        next unless allocating?(arg, schema_lookup)
        call.args[idx] = make_temp!(arg, hoists, ctr, moved: moved_arg?(arg), schema_lookup: schema_lookup)
      end
    end

    each_method_call(stmt) do |call|
      next unless ELEMENT_STORE.include?(call.name.to_s)
      next unless composite_element_store?(call)
      call.args.each_with_index do |arg, idx|
        if concat?(arg)
          call.args[idx] = make_temp!(arg, hoists, ctr)
        else
          hoist_concats_within!(arg, hoists, ctr)
        end
      end
    end
    # RETURN / YIELD / field-store values escape their current frame. If the
    # escaping value is anonymous and allocating, give it a binding first.
    case stmt
    when AST::ReturnNode
      expected = Type.from_node(return_type)
      expected = expected.success_type if expected
      stmt.value = hoist_escape_value!(stmt.value, hoists, ctr, schema_lookup, expected_type: expected) if stmt.value
    when AST::YieldExpr
      stmt.expr = hoist_escape_value!(stmt.expr, hoists, ctr, schema_lookup) if stmt.expr
    when AST::Assignment
      if stmt.name.is_a?(AST::GetField)
        stmt.value = hoist_escape_value!(stmt.value, hoists, ctr, schema_lookup) if stmt.value
      end
    end
  end

  sig { params(value: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer], schema_lookup: T.nilable(Proc), expected_type: T.untyped).returns(T.untyped) }
  def hoist_escape_value!(value, hoists, ctr, schema_lookup, expected_type: nil)
    return make_temp!(value, hoists, ctr, expected_type: expected_type) if allocating?(value, schema_lookup)
    if value.is_a?(AST::StructLit) || value.is_a?(AST::UnionVariantLit) || value.is_a?(AST::ListLit)
      hoist_concats_within!(value, hoists, ctr)
    end
    value
  end

  # An anonymous expression that allocates a fresh heap-able value and so
  # needs its own binding for escape analysis to place it.
  sig { params(node: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def allocating?(node, schema_lookup)
    return false unless node
    return false if node.is_a?(AST::Identifier) || node.is_a?(AST::Literal)
    return true if concat?(node) || node.is_a?(AST::ListLit) || node.is_a?(AST::HashLit)

    return false unless node.is_a?(AST::Locatable)
    ti = node.full_type!(context: "hoist allocation candidate")
    ti.heap_ptr? || ti.needs_explicit_cleanup?(:heap, schema_lookup)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def moved_arg?(node)
    AST.moved?(node)
  end

  # Yield every MethodCall reachable inside one statement's OWN
  # expressions. Must NOT descend into nested statement bodies (loop /
  # branch bodies) -- those are separate statements hoisted by
  # hoist_body!'s own recursion; hoisting a call found there would
  # insert the temp into the wrong scope.
  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_method_call(node, &blk)
    return if node.nil? || node.is_a?(Array)
    return unless node.is_a?(Struct)
    # Separate frames -- their bodies are walked independently.
    return if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit) ||
              node.is_a?(AST::BgBlock) || node.is_a?(AST::WithBlock) ||
              node.is_a?(AST::DoBlock)
    blk.call(node) if node.is_a?(AST::MethodCall)
    # A body-bearing control-flow node: walk only its condition/subject
    # expressions, never its statement bodies.
    children = non_body_exprs(node) || node.to_a
    children.each do |child|
      case child
      when Array then child.each { |c| each_method_call(c, &blk) }
      when Hash  then child.each_value { |v| each_method_call(v, &blk) }
      else each_method_call(child, &blk)
      end
    end
  end

  # Yield every call reachable inside one statement's own expressions. This
  # is the call-argument hoist path: anonymous allocating call arguments become
  # named bindings before escape/cleanup placement runs.
  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_call(node, &blk)
    return if node.nil? || node.is_a?(Array)
    return unless node.is_a?(Struct)
    return if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit) ||
              node.is_a?(AST::BgBlock) || node.is_a?(AST::WithBlock) ||
              node.is_a?(AST::DoBlock)
    blk.call(node) if node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)
    children = non_body_exprs(node) || node.to_a
    children.each do |child|
      case child
      when Array then child.each { |c| each_call(c, &blk) }
      when Hash  then child.each_value { |v| each_call(v, &blk) }
      else each_call(child, &blk)
      end
    end
  end

  # For a body-bearing control-flow node, the expression members that
  # are NOT statement bodies. nil for a plain node (recurse normally).
  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def non_body_exprs(node)
    case node
    when AST::IfStatement                  then [node.condition]
    when AST::ForRange                     then [node.start_expr, node.end_expr]
    when AST::ForEach                      then [node.collection]
    when AST::WhileLoop, AST::WhileBindLoop then [node.condition]
    when AST::MatchStatement               then [node.expr]
    end
  end

  # Replace every string concat directly held by `node` (struct/union
  # field value, list element) with a hoisted temp; recurse otherwise.
  sig { params(node: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).void }
  def hoist_concats_within!(node, hoists, ctr)
    case node
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_key do |k|
        v = node.fields[k]
        if concat?(v)
          node.fields[k] = make_temp!(v, hoists, ctr)
        else
          hoist_concats_within!(v, hoists, ctr)
        end
      end
    when AST::ListLit
      node.items.each_index do |idx|
        v = node.items[idx]
        if concat?(v)
          node.items[idx] = make_temp!(v, hoists, ctr)
        else
          hoist_concats_within!(v, hoists, ctr)
        end
      end
    end
  end

  # Composite element stores can own nested heap-bearing fields, so
  # anonymous allocating fragments inside their arguments need bindings.
  sig { params(call: T.untyped).returns(T::Boolean) }
  def composite_element_store?(call)
    obj = call.object
    sym = (obj.is_a?(AST::Identifier) || obj.is_a?(AST::GetField)) ? obj.symbol : nil
    ti = sym&.type
    return false unless ti.is_a?(Type) && ti.collection?
    et = ti.element_type
    !!(et.is_a?(Type) && !et.primitive? && !et.string?)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def concat?(node)
    node.is_a?(AST::StringConcat) ||
      (node.is_a?(AST::BinaryOp) && node.op == :ADD && !!node.string_concat)
  end

  # Build `__hoist_N = <concat>` with a real SymbolEntry, append the decl
  # to `hoists`, and return the Identifier that replaces the concat.
  sig { params(concat: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer], moved: T::Boolean, expected_type: T.untyped, schema_lookup: T.nilable(Proc)).returns(T.untyped) }
  def make_temp!(concat, hoists, ctr, moved: true, expected_type: nil, schema_lookup: nil)
    n = T.must(ctr[0]) + 1
    ctr[0] = n
    name = "__hoist_#{n}"
    tok = concat.respond_to?(:token) ? concat.token : nil
    expected = Type.from_node(expected_type)
    ti = if concat.is_a?(AST::BgStreamBlock) && expected&.stream?
      expected
    else
      Type.from_node!(concat, context: "AST hoist temp")
    end
    storage = if owned_fallback_temp?(concat, schema_lookup)
      :heap
    elsif ast_borrow_expr?(concat, moved) || (concat.respond_to?(:container_borrow) && concat.container_borrow)
      :borrow
    else
      (concat.respond_to?(:storage) && concat.storage) || :frame
    end

    decl = AST::VarDecl.new(tok, name, nil, concat, false)
    AST.stamp_synthetic_type!(decl, ti, context: "synthetic AST type")
    # The temp is always consumed by the statement it was lifted from
    # (return / yield / element store), so it is used by construction --
    # var-use analysis ran before this pass and cannot know that.
    decl.var_used = true
    # decl.storage (a node field) is left as annotation's default; escape
    # analysis records the definitive placement on sym.storage below.
    sym = SymbolEntry.new(reg: decl, type: ti, mutable: false, storage: storage)
    decl.symbol = sym
    decl.container_borrow = true if sym.borrow_provenance? && decl.respond_to?(:container_borrow=)
    hoists << decl

    ident = AST::Identifier.new(tok, name)
    AST.stamp_synthetic_type!(ident, ti, context: "synthetic AST type")
    ident.symbol = sym
    # The temp replaces a sub-expression in an ownership-consuming
    # position (element-store arg / struct field of one). Stamp the
    # move so ownership dataflow transfers the temp into the container
    # instead of cleaning it up at scope exit.
    ident.was_moved = moved if ident.respond_to?(:was_moved=)
    # An @indirect field value carries needs_heap_create; the stamp must
    # follow the value to its new position.
    if concat.respond_to?(:needs_heap_create) && concat.needs_heap_create
      ident.needs_heap_create = true
    end
    ident
  end

  sig { params(ast_node: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def owned_fallback_temp?(ast_node, schema_lookup)
    return false unless ast_node.is_a?(AST::BinaryOp) && (ast_node.op == :OR || ast_node.op == :OR_RESCUE)
    return false unless ast_container_borrow_expr?(ast_node.left)

    ti = Type.from_node!(ast_node, context: "owned fallback temp")

    ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(schema_lookup)
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def ast_container_borrow_expr?(ast_node)
    return false unless ast_node
    if ast_node.is_a?(AST::GetIndex)
      ti = Type.from_node!(ast_node.target, context: "container borrow expression")
      return ti.indexed_container_borrow?
    end
    if ast_node.is_a?(AST::BinaryOp) && (ast_node.op == :OR || ast_node.op == :OR_RESCUE)
      return ast_container_borrow_expr?(ast_node.left)
    end
    false
  rescue StandardError
    false
  end

  sig { params(ast_node: T.untyped, moved: T::Boolean).returns(T::Boolean) }
  def ast_borrow_expr?(ast_node, moved)
    return false if moved
    return true if ast_access_path?(ast_node)
    ast_container_borrow_expr?(ast_node)
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def ast_access_path?(ast_node)
    node = ast_node
    if node.is_a?(AST::BinaryOp) && (node.op == :OR || node.op == :OR_RESCUE)
      node = node.left
    end
    node.is_a?(AST::GetField) || node.is_a?(AST::GetIndex)
  end
end

# Lowering-side hoist helpers.
#
# The AST Hoist pass above runs before escape analysis so every escaping
# anonymous value has a SymbolEntry. This module handles the remaining MIR
# mechanical hoists during lowering: making allocator-producing MIR expressions
# into named Let bindings with matching cleanup markers. It does not decide
# escape; it reads the placement facts already stamped on symbols/nodes.
module MIRHoistLowering
  extend T::Sig
  include Kernel

  # Nodes whose ownership must be verifier-visible when nested, regardless of
  # whether placement selected heap or frame.
  ALLOC_MIR_CLASSES = [
    MIR::DupeSlice, MIR::AllocSlice, MIR::MakeList, MIR::CapWrap,
    MIR::SharePromote, MIR::DeepCopy, MIR::ConcatStr, MIR::ContainerInit,
  ].freeze

  sig { returns(T::Array[T.untyped]) }
  def flush_pending
    stmts = @pending_stmts
    @pending_stmts = []
    stmts
  end

  sig { params(blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def lower_scoped(&blk)
    prev = @pending_stmts
    @pending_stmts = []
    result = blk.call
    scoped = @pending_stmts
    @pending_stmts = prev
    return result if scoped.empty?
    @block_expr_counter += 1
    label = "__lazy_#{@block_expr_counter}"
    alloc_names = scoped.each_with_object(Set.new) do |stmt, names|
      names << stmt.name.to_s if stmt.is_a?(MIR::AllocMark)
    end
    result_names = result.is_a?(MIR::Ident) ? Set[result.name.to_s] : Set.new
    transfer_marks = alloc_names.intersection(result_names).flat_map do |name|
      marks = T.let([MIR::TransferMark.new(name, :block_result)], T::Array[T.untyped])
      marks << MIR::MoveMark.new(name) if @guarded_cleanup_names&.[](name)
      marks
    end
    MIR::BlockExpr.new(label, scoped + transfer_marks + [MIR::BreakStmt.new(label, result)])
  end

  sig { params(blk: T.proc.returns(T.untyped)).returns([T.untyped, T::Array[T.untyped]]) }
  def lower_head(&blk)
    prev = @pending_stmts
    @pending_stmts = []
    result = blk.call
    produced = @pending_stmts
    @pending_stmts = prev
    [result, produced]
  end

  sig { params(pending: T::Array[T.untyped], node: T.untyped).returns(T.untyped) }
  def with_pending(pending, node)
    pending.empty? ? node : MIR::ScopeBlock.new(pending + [node])
  end

  sig { params(parent: AST::BinaryOp, field: Symbol).returns(T.untyped) }
  def descend(parent, field)
    child = parent.send(field)
    if parent.respond_to?(:lazy_fields) && parent.lazy_fields.include?(field)
      lower_scoped do
        result = T.unsafe(self).lower(child)
        hoist_lazy_alloc_result(result, child)
      end
    else
      T.unsafe(self).lower(child)
    end
  end

  sig { params(expr: T.untyped, ast_node: T.untyped).returns(T.untyped) }
  def hoist_lazy_alloc_result(expr, ast_node)
    return expr unless mir_allocates?(expr)
    @tmp_counter += 1
    name = "__tmp_#{@tmp_counter}"
    ti = T.unsafe(self).alloc_mark_type_info(expr, ast_node, "lazy allocating expression")
    alloc = mir_owned_alloc(expr) || :heap
    mark = MIR::AllocMark.new(name, alloc, ti)
    mark.scope = alloc == :heap ? :heap : :iteration
    @pending_stmts << mark
    @lowered_alloc_names&.add(name)
    @lowered_alloc_names&.add(name)
    stamp_allocating_result_target!(expr, name, alloc: alloc)
    @pending_stmts << MIR::Let.new(name, expr, false, nil, nil)
    MIR::Ident.new(name)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def mir_allocates?(node)
    return false unless node
    effect = node.respond_to?(:ownership_effect) ? node.ownership_effect : MIR::OwnershipEffect.none
    return true if effect.produces_owned
    return true if node.is_a?(MIR::BgBlock)

    mir_result_child_exprs(node).any? do |child|
      mir_allocates?(child)
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def mutating_receiver_allocator_op?(node)
    return false unless node.is_a?(MIR::InlineZig)

    node.mutating_receiver_allocator_op? == true
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_mir_expr_child(node, &blk)
    return unless node.respond_to?(:mir?) && node.mir?
    return unless node.class.respond_to?(:members)

    node.class.members.each do |member|
      value = node[member]
      each_mir_expr_in_value(value, &blk)
    end
    nil
  end

  sig { params(value: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_mir_expr_in_value(value, &blk)
    if mir_expr_child?(value)
      yield value
    elsif value.is_a?(Array)
      value.each { |child| each_mir_expr_in_value(child, &blk) }
    elsif value.is_a?(Hash)
      value.each_value { |child| each_mir_expr_in_value(child, &blk) }
    end
    nil
  end

  sig { params(value: T.untyped).returns(T::Boolean) }
  def mir_expr_child?(value)
    value.respond_to?(:expr?) && value.expr?
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def ownership_borrow_boundary?(node)
    node.is_a?(MIR::Call) ||
      node.is_a?(MIR::TailCall) ||
      node.is_a?(MIR::MethodCall) ||
      node.is_a?(MIR::FieldGet) ||
      node.is_a?(MIR::IndexGet) ||
      node.is_a?(MIR::BinOp) ||
      node.is_a?(MIR::UnaryOp) ||
      node.is_a?(MIR::AddressOf) ||
      node.is_a?(MIR::Deref) ||
      node.is_a?(MIR::SliceExpr) ||
      node.is_a?(MIR::IfOptional) ||
      node.is_a?(MIR::TryCatch) ||
      node.is_a?(MIR::TryExpr) ||
      node.is_a?(MIR::Orelse) ||
      node.is_a?(MIR::Conditional) ||
      node.is_a?(MIR::ListItems) ||
      node.is_a?(MIR::ListLength) ||
      node.is_a?(MIR::HasField) ||
      node.is_a?(MIR::OwnedSlice) ||
      node.is_a?(MIR::ConcatStr) ||
      node.is_a?(MIR::RangeLit) ||
      node.is_a?(MIR::DeepCopy) ||
      node.is_a?(MIR::RcRetain) ||
      node.is_a?(MIR::RcDowngrade) ||
      node.is_a?(MIR::WeakUpgrade) ||
      node.is_a?(MIR::LambdaExpr) ||
      node.is_a?(MIR::Pipeline) ||
      node.is_a?(MIR::InlineZig) ||
      node.is_a?(MIR::RawZig) ||
      node.is_a?(MIR::InlineBc) ||
      node.is_a?(MIR::RawBc) ||
      node.is_a?(MIR::ShardedMapGet) ||
      node.is_a?(MIR::ShardedMapPut)
  end

  sig { params(node: T.untyped, ft: T.untyped, binding_entry: CleanupEntry, init: T.untyped, decl_alloc: Symbol).returns(Symbol) }
  def pick_node_alloc(node, ft, binding_entry, init, decl_alloc)
    return :heap if mir_allocates?(init)
    Kernel.raise "Hoist cannot choose heap/frame from node storage; placement must be on the binding symbol"
  end

  sig do
    params(
      expr: T.untyped,
      ast_node: T.untyped,
      err_cleanup: T.nilable(T::Boolean),
      mutable: T::Boolean,
      transfer_on_success: T::Boolean
    ).returns(T.untyped)
  end
  def hoist_alloc(expr, ast_node = nil, err_cleanup: false, mutable: false, transfer_on_success: true)
    return expr unless mir_allocates?(expr) ||
                       (expr.is_a?(MIR::Call) && expr.owned_return?) ||
                       T.unsafe(self).send(:call_union_return_needs_hoist?, expr, ast_node)
    @tmp_counter += 1
    name = "__tmp_#{@tmp_counter}"
    ti = T.unsafe(self).alloc_mark_type_info(expr, ast_node, "MIR allocating hoist")
    alloc = mir_owned_alloc(expr) || :heap
    mark = MIR::AllocMark.new(name, alloc, ti)
    mark.scope = alloc == :heap ? :heap : :iteration
    @pending_stmts << mark
    @lowered_alloc_names&.add(name)
    stamp_allocating_result_target!(expr, name, alloc: alloc)
    @pending_stmts << MIR::Let.new(name, expr, mutable, nil, nil)
    entry = hoist_cleanup_entry(expr, ast_node)
    if entry
      effective_err_cleanup = err_cleanup && !expr.is_a?(MIR::RcRetain) &&
        !expr.is_a?(MIR::RcDowngrade) && !expr.is_a?(MIR::WeakUpgrade)
      entry[:has_moved_guard] = true if effective_err_cleanup
      cleanup = effective_err_cleanup ? MIR::ErrCleanup.new(name, entry) : MIR::Cleanup.new(name, entry)
      @pending_stmts << cleanup
      (@guarded_cleanup_names ||= {})[name] = true if entry.has_moved_guard?
      @lowered_guarded_cleanup_names&.add(name) if entry.has_moved_guard?
    end
    MIR::Ident.new(name)
  end

  sig { params(mir: T.untyped, ast_node: T.untyped, context: String).returns(Type) }
  def mir_alloc_mark_type_info(mir, ast_node = nil, context: "MIR allocation")
    return T.unsafe(self).alloc_mark_type_info(mir, ast_node, context) if ast_node

    alloc = mir_owned_alloc(mir) || :heap
    case mir
    when MIR::DupeSlice, MIR::ConcatStr
      Type.new(:String, location: alloc)
    when MIR::AllocSlice
      Type.new("#{mir.elem_type}[]", location: alloc)
    when MIR::OwnedSlice
      Type.new(:Slice, location: alloc)
    when MIR::MakeList
      Type.new("#{mir.elem_type}[]", collection: :list, location: alloc)
    when MIR::HeapCreate
      Type.new(mir.zig_type.to_s.delete_prefix("*").to_sym, layout: :indirect)
    when MIR::ContainerInit
      Type.new(mir.zig_type.to_s, location: alloc)
    when MIR::DeepCopy
      Type.new(deep_copy_zig_type(mir, nil), location: alloc)
    when MIR::CapWrap
      wrapped = mir.sync_type || mir.zig_base
      Type.new(wrapped.to_s, layout: mir.sync_fn || mir.own_fn ? :indirect : nil, location: alloc)
    when MIR::SharePromote, MIR::WeakUpgrade
      Type.new(mir.zig_base.to_s, ownership: :shared, location: :heap)
    when MIR::RcRetain, MIR::RcDowngrade, MIR::FreezeExpr
      Type.new(mir.zig_base.to_s, ownership: :multiowned, location: :heap)
    when MIR::Cast, MIR::TryExpr
      mir_alloc_mark_type_info(mir.expr, nil, context: context)
    when MIR::Call, MIR::MethodCall, MIR::TailCall
      if mir.respond_to?(:result_type) && T.unsafe(mir).result_type
        return Type.new(T.must(T.unsafe(mir).result_type))
      end

      sig = mir.respond_to?(:callable_contract) ? mir.callable_contract&.signature : nil
      raise "#{context}: allocating #{mir.class} has no callable return type" unless sig

      Type.new(sig.return_type)
    when MIR::InlineZig
      sig = FunctionSignature.unwrap(mir.stdlib_def)
      raise "#{context}: allocating MIR::InlineZig has no typed stdlib return" unless sig

      Type.new(sig.return_type)
    when MIR::BgBlock
      raise "#{context}: allocating MIR::BgBlock has no result type" unless mir.result_type

      Type.new(T.must(mir.result_type))
    when MIR::TryCatch
      raise "#{context}: allocating MIR::TryCatch has no result type" unless mir.result_type

      Type.new(T.must(mir.result_type))
    when MIR::Orelse, MIR::IfOptional, MIR::BlockExpr
      raise "#{context}: allocating #{mir.class} has no typed allocation result"
    else
      raise "#{context}: unhandled allocating MIR node #{mir.class}"
    end
  end

  sig { params(expr: T.untyped, transfer_on_success: T::Boolean).returns([T::Array[T.untyped], MIR::Ident]) }
  def hoist_normalized_alloc_expr(expr, transfer_on_success: false)
    @tmp_counter += 1
    name = "__tmp_#{@tmp_counter}"
    alloc = mir_owned_alloc(expr) || :heap
    mark = MIR::AllocMark.new(name, alloc, mir_alloc_mark_type_info(expr, nil, context: "normalized MIR allocation"))
    mark.scope = alloc == :heap ? :heap : :iteration
    stamp_allocating_result_target!(expr, name, alloc: alloc)
    entry = hoist_cleanup_entry(expr, nil)
    stmts = T.let([mark, MIR::Let.new(name, expr, false, nil, nil)], T::Array[T.untyped])
    if entry
      effective_transfer = transfer_on_success && !expr.is_a?(MIR::RcRetain) &&
        !expr.is_a?(MIR::RcDowngrade) && !expr.is_a?(MIR::WeakUpgrade)
      if effective_transfer
        entry[:has_moved_guard] = true
        stmts << MIR::ErrCleanup.new(name, entry)
        (@guarded_cleanup_names ||= {})[name] = true
        @lowered_guarded_cleanup_names&.add(name)
      else
        entry[:has_moved_guard] = false
        stmts << MIR::Cleanup.new(name, entry)
      end
    end
    @lowered_alloc_names&.add(name)
    [stmts, MIR::Ident.new(name)]
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def consumes_owned_children?(node)
    node.respond_to?(:ownership_consumption) &&
      node.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def normalize_allocating_mir_body(body)
    out = T.let([], T::Array[T.untyped])
    body.each do |stmt|
      normalize_nested_mir_bodies!(stmt)
      prefix = normalize_allocating_mir_stmt!(stmt)
      out.concat(prefix)
      out << stmt
    end
    out
  end

  sig { params(stmt: T.untyped).returns(T::Array[T.untyped]) }
  def normalize_allocating_mir_stmt!(stmt)
    prefix = T.let([], T::Array[T.untyped])
    case stmt
    when MIR::Let
      prefix.concat(normalize_allocating_result_expr!(stmt.init))
    when MIR::Set
      prefix.concat(normalize_used_expr_attr!(stmt, :target))
      prefix.concat(normalize_allocating_result_expr!(stmt.value))
    when MIR::ReassignWithCleanup
      unless T.unsafe(self).fallible_self_fallback_reassign?(stmt.name.to_s, stmt.value)
        prefix.concat(normalize_used_expr_attr!(stmt, :value))
      end
    when MIR::ExprStmt
      prefix.concat(normalize_used_expr_attr!(stmt, :expr))
    when MIR::ReturnStmt, MIR::BreakStmt
      prefix.concat(normalize_used_expr_attr!(stmt, :value))
    when MIR::IfStmt
      prefix.concat(normalize_used_expr_attr!(stmt, :cond))
    when MIR::IfBindStmt
      stmt.bindings.each do |binding|
        expr = binding[:expr]
        expr_prefix, normalized = normalize_allocating_used_expr(expr)
        binding[:expr] = normalized
        prefix.concat(expr_prefix)
        capture = binding[:capture].to_s
        next unless normalized.is_a?(MIR::Ident)
        capture_cleanup = stmt.then_body.find { |child| child.is_a?(MIR::Cleanup) && child.name.to_s == capture }
        next unless capture_cleanup.is_a?(MIR::Cleanup)
        next if if_bind_transfer_present?(stmt, normalized.name.to_s)

        target_alloc = capture_cleanup.cleanup_entry.alloc
        stmt.then_body.unshift(MIR::TransferMark.new(normalized.name.to_s, :owned_sink, target_alloc))
        stmt.else_body ||= []
        stmt.else_body.unshift(MIR::TransferMark.new(normalized.name.to_s, :owned_sink, target_alloc))
      end
    when MIR::WhileStmt
      prefix.concat(normalize_used_expr_attr!(stmt, :cond))
      prefix.concat(normalize_used_expr_attr!(stmt, :update)) if stmt.update
    when MIR::ForStmt
      prefix.concat(normalize_used_expr_attr!(stmt, :iter))
    when MIR::SwitchStmt, MIR::UnionMatchStmt
      prefix.concat(normalize_used_expr_attr!(stmt, :subject))
    when MIR::IfChain
      stmt.branches&.each do |branch|
        cond = branch[:cond]
        cond_prefix, normalized = normalize_allocating_used_expr(cond)
        branch[:cond] = normalized
        prefix.concat(cond_prefix)
      end
    when MIR::DeferStmt, MIR::ErrDeferStmt
      prefix.concat(normalize_allocating_mir_stmt!(stmt.body))
    when MIR::BatchWindowPush
      prefix.concat(normalize_used_expr_attr!(stmt, :item_expr))
      prefix.concat(normalize_used_expr_attr!(stmt, :value_expr))
    when MIR::BatchWindowFlush
      prefix.concat(normalize_used_expr_attr!(stmt, :value_expr))
    end
    prefix
  end

  sig { params(stmt: T.untyped, attr: Symbol).returns(T::Array[T.untyped]) }
  def normalize_used_expr_attr!(stmt, attr)
    value = stmt.public_send(attr)
    prefix, normalized = normalize_allocating_used_expr(value)
    setter = :"#{attr}="
    stmt.public_send(setter, normalized)
    prefix
  end

  sig { params(stmt: MIR::IfBindStmt, name: String).returns(T::Boolean) }
  def if_bind_transfer_present?(stmt, name)
    [stmt.then_body, stmt.else_body].compact.any? do |body|
      body.any? { |child| child.is_a?(MIR::TransferMark) && child.name.to_s == name }
    end
  end

  sig { params(node: T.untyped).void }
  def normalize_nested_mir_bodies!(node)
    return unless node.respond_to?(:body_slots)

    node.body_slots.each do |slot|
      slot.replace(normalize_allocating_mir_body(slot.body))
    end
    nil
  end

  sig { params(expr: T.untyped).returns(T::Array[T.untyped]) }
  def normalize_allocating_result_expr!(expr)
    prefix = T.let([], T::Array[T.untyped])
    return prefix unless expr.respond_to?(:expr?) && expr.expr?

    result_children = T.let(mir_result_child_exprs(expr), T::Array[T.untyped])
    result_children.each do |child|
      if mir_allocates?(child) || (child.is_a?(MIR::Call) && child.owned_return?)
        child_prefix = normalize_allocating_result_expr!(child)
        prefix.concat(child_prefix)
        next
      end
      used_prefix, normalized = normalize_allocating_used_expr(child, transfer_on_success: consumes_owned_children?(expr))
      replace_mir_expr_child!(expr, child, normalized)
      prefix.concat(used_prefix)
    end
    each_mir_expr_child(expr) do |child|
      next if result_children.any? { |result_child| result_child.equal?(child) }

      used_prefix, normalized = normalize_allocating_used_expr(child, transfer_on_success: consumes_owned_children?(expr))
      replace_mir_expr_child!(expr, child, normalized)
      prefix.concat(used_prefix)
    end
    prefix
  end

  sig { params(expr: T.untyped, transfer_on_success: T::Boolean).returns([T::Array[T.untyped], T.untyped]) }
  def normalize_allocating_used_expr(expr, transfer_on_success: false)
    prefix = T.let([], T::Array[T.untyped])
    return [prefix, expr] unless expr.respond_to?(:expr?) && expr.expr?

    if !mutating_receiver_allocator_op?(expr) &&
       (mir_allocates?(expr) || (expr.is_a?(MIR::Call) && expr.owned_return?))
      nested = normalize_allocating_result_expr!(expr)
      prefix.concat(nested)
      hoisted, ident = hoist_normalized_alloc_expr(expr, transfer_on_success: transfer_on_success)
      prefix.concat(hoisted)
      return [prefix, ident]
    end

    each_mir_expr_child(expr) do |child|
      child_prefix, normalized = normalize_allocating_used_expr(child, transfer_on_success: consumes_owned_children?(expr))
      replace_mir_expr_child!(expr, child, normalized)
      prefix.concat(child_prefix)
    end
    [prefix, expr]
  end

  sig { params(parent: T.untyped, old_child: T.untyped, new_child: T.untyped).void }
  def replace_mir_expr_child!(parent, old_child, new_child)
    return if old_child.equal?(new_child)
    return unless parent.respond_to?(:mir?) && parent.mir?
    return unless parent.class.respond_to?(:members)

    parent.class.members.each do |member|
      value = parent[member]
      if value.equal?(old_child)
        parent[member] = new_child
        refresh_ownership_consumption_for_replaced_child!(parent, old_child, new_child)
        return
      elsif value.is_a?(Array)
        idx = value.index { |item| item.equal?(old_child) }
        if idx
          value[idx] = new_child
          refresh_ownership_consumption_for_replaced_child!(parent, old_child, new_child)
          return
        end
      elsif value.is_a?(Hash)
        key = value.keys.find { |k| value[k].equal?(old_child) }
        if key
          value[key] = new_child
          refresh_ownership_consumption_for_replaced_child!(parent, old_child, new_child)
          return
        end
      end
    end
    nil
  end

  sig { params(parent: T.untyped, old_child: T.untyped, new_child: T.untyped).void }
  def refresh_ownership_consumption_for_replaced_child!(parent, old_child, new_child)
    return unless parent.respond_to?(:ownership_consumption)
    fact = parent.ownership_consumption
    return unless fact.is_a?(MIR::OwnershipConsumptionFact)

    old_names = mir_ident_names(old_child).map(&:to_s).to_set
    new_names = mir_ident_names(new_child).map(&:to_s)
    names = fact.names.reject { |name| old_names.include?(name.to_s) }
    names.concat(new_names)
    parent.ownership_consumption = MIR::OwnershipConsumptionFact.new(
      names: names.map(&:to_s).reject(&:empty?).uniq,
      target: fact.target,
      target_alloc: fact.target_alloc,
      source: fact.source,
    )
    nil
  end

  sig { params(expr: T.untyped, name: String, alloc: T.nilable(Symbol)).void }
  def stamp_allocating_result_target!(expr, name, alloc: nil)
    return if name.empty?

    case expr
    when MIR::InlineZig
      return unless expr.has_alloc_metadata?
      return if expr.mutating_receiver_allocator_op?

      expr.target_var = name
      expr.allocs = expr.allocs.transform_values { |_value| alloc } if alloc
    else
      if alloc && expr.respond_to?(:ownership_effect) && expr.ownership_effect.produces_owned &&
         expr.respond_to?(:alloc=)
        expr.alloc = alloc
      end
      mir_result_child_exprs(expr).each do |child|
        has_alloc_metadata = child.respond_to?(:allocs) && child.allocs && !child.allocs.empty?
        stamp_allocating_result_target!(child, name, alloc: alloc) if has_alloc_metadata || mir_allocates?(child)
      end
    end
    nil
  end

  sig { params(node: T.untyped).returns(T::Array[T.untyped]) }
  def mir_result_child_exprs(node)
    case node
    when MIR::Cast, MIR::TryExpr, MIR::OptionalUnwrap
      [node.expr]
    when MIR::TryCatch
      [node.expr, node.catch_body]
    when MIR::Orelse
      [node.expr, node.fallback]
    when MIR::Conditional
      [node.then_val, node.else_val]
    when MIR::IfOptional
      [node.then_expr, node.else_expr]
    when MIR::Comptime
      [node.expr]
    when MIR::Pipeline
      [node.inner]
    else
      []
    end.compact
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def container_borrow_expr?(ast_node)
    return false unless ast_node
    if ast_node.is_a?(AST::GetIndex)
      ti = Type.from_node!(ast_node.target, context: "container borrow expression")
      return ti.indexed_container_borrow?
    end
    if ast_node.is_a?(AST::BinaryOp) && (ast_node.op == :OR || ast_node.op == :OR_RESCUE)
      return container_borrow_expr?(ast_node.left)
    end
    false
  rescue
    false
  end

  sig { params(expr: T.untyped, ast_node: T.untyped).returns(T.untyped) }
  def copy_container_borrow_if_needed(expr, ast_node)
    return expr unless container_borrow_expr?(ast_node)
    return expr if mir_allocates?(expr)

    ti = Type.from_node!(ast_node, context: "container borrow copy")
    ti = ti.success_type || ti
    return expr unless @union_schemas&.key?(ti.resolved)
    copied = MIR::DeepCopy.new(expr, ti.zig_type, nil, :full_value, :heap)
    hoist_alloc(copied, ast_node, err_cleanup: true)
  end

  sig { params(ast_node: T.untyped, source: String).returns(CleanupEntry) }
  def rc_cleanup_entry(ast_node, source:)
    ti = Type.from_node!(ast_node, context: "RC hoist cleanup")
    zig_t = ti.zig_type
    CleanupEntry.build(:rc, alloc: :heap, has_moved_guard: false,
                       zig_type: zig_t, rc_variant: :standard, rc_alloc: :heap)
  end

  sig { params(zig_type: String, alloc: Symbol).returns(CleanupEntry) }
  def uniform_cleanup_entry(zig_type, alloc: :heap)
    CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: false, zig_type: zig_type)
  end

  sig { params(alloc: Symbol).returns(CleanupEntry) }
  def heap_string_entry(alloc: :heap)
    CleanupEntry.build(:heap_string, alloc: alloc, has_moved_guard: true)
  end

  sig { params(mir: T.untyped).returns(T.nilable(Symbol)) }
  def mir_owned_alloc(mir)
    return nil unless mir && mir.respond_to?(:ownership_effect)
    mir.ownership_effect.alloc
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(T.nilable(CleanupEntry)) }
  def hoist_cleanup_entry(mir, ast_node)
    alloc = mir_owned_alloc(mir) || :heap
    case mir
    when MIR::DupeSlice, MIR::ConcatStr
      heap_string_entry(alloc: alloc)
    when MIR::AllocSlice
      e = uniform_cleanup_entry("[]#{mir.elem_type}", alloc: alloc)
      e[:elem_zig_type] = mir.elem_type
      e
    when MIR::MakeList
      uniform_cleanup_entry("std.ArrayListUnmanaged(#{mir.elem_type})", alloc: alloc)
    when MIR::OwnedSlice
      uniform_cleanup_entry("[]", alloc: alloc)
    when MIR::HeapCreate, MIR::ContainerInit
      uniform_cleanup_entry(mir.zig_type, alloc: alloc)
    when MIR::DeepCopy
      raise "hoist_cleanup_entry: unexpected DeepCopy strategy :#{mir.strategy}" unless mir.strategy == :full_value
      uniform_cleanup_entry(deep_copy_zig_type(mir, ast_node), alloc: alloc)
    when MIR::CapWrap
      if mir.sync_fn
        uniform_cleanup_entry(mir.sync_type, alloc: alloc)
      elsif mir.own_fn
        rc_cleanup_entry(ast_node, source: "MIR::CapWrap (own_fn=#{mir.own_fn})")
      elsif mir.strategy == :local
        uniform_cleanup_entry("*#{mir.zig_base}", alloc: alloc)
      end
    when MIR::SharePromote
      rc_cleanup_entry(ast_node, source: "MIR::SharePromote")
    when MIR::RcRetain, MIR::RcDowngrade, MIR::WeakUpgrade
      cleanup_entry_for_owned_result(ast_node, alloc: alloc) || CleanupEntry.build(:rc, alloc: alloc, has_moved_guard: false)
    when MIR::FreezeExpr
      CleanupEntry.build(:frozen, alloc: :heap, has_moved_guard: false, fixed_alloc: true)
    when MIR::Cast, MIR::TryExpr
      hoist_cleanup_entry(mir.expr, ast_node)
    when MIR::Call, MIR::MethodCall, MIR::TryCatch, MIR::Orelse, MIR::IfOptional, MIR::BlockExpr, MIR::InlineZig, MIR::BgBlock
      cleanup_entry_for_owned_result(ast_node, alloc: alloc) || cleanup_entry_for_ownership_effect(mir, alloc: alloc)
    else
      raise "hoist_cleanup_entry: unhandled allocating MIR node #{mir.class} -- " \
            "mir_allocates? returned true but no cleanup entry is defined. Add a case."
    end
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(String) }
  def deep_copy_zig_type(mir, ast_node)
    return mir.zig_type if mir.zig_type
    ti = Type.from_node!(ast_node, context: "deep-copy zig type")
    bare = Type.new(ti)
    bare.provenance = :stack if bare.respond_to?(:provenance=)
    bare.zig_type
  end

  sig { params(ast_node: T.untyped, alloc: Symbol).returns(T.nilable(CleanupEntry)) }
  def cleanup_entry_for_owned_result(ast_node, alloc: :heap)
    return nil unless ast_node
    ti = Type.from_node!(ast_node, context: "owned result cleanup entry")
    ti = ti.success_type || ti
    return heap_string_entry(alloc: alloc) if ti.string?
    return uniform_cleanup_entry(ti.zig_type, alloc: alloc) if ti.collection?
    zig_t = (Type.new(ti.resolved).zig_type rescue nil)
    return nil unless zig_t
    uniform_cleanup_entry(zig_t, alloc: alloc)
  end

  sig { params(mir: T.untyped, alloc: Symbol).returns(T.nilable(CleanupEntry)) }
  def cleanup_entry_for_ownership_effect(mir, alloc: :heap)
    return nil unless mir.respond_to?(:ownership_effect)

    if mir.is_a?(MIR::BlockExpr)
      transferred = mir_ident_names(mir).first
      if transferred
        let = mir.body&.find { |stmt| stmt.is_a?(MIR::Let) && stmt.name.to_s == transferred.to_s }
        return hoist_cleanup_entry(let.init, nil) if let
      end
    end

    effect = mir.ownership_effect
    return nil unless effect.produces_owned

    case effect.cleanup_kind
    when :heap_string
      heap_string_entry(alloc: alloc)
    when :rc
      CleanupEntry.build(:rc, alloc: alloc, has_moved_guard: false)
    when :frozen
      CleanupEntry.build(:frozen, alloc: :heap, has_moved_guard: false, fixed_alloc: true)
    else
      nil
    end
  end

  sig { params(node: T.untyped).returns(T::Array[String]) }
  def mir_ident_names(node)
    case node
    when MIR::Ident
      [node.name.to_s]
    when MIR::BlockExpr
      local_names = node.body.each_with_object(Set.new) do |stmt, names|
        names << stmt.name.to_s if stmt.is_a?(MIR::AllocMark)
        names << stmt.name.to_s if stmt.is_a?(MIR::Let)
      end
      transferred_names = node.body.each_with_object(Set.new) do |stmt, names|
        names << stmt.name.to_s if stmt.is_a?(MIR::TransferMark) && stmt.target == :block_result
      end
      last = node.body.reverse.find { |s| s.is_a?(MIR::BreakStmt) }
      last ? mir_ident_names(last.value).reject { |name|
        local_names.include?(name.to_s) || transferred_names.include?(name.to_s)
      } : []
    else
      return [] if ownership_borrow_boundary?(node)
      names = T.let([], T::Array[String])
      each_mir_expr_child(node) do |child|
        mir_ident_names(child).each { |name| names << name.to_s }
      end
      names.uniq
    end
  end

end
