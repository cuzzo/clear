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
require_relative "mir"
require_relative "cleanup_entry"
require_relative "../ast/ast"
require_relative "../ast/type"

module Hoist
  extend T::Sig
  module_function

  ELEMENT_STORE = T.let(%w[append insert push put].freeze, T::Array[String])

  sig { params(ast: T.untyped).void }
  def apply!(ast)
    ctr = T.let([0], T::Array[Integer])
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      hoist_body!(stmt.body, ctr)
    end
  end

  # Walk a statement list. For each statement, lift the hoistable
  # sub-expressions into temp decls inserted immediately before it.
  sig { params(body: T.untyped, ctr: T::Array[Integer]).void }
  def hoist_body!(body, ctr)
    return unless body.is_a?(Array)
    i = 0
    while i < body.length
      stmt = body[i]
      hoists = T.let([], T::Array[T.untyped])
      collect_stmt_hoists!(stmt, hoists, ctr)
      hoists.each_with_index { |decl, j| body.insert(i + j, decl) }
      i += hoists.length
      # Recurse into nested statement bodies (control flow). Nested
      # functions / lambdas / BG blocks are separate frames -- each is
      # reached as its own AST::FunctionDef or handled separately.
      child_bodies(stmt).each { |b| hoist_body!(b, ctr) }
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
  sig { params(stmt: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).void }
  def collect_stmt_hoists!(stmt, hoists, ctr)
    each_method_call(stmt) do |call|
      next unless ELEMENT_STORE.include?(call.name.to_s)
      next unless composite_element_store?(call)
      (call.args || []).each_with_index do |arg, idx|
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
      stmt.value = hoist_escape_value!(stmt.value, hoists, ctr) if stmt.value
    when AST::YieldExpr
      stmt.expr = hoist_escape_value!(stmt.expr, hoists, ctr) if stmt.expr
    when AST::Assignment
      if stmt.name.is_a?(AST::GetField) || stmt.name.is_a?(AST::GetIndex)
        stmt.value = hoist_escape_value!(stmt.value, hoists, ctr) if stmt.value
      end
    end
  end

  sig { params(value: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).returns(T.untyped) }
  def hoist_escape_value!(value, hoists, ctr)
    return make_temp!(value, hoists, ctr) if allocating?(value)
    if value.is_a?(AST::StructLit) || value.is_a?(AST::UnionVariantLit) || value.is_a?(AST::ListLit)
      hoist_concats_within!(value, hoists, ctr)
    end
    value
  end

  # An anonymous expression that allocates a fresh heap-able value and so
  # needs its own binding for escape analysis to place it.
  sig { params(node: T.untyped).returns(T::Boolean) }
  def allocating?(node)
    return false unless node
    concat?(node) || node.is_a?(AST::ListLit) || node.is_a?(AST::HashLit) ||
      node.is_a?(AST::MethodCall)
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
  sig { params(concat: T.untyped, hoists: T::Array[T.untyped], ctr: T::Array[Integer]).returns(T.untyped) }
  def make_temp!(concat, hoists, ctr)
    n = T.must(ctr[0]) + 1
    ctr[0] = n
    name = "__hoist_#{n}"
    tok = concat.respond_to?(:token) ? concat.token : nil
    ti = concat.full_type
    storage = (concat.respond_to?(:storage) && concat.storage) || :frame

    decl = AST::VarDecl.new(tok, name, nil, concat, false)
    decl.full_type = ti
    # The temp is always consumed by the statement it was lifted from
    # (return / yield / element store), so it is used by construction --
    # var-use analysis ran before this pass and cannot know that.
    decl.var_used = true
    # decl.storage (a node field) is left as annotation's default; escape
    # analysis records the definitive placement on sym.storage below.
    sym = SymbolEntry.new(reg: decl, type: ti, mutable: false, storage: storage)
    decl.symbol = sym
    hoists << decl

    ident = AST::Identifier.new(tok, name)
    ident.full_type = ti
    ident.symbol = sym
    # The temp replaces a sub-expression in an ownership-consuming
    # position (element-store arg / struct field of one). Stamp the
    # move so ownership dataflow transfers the temp into the container
    # instead of cleaning it up at scope exit.
    ident.was_moved = true if ident.respond_to?(:was_moved=)
    # An @indirect field value carries needs_heap_create; the stamp must
    # follow the value to its new position.
    if concat.respond_to?(:needs_heap_create) && concat.needs_heap_create
      ident.needs_heap_create = true
    end
    ident
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

  # Nodes whose "allocates?" decision is simply `node.alloc == :heap`.
  ALLOC_HEAP_MIR_CLASSES = [
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
    MIR::BlockExpr.new(label, scoped + [MIR::BreakStmt.new(label, result)])
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
      lower_scoped { T.unsafe(self).lower(child) }
    else
      T.unsafe(self).lower(child)
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def mir_allocates?(node)
    return true if MIR::HeapCreate === node
    return node.alloc == :heap if ALLOC_HEAP_MIR_CLASSES.any? { |c| c === node }
    case node
    when MIR::Call, MIR::TryCatch
      !!node.heap_provenance
    when MIR::Cast
      mir_allocates?(node.expr)
    when MIR::InlineZig
      return false unless node.stdlib_def&.emit&.allocates
      return true unless node.allocs
      node.allocs.any? { |_k, v| v == :heap }
    else
      false
    end
  end

  sig { params(node: T.untyped, ft: T.untyped, binding_entry: CleanupEntry, init: T.untyped, decl_alloc: Symbol).returns(Symbol) }
  def pick_node_alloc(node, ft, binding_entry, init, decl_alloc)
    return :heap if mir_allocates?(init)
    return :heap if node.respond_to?(:storage) && node.storage == :heap
    if binding_entry.present? && binding_entry.alloc == :heap &&
       T.unsafe(self).alloc_for_node(node) != :heap && !ft.needs_heap_backing? &&
       binding_entry.kind != :frozen
      return :frame
    end
    (binding_entry.present? && binding_entry.alloc) || decl_alloc
  end

  sig { params(expr: T.untyped, ast_node: T.untyped, err_cleanup: T.nilable(T::Boolean), mutable: T::Boolean).returns(T.untyped) }
  def hoist_alloc(expr, ast_node = nil, err_cleanup: false, mutable: false)
    return expr unless mir_allocates?(expr) || T.unsafe(self).send(:call_union_return_needs_hoist?, expr, ast_node)
    @tmp_counter += 1
    name = "__tmp_#{@tmp_counter}"
    @pending_stmts << MIR::AllocMark.new(name, :heap, nil)
    @pending_stmts << MIR::Let.new(name, expr, mutable, nil, nil)
    entry = hoist_cleanup_entry(expr, ast_node)
    if entry
      cleanup = err_cleanup ? MIR::ErrCleanup.new(name, entry) : MIR::Cleanup.new(name, entry)
      @pending_stmts << cleanup
      (@guarded_cleanup_names ||= {})[name] = true if entry.has_moved_guard?
    end
    MIR::Ident.new(name)
  end

  sig { params(expr: T.untyped, ast_node: T.untyped, err_cleanup: T.nilable(T::Boolean)).returns(T.untyped) }
  def hoist_owned_value_temp(expr, ast_node, err_cleanup: false)
    return expr unless owned_value_temp_needs_cleanup?(ast_node)

    @tmp_counter += 1
    name = "__tmp_#{@tmp_counter}"
    ti = Type.from_node(ast_node)
    zig_t = ti ? Type.new(ti.resolved).zig_type : "UNKNOWN"
    schema_lookup = T.unsafe(self).instance_variable_get(:@schema_lookup)
    alloc = if ti&.recursive_cleanup_shape?(schema_lookup)
              :heap
            else
              @decl_alloc == :heap ? :heap : :frame
            end
    entry = CleanupEntry.from({ kind: :uniform, alloc: alloc, has_moved_guard: false, zig_type: zig_t })

    @pending_stmts << MIR::AllocMark.new(name, alloc, ti)
    @pending_stmts << MIR::Let.new(name, expr, false, nil, nil)
    @pending_stmts << (err_cleanup ? MIR::ErrCleanup.new(name, entry) : MIR::Cleanup.new(name, entry))
    MIR::Ident.new(name)
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def owned_value_temp_needs_cleanup?(ast_node)
    return false unless ast_node
    return false if ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode) || ast_node.is_a?(AST::MoveNode)
    return false if ast_node.is_a?(AST::Identifier) || ast_node.is_a?(AST::GetField) || ast_node.is_a?(AST::GetIndex)
    return false if container_borrow_expr?(ast_node)
    ti = Type.from_node(ast_node)
    return false unless ti
    ti = ti.payload_type || ti if ti.error_union?
    @union_schemas&.key?(ti.resolved) &&
      ti.needs_explicit_cleanup?(:heap, @schema_lookup)
  rescue
    false
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def container_borrow_expr?(ast_node)
    return false unless ast_node
    if ast_node.is_a?(AST::GetIndex)
      ti = ast_node.target.full_type
      return !!ti&.indexed_container_borrow?
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
    ti = Type.from_node(ast_node)
    return expr unless ti
    ti = ti.payload_type || ti if ti.error_union?
    return expr unless @union_schemas&.key?(ti.resolved)
    copied = MIR::DeepCopy.new(expr, ti.zig_type, nil, :full_value, :heap)
    hoist_alloc(copied, ast_node, err_cleanup: true)
  end

  sig { params(ast_node: T.untyped, source: String).returns(CleanupEntry) }
  def rc_cleanup_entry(ast_node, source:)
    ti = Type.from_node(ast_node)
    zig_t = ti&.zig_type
    raise "hoist_cleanup_entry: #{source} has no zig_type -- ast_node type_info unavailable" unless zig_t
    CleanupEntry.build(:rc, alloc: :heap, has_moved_guard: false,
                       zig_type: zig_t, rc_variant: :standard, rc_alloc: :heap)
  end

  sig { params(zig_type: String).returns(CleanupEntry) }
  def uniform_cleanup_entry(zig_type)
    CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false, zig_type: zig_type)
  end

  sig { returns(CleanupEntry) }
  def heap_string_entry
    CleanupEntry.build(:heap_string, alloc: :heap, has_moved_guard: true)
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(T.nilable(CleanupEntry)) }
  def hoist_cleanup_entry(mir, ast_node)
    case mir
    when MIR::DupeSlice, MIR::ConcatStr
      heap_string_entry
    when MIR::AllocSlice
      e = uniform_cleanup_entry("[]#{mir.elem_type}")
      e[:elem_zig_type] = mir.elem_type
      e
    when MIR::MakeList
      uniform_cleanup_entry("std.ArrayListUnmanaged(#{mir.elem_type})")
    when MIR::HeapCreate, MIR::ContainerInit
      uniform_cleanup_entry(mir.zig_type)
    when MIR::DeepCopy
      raise "hoist_cleanup_entry: unexpected DeepCopy strategy :#{mir.strategy}" unless mir.strategy == :full_value
      uniform_cleanup_entry(deep_copy_zig_type(mir, ast_node))
    when MIR::CapWrap
      if mir.sync_fn
        uniform_cleanup_entry(mir.sync_type)
      elsif mir.own_fn
        rc_cleanup_entry(ast_node, source: "MIR::CapWrap (own_fn=#{mir.own_fn})")
      end
    when MIR::SharePromote
      rc_cleanup_entry(ast_node, source: "MIR::SharePromote")
    when MIR::Cast
      hoist_cleanup_entry(mir.expr, ast_node)
    when MIR::Call, MIR::TryCatch, MIR::InlineZig
      cleanup_entry_for_heap_result(ast_node)
    else
      raise "hoist_cleanup_entry: unhandled allocating MIR node #{mir.class} -- " \
            "mir_allocates? returned true but no cleanup entry is defined. Add a case."
    end
  end

  sig { params(mir: T.untyped, ast_node: T.untyped).returns(String) }
  def deep_copy_zig_type(mir, ast_node)
    return mir.zig_type if mir.zig_type
    ti = Type.from_node(ast_node)
    raise "hoist_cleanup_entry: MIR::DeepCopy :full_value has no zig_type" unless ti
    bare = Type.new(ti)
    bare.provenance = :stack if bare.respond_to?(:provenance=)
    bare.zig_type
  end

  sig { params(ast_node: T.untyped).returns(T.nilable(CleanupEntry)) }
  def cleanup_entry_for_heap_result(ast_node)
    ti = Type.from_node(ast_node)
    return nil unless ti
    ti = ti.payload_type || ti if ti.error_union?
    return heap_string_entry if ti.string?
    return uniform_cleanup_entry(ti.zig_type) if ti.list_collection?
    zig_t = (Type.new(ti.resolved).zig_type rescue nil)
    return nil unless zig_t
    uniform_cleanup_entry(zig_t)
  end

  sig { params(node: T.untyped).returns(T::Array[String]) }
  def mir_ident_names(node)
    case node
    when MIR::Ident
      [node.name.to_s]
    when MIR::StructInit
      node.fields.flat_map { |f| mir_ident_names(f[:value]) }
    when MIR::Cast
      mir_ident_names(node.expr)
    when MIR::HeapCreate
      mir_ident_names(node.init)
    when MIR::BlockExpr
      last = node.body.reverse.find { |s| s.is_a?(MIR::BreakStmt) }
      last ? mir_ident_names(last.value) : []
    else
      []
    end
  end

  sig { params(value: T.untyped, returned_names: T.untyped).returns(T::Array[MIR::MoveMark]) }
  def returned_transfer_marks(value, returned_names)
    names = {}
    returned_names.to_a.each { |n| names[n.to_s] = true } if returned_names
    mir_ident_names(value).each { |n| names[n.to_s] = true }
    names.keys
      .select { |n| @guarded_cleanup_names&.[](n) }
      .map { |n| MIR::MoveMark.new(n) }
  end
end
