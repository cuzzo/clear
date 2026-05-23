# typed: strict
# EscapeGraph -- deliberately small escape placement pass.
#
# This pass answers one question for symbol-bearing bindings:
#   does this binding escape the frame where it was declared?
#
# Output is intentionally tiny: escaped bindings get SymbolEntry#storage = :heap.
# Lowering and cleanup read that storage. They do not re-decide escape.
require "set"
require "sorbet-runtime"
require_relative "escape_analysis"

module EscapeGraph
  extend T::Sig
  module_function

  FnNodes = T.type_alias { T::Hash[T.untyped, AST::FunctionDef] }

  ELEMENT_STORE_METHODS = T.let(%w[append insert push put].freeze, T::Array[String])

  sig { params(fn_nodes: FnNodes, schema_lookup: T.untyped).returns([T::Set[String], T::Set[String]]) }
  def apply!(fn_nodes, schema_lookup = nil)
    @schema_lookup = T.let(schema_lookup, T.untyped)
    heap_decls = T.let(Set.new, T::Set[String])

    fn_nodes.each_value do |fn|
      next unless fn.body
      mark_inherent_heap!(fn)
      escape_fn!(fn, fn_nodes, heap_decls)
      stamp_return_provenance!(fn, fn_nodes)
    end

    fn_nodes.each_value do |fn|
      next unless fn.body
      mark_return_receivers!(fn, fn_nodes, heap_decls)
      stamp_return_provenance!(fn, fn_nodes)
    end

    fn_nodes.each_value do |fn|
      next unless fn.body
      escape_fn!(fn, fn_nodes, heap_decls)
      stamp_return_provenance!(fn, fn_nodes)
    end

    EscapeAnalysis.propagate_caller_sync!(fn_nodes)
    heap_fns = fn_nodes.each_with_object(T.let(Set.new, T::Set[String])) do |(name, fn), set|
      set << name.to_s if fn.return_provenance == :heap
    end
    [heap_fns, heap_decls]
  end

  sig { params(storage: T.nilable(Symbol)).returns(Symbol) }
  def storage_to_alloc(storage)
    storage == :heap ? :heap : :frame
  end

  sig { params(sym: T.untyped).returns(T.nilable(Symbol)) }
  def authoritative_storage(sym)
    return nil unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    decl_sym = decl && decl.respond_to?(:symbol) ? decl.symbol : nil
    decl_sym&.storage || sym.storage
  end

  sig { params(fn: AST::FunctionDef).void }
  def mark_inherent_heap!(fn)
    each_decl(fn.body) do |decl|
      ti = type_of(decl)
      stamp_heap!(decl) if ti.is_a?(Type) && inherent_heap_type?(ti)
    end
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes, heap_decls: T::Set[String]).void }
  def escape_fn!(fn, fn_nodes, heap_decls)
    scopes = T.let([], T::Array[T::Hash[String, T.untyped]])
    walk_scope(fn, fn.body, scopes, false, fn_nodes) do |decl|
      stamp_heap!(decl)
      heap_decls << decl.name.to_s if decl.respond_to?(:name)
    end
  end

  sig do
    params(fn: AST::FunctionDef, body: T.untyped, scopes: T::Array[T::Hash[String, T.untyped]], in_fiber: T::Boolean,
           fn_nodes: FnNodes, mark: T.proc.params(arg0: T.untyped).void).void
  end
  def walk_scope(fn, body, scopes, in_fiber, fn_nodes, &mark)
    return unless body.is_a?(Array)
    locals = local_decls(body)
    local_names = Set.new(locals.keys)
    outer_decls = scopes.reduce(T.let({}, T::Hash[String, T.untyped])) { |acc, s| acc.merge(s) }
    outer_names = Set.new(outer_decls.keys)
    scopes.push(locals)

    walk_current_frame(body) do |node|
      case node
      when AST::ReturnNode
        each_binding_ref(node.value) do |id|
          sym = id.symbol
          next if value_shaped_return_param?(node.value, sym)
          next if sym&.is_param && !sym&.takes
          next unless returned_binding_escapes?(fn, id)
          mark.call(sym&.reg)
        end
      when AST::YieldExpr
        each_binding_ref(node.expr) { |id| mark.call(id.symbol&.reg) }
      when AST::Identifier
        if in_fiber && outer_names.include?(node.name.to_s)
          mark.call(node.symbol&.reg)
        end
      when AST::VarDecl
        mark_heap_payloads!(node, &mark)
      when AST::BindExpr
        if node.mode == :decl
          mark_heap_payloads!(node, &mark)
          next
        end
        mark_enclosing_store!(node.name, node.value, local_names, outer_names, outer_decls, &mark)
      when AST::Assignment
        mark_enclosing_store!(node.name, node.value, local_names, outer_names, outer_decls, &mark)
        mark_heap_container_assignment!(node.name, node.value, &mark)
      when AST::FuncCall, AST::MethodCall
        mark_takes_args!(node, fn_nodes, &mark)
        mark_element_store!(node, local_names, outer_names, &mark) if node.is_a?(AST::MethodCall)
        mark_heap_element_store!(node, &mark) if node.is_a?(AST::MethodCall)
        mark_heap_value_container_store!(node, fn_nodes, &mark) if node.is_a?(AST::MethodCall)
      end
    end

    nested_scopes(body).each do |nested_body, fiber|
      walk_scope(fn, nested_body, scopes, in_fiber || fiber, fn_nodes, &mark)
    end
  ensure
    scopes.pop if scopes.last.equal?(locals)
  end

  sig do
    params(target: T.untyped, value: T.untyped, locals: T::Set[String], outer_names: T::Set[String],
           outer_decls: T::Hash[String, T.untyped],
           mark: T.proc.params(arg0: T.untyped).void).void
  end
  def mark_enclosing_store!(target, value, locals, outer_names, outer_decls, &mark)
    root = root_name(target)
    return unless root && outer_names.include?(root) && !locals.include?(root)
    each_binding_ref(value) { |id| mark.call(id.symbol&.reg) }
    root_decl = root_decl_from(target) || outer_decls[root]
    mark.call(root_decl) if root_decl && frame_backed_container?(root_decl)
  end

  sig do
    params(call: AST::MethodCall, locals: T::Set[String], outer_names: T::Set[String],
           mark: T.proc.params(arg0: T.untyped).void).void
  end
  def mark_element_store!(call, locals, outer_names, &mark)
    return unless ELEMENT_STORE_METHODS.include?(call.name.to_s)
    root = root_name(call.object)
    return unless root && outer_names.include?(root) && !locals.include?(root)
    call.args.each { |arg| each_binding_ref(arg) { |id| mark.call(id.symbol&.reg) } }
    decl = root_decl_from(call.object)
    mark.call(decl) if decl && frame_backed_container?(decl)
  end

  sig { params(target: T.untyped, value: T.untyped, mark: T.proc.params(arg0: T.untyped).void).void }
  def mark_heap_container_assignment!(target, value, &mark)
    return unless target.is_a?(AST::GetIndex) || target.is_a?(AST::GetField)
    decl = root_decl_from(target)
    target_owner = target.respond_to?(:target) ? target.target : target
    return unless heap_backed_container?(decl) || heap_backed_container_expr?(target_owner)
    each_binding_ref(value) { |id| mark.call(id.symbol&.reg) }
  end

  sig { params(call: AST::MethodCall, mark: T.proc.params(arg0: T.untyped).void).void }
  def mark_heap_element_store!(call, &mark)
    return unless ELEMENT_STORE_METHODS.include?(call.name.to_s)
    decl = root_decl_from(call.object)
    return unless heap_backed_container?(decl) || heap_backed_container_expr?(call.object)
    call.args.each { |arg| each_binding_ref(arg) { |id| mark.call(id.symbol&.reg) } }
  end

  sig { params(call: AST::MethodCall, fn_nodes: FnNodes, mark: T.proc.params(arg0: T.untyped).void).void }
  def mark_heap_value_container_store!(call, fn_nodes, &mark)
    return unless ELEMENT_STORE_METHODS.include?(call.name.to_s)
    decl = root_decl_from(call.object)
    return unless decl && frame_backed_container?(decl)
    escapes = (call.args || []).any? do |arg|
      return_expr_provenance(arg, fn_nodes) == :heap ||
        heap_binding_ref?(arg)
    end
    mark.call(decl) if escapes
  end

  sig { params(decl: T.untyped, mark: T.proc.params(arg0: T.untyped).void).void }
  def mark_heap_payloads!(decl, &mark)
    return unless decl.respond_to?(:value)
    return unless decl.respond_to?(:symbol) && decl.symbol&.heap_provenance?
    each_binding_ref(decl.value) { |id| mark.call(id.symbol&.reg) }
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  def heap_binding_ref?(expr)
    found = T.let(false, T::Boolean)
    each_binding_ref(expr) { |id| found = true if id.symbol&.heap_provenance? }
    found
  end

  sig { params(call: T.untyped, fn_nodes: FnNodes, mark: T.proc.params(arg0: T.untyped).void).void }
  def mark_takes_args!(call, fn_nodes, &mark)
    callee = fn_nodes[call.name.to_s] || fn_nodes[call.name]
    return unless callee.is_a?(AST::FunctionDef)
    args = call.args || []
    callee.params.each_with_index do |param, idx|
      arg = args[idx]
      next unless arg
      pt = param.type
      mutable_collection = param.mutable && pt.is_a?(Type) && collection_type?(pt)
      takes_collection = param.takes && pt.is_a?(Type) && collection_type?(pt)
      takes_owned_shape = param.takes && pt.is_a?(Type) && type_shape_needs_recursive_cleanup?(pt)
      next unless mutable_collection || takes_collection || takes_owned_shape || param_storage_heap?(param)
      each_binding_ref(arg) { |id| mark.call(id.symbol&.reg) }
    end
  end

  sig { params(param: T.untyped).returns(T::Boolean) }
  def param_storage_heap?(param)
    sym = param.respond_to?(:symbol) ? param.symbol : nil
    !!(sym&.heap_provenance? || sym&.storage == :heap)
  end

  sig { params(fn: AST::FunctionDef, id: AST::Identifier).returns(T::Boolean) }
  def returned_binding_escapes?(fn, id)
    rt = fn.return_type
    return true if rt.is_a?(Type) && inherent_heap_type?(rt)
    bare_rt = rt.respond_to?(:error_union?) && rt.error_union? ? (rt.payload_type || rt) : rt
    return true if bare_rt.is_a?(Type) && inherent_heap_type?(bare_rt)

    decl = id.symbol&.reg
    storage = decl.respond_to?(:storage) ? decl.storage : nil
    return false if storage == :rodata

    ti = type_of(id)
    return false unless ti.is_a?(Type)
    return true if ti.string?
    return true if collection_type?(ti)
    return true if type_shape_needs_recursive_cleanup?(ti)
    false
  rescue
    false
  end

  sig { params(value: T.untyped, sym: T.untyped).returns(T::Boolean) }
  def value_shaped_return_param?(value, sym)
    return false unless sym&.is_param
    value.is_a?(AST::StructLit) || value.is_a?(AST::UnionVariantLit)
  end

  sig { params(decl: T.untyped).void }
  def stamp_heap!(decl)
    stamp_storage!(decl, :heap)
  end

  sig { params(decl: T.untyped, storage: Symbol).void }
  def stamp_storage!(decl, storage)
    return unless decl && decl.respond_to?(:symbol) && decl.symbol
    return if decl.symbol.storage == :heap && storage != :heap
    decl.symbol.storage = storage
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes).void }
  def stamp_return_provenance!(fn, fn_nodes)
    if borrow_return?(fn)
      fn.return_provenance = :borrow
      return
    end

    rt = fn.return_type
    if rt.is_a?(Type) && inherent_heap_type?(rt)
      fn.return_provenance = :heap
      return
    end
    if owned_string_return_type?(rt)
      fn.return_provenance = :heap
      return
    end
    fn.return_provenance = nil
    return_values(fn.body).each do |rv|
      fn.return_provenance = merge_provenance(fn.return_provenance, return_expr_provenance(rv, fn_nodes))
      return if fn.return_provenance == :heap
    end
  end

  sig { params(rt: T.untyped).returns(T::Boolean) }
  def owned_string_return_type?(rt)
    return false unless rt.is_a?(Type)
    bare = rt.respond_to?(:error_union?) && rt.error_union? ? (rt.payload_type || rt) : rt
    return false unless bare.respond_to?(:string?) && bare.string?
    sync = bare.respond_to?(:sync) ? bare.sync : nil
    sync != :symbol && sync != :raw
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes, heap_decls: T::Set[String]).void }
  def mark_return_receivers!(fn, fn_nodes, heap_decls)
    each_decl(fn.body) do |decl|
      prov = call_return_provenance(decl.respond_to?(:value) ? decl.value : nil, fn_nodes)
      next unless prov
      stamp_storage!(decl, prov)
      heap_decls << decl.name.to_s if prov == :heap && decl.respond_to?(:name)
    end
  end

  sig { params(expr: T.untyped, fn_nodes: FnNodes).returns(T::Boolean) }
  def call_returns_heap?(expr, fn_nodes)
    call_return_provenance(expr, fn_nodes) == :heap
  end

  sig { params(expr: T.untyped, fn_nodes: FnNodes).returns(T.nilable(Symbol)) }
  def call_return_provenance(expr, fn_nodes)
    case expr
    when AST::FuncCall
      callee = fn_nodes[expr.name.to_s] || fn_nodes[expr.name]
      return callee.return_provenance if callee.is_a?(AST::FunctionDef) && callee.return_provenance
      sig = expr.respond_to?(:matched_signature) ? expr.matched_signature : nil
      return sig.return_provenance if sig.respond_to?(:return_provenance) && sig.return_provenance
      return :heap if expr.respond_to?(:heap_provenance?) && expr.heap_provenance?
      return :borrow if expr.respond_to?(:borrow_provenance?) && expr.borrow_provenance?
      return :rodata if expr.respond_to?(:rodata_provenance?) && expr.rodata_provenance?
      ti = expr.full_type if expr.respond_to?(:full_type)
      :heap if ti.is_a?(Type) && inherent_heap_type?(ti)
    when AST::MethodCall
      return :heap if expr.respond_to?(:heap_provenance?) && expr.heap_provenance?
      return :borrow if expr.respond_to?(:borrow_provenance?) && expr.borrow_provenance?
      return :rodata if expr.respond_to?(:rodata_provenance?) && expr.rodata_provenance?
      ti = expr.full_type if expr.respond_to?(:full_type)
      :heap if ti.is_a?(Type) && inherent_heap_type?(ti)
    when AST::BinaryOp
      return pipeline_return_provenance(expr, fn_nodes) if expr.op == :SMOOTH
      expr.op == :OR_RESCUE ? call_return_provenance(expr.left, fn_nodes) : nil
    else
      nil
    end
  end

  sig { params(expr: AST::BinaryOp, fn_nodes: FnNodes).returns(T.nilable(Symbol)) }
  def pipeline_return_provenance(expr, fn_nodes)
    rhs = expr.right
    callee_name = case rhs
                  when AST::Identifier then rhs.name
                  when AST::FuncCall then rhs.name
                  else nil
                  end
    return nil unless callee_name
    callee = fn_nodes[callee_name.to_s] || fn_nodes[callee_name]
    return nil unless callee.is_a?(AST::FunctionDef)
    callee.return_provenance
  end

  sig { params(expr: T.untyped, fn_nodes: FnNodes).returns(T.nilable(Symbol)) }
  def return_expr_provenance(expr, fn_nodes)
    return nil unless expr
    return :heap if return_expr_allocates_owned?(expr, fn_nodes)
    case expr
    when AST::Literal
      ti = type_of(expr)
      return :rodata if ti.is_a?(Type) && ti.string?
    when AST::FuncCall, AST::MethodCall
      return call_return_provenance(expr, fn_nodes)
    end

    found = T.let(nil, T.nilable(Symbol))
    each_binding_ref(expr) do |id|
      sym = id.symbol
      prov = if sym&.heap_provenance?
        ti = type_of(id)
        ti.is_a?(Type) && ti.primitive? ? nil : :heap
      elsif sym&.borrow_provenance?
        :borrow
      elsif sym&.is_param && !sym&.takes
        :borrow
      elsif sym&.rodata_provenance?
        :rodata
      else
        ti = type_of(id)
        ti.is_a?(Type) && ti.string? ? :borrow : nil
      end
      found = merge_provenance(found, prov)
    end
    found
  end

  sig { params(expr: T.untyped, fn_nodes: FnNodes).returns(T::Boolean) }
  def return_expr_allocates_owned?(expr, fn_nodes)
    return false unless expr
    case expr
    when AST::CopyNode, AST::CloneNode
      true
    when AST::Literal
      false
    when AST::BinaryOp
      ti = type_of(expr)
      (ti.is_a?(Type) && ti.string?) || return_expr_allocates_owned?(expr.left, fn_nodes) || return_expr_allocates_owned?(expr.right, fn_nodes)
    when AST::FuncCall
      callee = fn_nodes[expr.name.to_s] || fn_nodes[expr.name]
      return callee.return_provenance == :heap if callee.is_a?(AST::FunctionDef) && callee.return_provenance
      sig = expr.respond_to?(:matched_signature) ? expr.matched_signature : nil
      return sig.return_provenance == :heap if sig.respond_to?(:return_provenance) && sig.return_provenance
      ti = type_of(expr)
      ti.is_a?(Type) && (ti.string? || collection_type?(ti))
    when AST::MethodCall
      ti = type_of(expr)
      ti.is_a?(Type) && (ti.string? || collection_type?(ti))
    when AST::StructLit, AST::UnionVariantLit
      expr.fields.values.any? { |v| return_expr_allocates_owned?(v, fn_nodes) }
    when AST::ListLit
      true
    else
      false
    end
  end

  sig { params(current: T.nilable(Symbol), incoming: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def merge_provenance(current, incoming)
    return current unless incoming
    return :heap if current == :heap || incoming == :heap
    return :borrow if current == :borrow || incoming == :borrow
    incoming
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  def borrow_return?(fn)
    lifetime = fn.respond_to?(:return_lifetime) ? fn.return_lifetime : nil
    return false unless lifetime && !lifetime.empty?
    true
  end

  sig { params(body: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_decl(body, &blk)
    walk_all(body) do |node|
      blk.call(node) if decl?(node)
    end
  end

  sig { params(stmts: T.untyped).returns(T::Hash[String, T.untyped]) }
  def local_decls(stmts)
    decls = T.let({}, T::Hash[String, T.untyped])
    walk_current_frame(stmts) { |n| decls[n.name.to_s] = n if decl?(n) }
    decls
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def decl?(node)
    node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def type_of(node)
    node.respond_to?(:full_type) ? node.full_type : nil
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def inherent_heap_type?(ti)
    ti.any_sync? || ti.any_rc? || ti.link? || ti.sharded? || ti.striped? ||
      ti.set_collection? || ti.map_init_needs_alloc? ||
      (ti.respond_to?(:indirect?) && ti.indirect?) ||
      ti.stream? || ti.tense_observable? || ti.shared_promise? || ti.promise_list?
  end

  sig { params(ti: T.untyped).returns(T::Boolean) }
  def collection_type?(ti)
    !!(ti.is_a?(Type) && (ti.list_collection? || ti.map? || ti.set_collection? || ti.pool?))
  end

  sig { params(ti: Type, seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  def type_shape_needs_recursive_cleanup?(ti, seen = nil)
    seen ||= Set.new
    key = "#{ti.resolved}|#{ti.collection}|#{ti.ownership}|#{ti.sync}|#{ti.provenance}"
    return false if seen.include?(key)
    seen.add(key)
    return false if ti.provenance == :borrow
    return true if ti.string? || ti.any_rc? || ti.link? || collection_type?(ti)
    if ti.array? && !ti.string?
      et = ti.element_type
      return false unless et
      return type_shape_needs_recursive_cleanup?(et.is_a?(Type) ? et : Type.new(et), seen)
    end

    schema = @schema_lookup.call(ti.resolved) rescue nil
    if Schemas.union?(schema)
      return (schema.variants || {}).any? do |_, vt|
        if Schemas.inline_struct?(vt)
          vt.fields.any? do |_, ft|
            type_shape_needs_recursive_cleanup?(ft.is_a?(Type) ? ft : Type.new(ft || :Any), seen)
          end
        else
          type_shape_needs_recursive_cleanup?(vt.is_a?(Type) ? vt : Type.new(vt || :Any), seen)
        end
      end
    end

    if Schemas.field_bearing?(schema)
      return schema.fields.any? do |_, field|
        next false if field.is_a?(AST::StructField) && field.borrowed
        ft = field.is_a?(AST::StructField) ? field.type : field
        type_shape_needs_recursive_cleanup?(ft.is_a?(Type) ? ft : Type.new(ft || :Any), seen)
      end
    end

    false
  end

  sig { params(decl: T.untyped).returns(T::Boolean) }
  def frame_backed_container?(decl)
    ti = type_of(decl)
    !!(ti.is_a?(Type) && (ti.string? || ti.array? || collection_type?(ti)))
  end

  sig { params(decl: T.untyped).returns(T::Boolean) }
  def heap_backed_container?(decl)
    return false unless decl
    return true if decl.respond_to?(:symbol) && decl.symbol&.heap_provenance?
    ti = type_of(decl)
    !!(ti.is_a?(Type) && inherent_heap_type?(ti))
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def heap_backed_container_expr?(node)
    return false unless node
    return true if node.respond_to?(:symbol) && node.symbol&.heap_provenance?
    ti = type_of(node)
    !!(ti.is_a?(Type) && inherent_heap_type?(ti))
  end

  sig { params(expr: T.untyped, blk: T.proc.params(arg0: AST::Identifier).void).void }
  def each_binding_ref(expr, &blk)
    return unless expr
    case expr
    when AST::Identifier
      blk.call(expr)
    when AST::MoveNode, AST::ShareNode
      each_binding_ref(expr.value, &blk)
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      return
    when AST::StructLit, AST::UnionVariantLit
      expr.fields.each_value { |v| each_binding_ref(v, &blk) }
    when AST::ListLit
      expr.items.each { |v| each_binding_ref(v, &blk) }
    when AST::BinaryOp
      if expr.op == :OR_RESCUE
        each_binding_ref(expr.left, &blk)
        each_binding_ref(expr.right, &blk)
      end
    when AST::GetField, AST::GetIndex
      return
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(String)) }
  def root_name(node)
    case node
    when String, Symbol then node.to_s
    when AST::Identifier then node.name.to_s
    when AST::GetField, AST::GetIndex then root_name(node.target)
    else nil
    end
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def root_decl_from(node)
    case node
    when AST::Identifier then node.symbol&.reg
    when AST::GetField, AST::GetIndex then root_decl_from(node.target)
    else nil
    end
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def walk_current_frame(node, &blk)
    return if node.nil?
    if node.is_a?(Array)
      node.each { |c| walk_current_frame(c, &blk) }
      return
    end
    return unless node.is_a?(Struct)
    blk.call(node)
    return if nested_frame?(node)
    expr_children(node).each { |child| walk_current_frame(child, &blk) }
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def walk_all(node, &blk)
    return if node.nil?
    if node.is_a?(Array)
      node.each { |c| walk_all(c, &blk) }
      return
    end
    return unless node.is_a?(Struct)
    blk.call(node)
    node.to_a.each { |child| walk_all(child, &blk) }
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def nested_frame?(node)
    node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach) ||
      node.is_a?(AST::WhileLoop) || node.is_a?(AST::WhileBindLoop) ||
      node.is_a?(AST::BgBlock) || node.is_a?(AST::BgStreamBlock) ||
      node.is_a?(AST::LambdaLit)
  end

  sig { params(node: T.untyped).returns(T::Array[T.untyped]) }
  def expr_children(node)
    case node
    when AST::IfStatement then [node.condition, node.then_branch, node.else_branch]
    when AST::ForRange then [node.start_expr, node.end_expr]
    when AST::ForEach then [node.collection]
    when AST::WhileLoop, AST::WhileBindLoop then [node.condition]
    when AST::MatchStatement
      bodies = node.cases.flat_map { |c| c.respond_to?(:body) ? c.body : [] }
      [node.expr, bodies, node.default_case]
    else node.to_a
    end.compact
  end

  sig { params(stmts: T.untyped).returns(T::Array[[T.untyped, T::Boolean]]) }
  def nested_scopes(stmts)
    out = T.let([], T::Array[[T.untyped, T::Boolean]])
    walk_current_frame(stmts) do |node|
      case node
      when AST::ForRange, AST::ForEach then out << [node.body, false]
      when AST::WhileLoop, AST::WhileBindLoop then out << [node.do_branch, false]
      when AST::BgBlock, AST::BgStreamBlock then out << [node.body, true]
      when AST::LambdaLit then out << [node.body, true]
      end
    end
    out
  end

  sig { params(body: T.untyped).returns(T::Array[T.untyped]) }
  def return_values(body)
    vals = T.let([], T::Array[T.untyped])
    walk_all(body) { |n| vals << n.value if n.is_a?(AST::ReturnNode) && n.value }
    vals
  end
end
