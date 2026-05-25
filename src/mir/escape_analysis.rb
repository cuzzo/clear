# typed: strict
# Dead-simple escape placement plus caller sync propagation.
#
# Escape placement is intentionally AST-bound: each escape mechanism is a
# local node predicate and the only output is SymbolEntry#storage = :heap.

require "sorbet-runtime"

require_relative "../ast/type"
require_relative "../ast/ast"
require_relative "../annotator-helpers/function_signature"
require_relative "local_binding_facts"

module EscapeAnalysis
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  HeapResult = T.type_alias { [T::Set[String], T::Set[String]] }

  sig { params(fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(HeapResult) }
  def self.apply!(fn_nodes, schema_lookup = nil)
    propagate_caller_sync!(fn_nodes)

    heap_fns = T.let(Set.new, T::Set[String])
    bg_heap = T.let(Set.new, T::Set[String])

    fn_nodes.each_value do |fn|
      mark_heap_return_facts!(fn, schema_lookup) if fn.body
    end

    fn_nodes.each_value do |fn|
      mark_param_receiver_allocations_heap!(fn.body) if fn.body
      mark_recursive_aggregate_owners_heap!(fn, schema_lookup) if fn.body
    end

    fn_nodes.each do |name, fn|
      next unless fn.body
      before = heap_symbol_count(fn)
      mark_body_escapes!(fn, fn_nodes, bg_heap, schema_lookup)
      mark_loop_receiver_allocations_heap!(fn.body)
      propagate_assignment_ownership!(fn, fn_nodes, schema_lookup)
      propagate_hoist_dependencies!(fn, schema_lookup)
      heap_fns << name if heap_symbol_count(fn) > before
    end

    [heap_fns, bg_heap]
  end

  # E3c: Propagate caller arg sync (and Arc-storage) into callee param
  # SymbolEntry. Two axes flow with the same all-callers-agree rule:
  #   - sync     (:locked / :write_locked / :always_mutable)
  #   - storage  (:shared / :multiowned for Arc/Rc-wrapped bindings)
  # The storage axis is what mir_lowering needs to emit Arc unwrap
  # (`x.ctrl.data.*` vs `x`) at WITH/field-access sites. Sync drives the
  # acquire/release method choice. Runs to fixed point so transitive calls
  # also pick up both axes.
  #
  # Rule: a param with no caller-derived value (and no explicit declared
  # value) adopts a caller's value iff every observed caller passes the
  # same non-nil value. Disagreement leaves the param at its current
  # value. Params with declared sync (legacy) are not overwritten.
  #
  # @param fn_nodes [Hash]  name -> AST::FunctionDef
  sig { params(fn_nodes: FnNodes).void }
  def self.propagate_caller_sync!(fn_nodes)
    return if fn_nodes.empty?

    # Index callsites: callee_name => [{ args: }, ...].
    # AST.walk_body only visits top-level statements, not expression
    # sub-trees, so a `let x = foo(...)` would miss the FuncCall. Walk
    # every Locatable descendant.
    callsites = Hash.new { |h, k| h[k] = [] }
    fn_nodes.each do |_, caller_fn|
      next unless caller_fn&.body
      collect_callsites_deep(caller_fn.body, callsites)
    end

    max_iters = 8
    max_iters.times do
      changed = T.let(false, T::Boolean)
      fn_nodes.each do |callee_name, callee_fn|
        next unless callee_fn&.params
        sites = callsites[callee_name]
        next if sites.empty?

        callee_fn.params.each_with_index do |param, idx|
          entry = param.symbol
          next unless entry

          # ── sync axis ────────────────────────────────────────────────
          unless entry.sync && param_sync_was_declared?(param)
            unified = unify_caller_attr(sites, idx) do |s|
              next s.sync if s&.sync
              t = s&.type
              t.is_a?(Type) ? t.sync : nil
            end
            if unified && entry.sync != unified && param_accepts_caller_sync?(callee_fn, param, unified)
              entry.sync = unified
              changed = true
            end
          end

          # ── storage axis (Arc / Rc) ──────────────────────────────────
          # We're trying to detect "this binding is Arc/Rc-wrapped" so
          # the callee's lowering knows to emit `x.ctrl.data.*` unwrap.
          # For struct types, that fact lives on entry.storage (:shared /
          # :multiowned). For collection types, finalize_storage maps
          # @shared:locked + collection to :heap, so the wrapping fact
          # lives on entry.type.ownership instead. Check both axes.
          unified_storage = unify_caller_attr(sites, idx) do |s|
            next s.storage if s&.rc_stored?
            t = s&.type
            if t.is_a?(Type)
              next :shared     if t.respond_to?(:shared?)     && t.shared?
              next :multiowned if t.respond_to?(:multiowned?) && t.multiowned?
            end
            nil
          end
          if unified_storage && entry.storage != unified_storage
            entry.storage = unified_storage
            changed = true
          end
        end
      end
      break unless changed
    end
  end

  # Walk every Locatable descendant (incl. expression sub-trees), record
  # FuncCalls.
  sig { params(body: T::Array[T.untyped], callsites: T::Hash[String, T::Array[T.untyped]]).returns(NilClass) }
  private_class_method def self.collect_callsites_deep(body, callsites)
    AST.each_locatable(body) do |node|
      if node.is_a?(AST::FuncCall)
        T.must(callsites[node.name.to_s]) << { args: node.args }
      end
    end
    nil
  end

  # Most-general unifier: returns the single non-nil value when every
  # callsite's arg projects to the same value, else nil.
  sig { params(sites: T::Array[T::Hash[T.untyped, T.untyped]], idx: Integer, project: T.untyped).returns(T.nilable(Symbol)) }
  private_class_method def self.unify_caller_attr(sites, idx, &project)
    observed = sites.map do |site|
      arg = site[:args][idx]
      next nil unless arg && arg.respond_to?(:symbol)
      project.call(arg.symbol)
    end
    return nil if observed.empty?
    unique = observed.uniq
    (unique.length == 1 && unique.first) ? unique.first : nil
  end

  # True when the param's declared type carried explicit sync (so the
  # entry.sync currently reflects an annotation, not a propagated value).
  sig { params(param: AST::Param).returns(T.nilable(T::Boolean)) }
  private_class_method def self.param_sync_was_declared?(param)
    t = param.type
    t.is_a?(Type) && t.any_sync?
  end

  sig { params(fn_node: AST::FunctionDef, param: AST::Param, sync: Symbol).returns(T::Boolean) }
  private_class_method def self.param_accepts_caller_sync?(fn_node, param, sync)
    t = param.type
    return true if t.is_a?(Type) && (t.shared? || t.any_sync?)
    # Sync axes other than :atomic were already accepted above (via shared?
    # / any_sync?) -- only :atomic needs the REQUIRES family check.
    return true unless SymbolEntry.atomic_sync?(sync)

    requires = fn_node.respond_to?(:requires) ? fn_node.requires : nil
    families = requires && requires[param.name.to_s]
    return false unless families.respond_to?(:include?)
    families.include?(:ATOMIC) || families.include?(:SNAPSHOTTED)
  end

  sig { params(fn: AST::FunctionDef).returns(Integer) }
  private_class_method def self.heap_symbol_count(fn)
    count = T.let(0, Integer)
    fn.params.each { |param| count += 1 if symbol_heap?(param.symbol) }
    walk_body(fn.body) do |node|
      sym = symbol_for_binding_node(node)
      count += 1 if symbol_heap?(sym)
    end
    count
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes, bg_heap: T::Set[String], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_body_escapes!(fn, fn_nodes, bg_heap, schema_lookup)
    walk_body(fn.body) do |node|
      case node
      when AST::ReturnNode
        if owning_return_needs_heap_placement?(fn, node.value, schema_lookup)
          mark_expr_identifiers_heap!(node.value)
          mark_heap_return!(fn, node.value)
        end
      when AST::Assignment
        mark_expr_identifiers_heap!(node.value) if heap_destination?(fn, node.name)
      when AST::VarDecl, AST::BindExpr
        if borrow_return_expr?(node.value)
          mark_symbol_borrow!(node.symbol)
        elsif call_result_is_heap?(node.value, fn_nodes, schema_lookup)
          mark_symbol_heap!(node.symbol)
        end
      when AST::BgBlock, AST::BgStreamBlock
        mark_capture_analysis_heap!(node.capture_analysis, bg_heap)
        mark_fsm_ctx_locals_heap!(node, schema_lookup) if node.is_a?(AST::BgBlock)
      when AST::LambdaLit
        mark_lambda_captures_heap!(node, bg_heap)
      when AST::FuncCall
        mark_takes_args_heap!(node.args, params_for_call(node, fn_nodes), schema_lookup)
      when AST::MethodCall
        mark_method_takes_heap!(node, params_for_method_call(node), fn_nodes, schema_lookup)
      end
    end
  end

  sig { params(body: T::Array[T.untyped]).void }
  private_class_method def self.mark_param_receiver_allocations_heap!(body)
    walk_body(body) do |node|
      case node
      when AST::MethodCall
        sig = node.respond_to?(:matched_signature) ? FunctionSignature.unwrap(node.matched_signature) : nil
        emit = sig&.emit
        next unless emit&.allocates && emit&.mutates_receiver
        root = AST.root_identifier(node.object)
      when AST::Assignment
        next unless node.name.is_a?(AST::GetIndex)
        root = AST.root_identifier(node.name)
        ti = root&.symbol&.type
        next unless ti.is_a?(Type) && ti.collection?
      else
        next
      end
      sym = root&.symbol
      next unless sym&.is_param
      mark_symbol_heap!(sym)
    end
  end

  sig { params(fn: AST::FunctionDef, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_recursive_aggregate_owners_heap!(fn, schema_lookup)
    fn.params.each do |param|
      next unless aggregate_owner_requires_heap?(Type.from_node(param.type), schema_lookup)
      mark_symbol_heap!(param.symbol)
    end

    walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
      ti = Type.from_node(node.full_type)
      ti = Type.from_node(node.value) unless ti
      next unless aggregate_owner_requires_heap?(ti, schema_lookup)
      mark_symbol_heap!(node.symbol)
    end
  end

  sig { params(ti: T.nilable(Type), schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.aggregate_owner_requires_heap?(ti, schema_lookup)
    return false unless ti
    t = ti.value_payload_type
    return false unless t
    return false if t.rodata? || t.provenance == :borrow

    if t.collection? || (t.array? && !t.string?)
      elem = t.element_type
      return false unless elem.is_a?(Type)
      return type_contains_cleanup_payload?(elem, schema_lookup)
    end

    return false if t.string? || t.heap_ptr?
    type_contains_cleanup_payload?(t, schema_lookup)
  rescue StandardError
    false
  end

  sig { params(body: T::Array[T.untyped]).void }
  private_class_method def self.mark_loop_receiver_allocations_heap!(body)
    body.each do |stmt|
      AST.child_bodies(stmt).each do |child_body|
        mark_receiver_allocations_in_loop!(child_body) if AST.loop_node?(stmt)
        mark_loop_receiver_allocations_heap!(child_body)
      end
    end
  end

  sig { params(body: T::Array[T.untyped]).void }
  private_class_method def self.mark_receiver_allocations_in_loop!(body)
    local_names = MIR::LocalBindingAnalysis.direct_loop_body_facts(body).names
    MIR::LocalBindingAnalysis.each_direct_loop_node(body) do |node|
      case node
      when AST::MethodCall
        sig = node.respond_to?(:matched_signature) ? FunctionSignature.unwrap(node.matched_signature) : nil
        emit = sig&.emit
        next unless emit&.allocates && emit&.mutates_receiver
        root = AST.root_identifier(node.object)
        value_params = sig ? sig.params.drop(1) : []
      when AST::Assignment
        next unless node.name.is_a?(AST::GetIndex)
        root = AST.root_identifier(node.name)
        ti = root&.symbol&.type
        next unless ti.is_a?(Type) && ti.collection?
        value_params = []
      else
        next
      end
      next unless root&.symbol
      next if local_names.include?(root.name.to_s)
      mark_symbol_heap!(root.symbol)
      if node.is_a?(AST::MethodCall)
        value_params.each_with_index do |param, idx|
          next unless param.takes || param.mutable
          arg = node.args[idx]
          mark_expr_identifiers_heap!(arg) if arg
        end
      end
    end
  end

  sig { params(body: T::Array[T.untyped], blk: T.proc.params(arg0: T.untyped).void).void }
  private_class_method def self.walk_body(body, &blk)
    AST.each_locatable(body, &blk)
  end

  sig { params(expr: T.untyped).void }
  private_class_method def self.mark_expr_roots_heap!(expr)
    root = AST.root_identifier(unwrap_value(expr))
    if root
      mark_symbol_heap!(root.symbol)
      return
    end

    node = unwrap_value(expr)
    mark_symbol_heap!(node.symbol) if node.is_a?(AST::Identifier)
  end

  sig { params(expr: T.untyped).void }
  private_class_method def self.mark_expr_identifiers_heap!(expr)
    stack = T.let([expr], T::Array[T.untyped])
    until stack.empty?
      node = stack.pop
      next if node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode)
      node = unwrap_value(node)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        mark_symbol_heap!(node.symbol)
        next
      end
      root = AST.root_identifier(node)
      if root
        mark_symbol_heap!(root.symbol)
        next
      end
      AST.wrapped_children(node).each { |child| stack << child if child.is_a?(AST::Locatable) }
      node.class.members.each do |member|
        value = node[member]
        if value.is_a?(Array)
          value.each { |child| stack << child if child.is_a?(AST::Locatable) }
        elsif value.is_a?(Hash)
          value.each_value { |child| stack << child if child.is_a?(AST::Locatable) }
        elsif value.is_a?(AST::Locatable)
          stack << value
        end
      end
    end
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  private_class_method def self.unwrap_value(node)
    current = T.let(node, T.untyped)
    while current.is_a?(AST::MoveNode) || current.is_a?(AST::CopyNode) || current.is_a?(AST::CloneNode) ||
          current.is_a?(AST::ShareNode) || current.is_a?(AST::FreezeNode) || current.is_a?(AST::CapabilityWrap)
      current = current.value
    end
    current
  end

  sig { params(analysis: T.untyped, bg_heap: T::Set[String]).void }
  private_class_method def self.mark_capture_analysis_heap!(analysis, bg_heap)
    return unless analysis
    symbols = analysis.respond_to?(:capture_symbols) ? analysis.capture_symbols : nil
    return unless symbols.respond_to?(:each)
    symbols.each do |name, sym|
      mark_symbol_heap!(sym, bg_heap, name.to_s)
    end
  end

  sig { params(node: AST::BgBlock, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_fsm_ctx_locals_heap!(node, schema_lookup)
    return unless node.spawn_form == :fsm
    walk_body(node.body) do |child|
      next unless child.is_a?(AST::VarDecl) || (child.is_a?(AST::BindExpr) && child.mode == :decl)
      ti = Type.from_node(child.full_type)
      ti = ti.success_type if ti
      next unless ti&.heap_ptr? || ti&.recursive_cleanup_shape?(schema_lookup)
      mark_symbol_heap!(child.symbol)
    end
  end

  sig { params(args: T::Array[T.untyped], params: T::Array[AST::Param], schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_takes_args_heap!(args, params, schema_lookup)
    params.each_with_index do |param, idx|
      arg = args[idx]
      next unless arg
      next unless param.takes || symbol_heap?(param.symbol)
      arg_type = Type.from_node(arg)
      next unless ownership_bearing_transfer_expr?(arg, schema_lookup) ||
                  type_requires_owned_storage?(arg_type, schema_lookup)
      mark_expr_roots_heap!(arg)
    end
  end

  sig { params(call: AST::MethodCall, params: T::Array[AST::Param], fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_method_takes_heap!(call, params, fn_nodes, schema_lookup)
    receiver_param = params.first
    if receiver_is_param?(call.object) && symbol_heap?(receiver_param&.symbol)
      mark_expr_roots_heap!(call.object)
    end

    value_params = params.drop(1)
    mark_takes_args_heap!(call.args, value_params, schema_lookup)
    mark_receiver_for_owned_sink!(call.object, call.args, value_params, fn_nodes, schema_lookup)
    mark_receiver_scope_escapes!(call.object, call.args, value_params)
  end

  sig { params(receiver: T.untyped, args: T::Array[T.untyped], params: T::Array[AST::Param], fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_receiver_for_owned_sink!(receiver, args, params, fn_nodes, schema_lookup)
    receiver_root = AST.root_identifier(receiver)
    receiver_sym = receiver_root&.symbol
    return unless receiver_sym

    params.each_with_index do |param, idx|
      next unless param.takes
      arg = args[idx]
      next unless ownership_bearing_transfer_expr?(arg, schema_lookup) ||
                  call_result_is_heap?(arg, fn_nodes, schema_lookup)
      mark_symbol_heap!(receiver_sym)
      return
    end
  end

  sig { params(arg: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.ownership_bearing_transfer_expr?(arg, schema_lookup)
    if arg.is_a?(AST::MoveNode)
      return type_requires_owned_storage?(Type.from_node(arg.value), schema_lookup)
    end
    return true if heap_owned_transfer_source?(arg)
    return true if ownership_transferring_expr?(arg, include_allocating_expr: true) &&
                   type_requires_owned_storage?(Type.from_node(arg), schema_lookup)
    false
  rescue StandardError
    false
  end

  sig { params(arg: T.untyped).returns(T::Boolean) }
  private_class_method def self.heap_owned_transfer_source?(arg)
    return false if arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode)
    root = AST.root_identifier(unwrap_value(arg))
    sym = root&.symbol
    symbol_heap?(sym)
  rescue StandardError
    false
  end

  sig { params(receiver: T.untyped, args: T::Array[T.untyped], params: T::Array[AST::Param]).void }
  private_class_method def self.mark_receiver_scope_escapes!(receiver, args, params)
    receiver_root = AST.root_identifier(receiver)
    receiver_depth = receiver_root&.symbol&.scope_depth
    return unless receiver_depth.is_a?(Integer)

    params.each_with_index do |param, idx|
      next unless param.takes || param.mutable
      arg = args[idx]
      arg_root = AST.root_identifier(arg)
      arg_depth = arg_root&.symbol&.scope_depth
      next unless arg_depth.is_a?(Integer) && arg_depth > receiver_depth
      mark_expr_identifiers_heap!(arg)
    end
  end

  sig { params(fn: AST::FunctionDef, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.propagate_hoist_dependencies!(fn, schema_lookup)
    bindings = T.let({}, T::Hash[String, T.untyped])
    walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
      next unless node.name
      bindings[node.name.to_s] = node.value
    end

    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      bindings.each do |name, value|
        sym = symbol_for_name(fn, name)
        next unless symbol_heap?(sym)
        next unless heap_binding_carries_sources?(value)
        before = heap_symbol_count(fn)
        mark_expr_identifiers_heap!(value)
        changed = true if heap_symbol_count(fn) > before
      end
    end
  end

  sig { params(value: T.untyped).returns(T::Boolean) }
  private_class_method def self.heap_binding_carries_sources?(value)
    node = value
    return false if node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode)
    node = unwrap_value(node)
    return true if node.is_a?(AST::Identifier)
    return true if node.is_a?(AST::StructLit) || node.is_a?(AST::UnionVariantLit) ||
                   node.is_a?(AST::ListLit) || node.is_a?(AST::HashLit)
    false
  end

  sig { params(fn: AST::FunctionDef, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.propagate_assignment_ownership!(fn, fn_nodes, schema_lookup)
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      walk_body(fn.body) do |node|
        target = assigned_binding_name(node)
        next unless target
        sym = symbol_for_name(fn, target)
        next unless sym
        next unless assignment_value_is_owned?(node, fn_nodes, schema_lookup)
        changed = true if mark_reassigned_symbol_heap!(sym)
      end
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(String)) }
  private_class_method def self.assigned_binding_name(node)
    if node.is_a?(AST::BindExpr) && node.mode == :assign
      return node.name.to_s
    end
    return nil unless node.is_a?(AST::Assignment)
    target = unwrap_value(node.name)
    return target.name.to_s if target.is_a?(AST::Identifier)
    root = AST.root_identifier(target)
    return root.name.to_s if root
    nil
  end

  sig { params(node: T.untyped, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.assignment_value_is_owned?(node, fn_nodes, schema_lookup)
    return false unless node.respond_to?(:value)
    value = node.value
    return true if ownership_transferring_expr?(value, include_allocating_expr: false)
    return false if string_concat_expr?(unwrap_value(value))
    return true if expr_has_owned_inline_value?(value)
    target_type = Type.from_node(node.name) rescue Type.from_node(node) rescue nil
    return true if type_requires_owned_storage?(target_type, schema_lookup) &&
                   call_result_is_heap?(value, fn_nodes, schema_lookup)
    false
  end

  sig { params(expr: T.untyped, include_allocating_expr: T::Boolean).returns(T::Boolean) }
  private_class_method def self.ownership_transferring_expr?(expr, include_allocating_expr:)
    value = unwrap_value(expr)
    value = unwrap_value(value.left) if value.is_a?(AST::BinaryOp) && value.op == :OR_RESCUE
    return true if value.is_a?(AST::CopyNode) || value.is_a?(AST::CloneNode)
    return true if expr_has_heap_identifier?(value)
    return true if include_allocating_expr && string_concat_expr?(value)
    return true if value.respond_to?(:heap_storage?) && value.heap_storage?
    return true if value.respond_to?(:symbol) && value.symbol&.heap_storage?
    ti = Type.from_node(value)
    !!(ti && !ti.string? && !ti.rodata? && ti.provenance != :borrow && ti.heap_ptr?)
  rescue StandardError
    false
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.string_concat_expr?(expr)
    expr.is_a?(AST::StringConcat) ||
      (expr.is_a?(AST::BinaryOp) && expr.op == :ADD && expr.string_concat == true)
  end

  sig { params(ti: T.nilable(Type), schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.type_requires_owned_storage?(ti, schema_lookup)
    return false unless ti
    t = ti.success_type
    return false unless t
    return false if t.rodata? || t.provenance == :borrow
    t.heap_ptr? ||
      t.recursive_cleanup_shape?(schema_lookup) ||
      t.needs_explicit_cleanup?(:heap, schema_lookup) ||
      type_contains_cleanup_payload?(t, schema_lookup)
  rescue StandardError
    false
  end

  sig { params(ti: Type, schema_lookup: T.nilable(Proc), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  private_class_method def self.type_contains_cleanup_payload?(ti, schema_lookup, seen = nil)
    t = ti.success_type
    return false unless t
    return true if t.string? && !t.rodata? && t.provenance != :borrow
    return true if t.needs_explicit_cleanup?(:heap, schema_lookup)
    if t.array? && !t.string?
      elem = t.element_type
      return false unless elem.is_a?(Type)
      return type_contains_cleanup_payload?(elem, schema_lookup, seen)
    end
    return false unless schema_lookup
    key = t.resolved.to_s
    seen ||= Set.new
    return false unless seen.add?(key)
    schema = schema_lookup.call(t.resolved) rescue nil
    if Schemas.union?(schema)
      return (schema.variants || {}).any? do |_name, vt|
        vt.is_a?(Type) && type_contains_cleanup_payload?(vt, schema_lookup, seen)
      end
    end
    return false unless Schemas.field_bearing?(schema)
    schema.fields.any? do |_name, field|
      ft = field.is_a?(AST::StructField) ? field.type : field
      ft.is_a?(Type) && type_contains_cleanup_payload?(ft, schema_lookup, seen)
    end
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.borrow_return_expr?(expr)
    call = unwrap_value(expr)
    return false unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    !!sig && !sig.return_lifetime.empty?
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.expr_has_heap_identifier?(expr)
    found = T.let(false, T::Boolean)
    AST.each_locatable(expr) do |raw|
      node = unwrap_value(raw)
      if node.is_a?(AST::Identifier)
        found = true if symbol_heap?(node.symbol)
      end
    end
    found
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.expr_has_owned_inline_value?(expr)
    root = unwrap_value(expr)
    AST.each_locatable(expr) do |raw|
      node = unwrap_value(raw)
      next unless node.is_a?(AST::Locatable)
      is_root = node.equal?(root)
      unless is_root || node.is_a?(AST::Identifier)
        return true if node.is_a?(AST::Literal) && node.value.is_a?(String)
        ti = Type.from_node(node)
        return true if ti && !ti.rodata? && ti.provenance != :borrow &&
                       ti.heap_ptr?
      end
    end
    false
  rescue StandardError
    false
  end

  sig { params(fn: AST::FunctionDef, name: String).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.symbol_for_name(fn, name)
    found = T.let(nil, T.nilable(SymbolEntry))
    fn.params.each do |param|
      found = param.symbol if param.name.to_s == name
    end
    walk_body(fn.body) do |node|
      next if found
      sym = symbol_for_binding_node(node)
      found = sym if sym && node.respond_to?(:name) && node.name.to_s == name
    end
    found
  end

  sig { params(receiver: T.untyped).returns(T::Boolean) }
  private_class_method def self.receiver_is_param?(receiver)
    root = AST.root_identifier(receiver)
    sym = root&.symbol
    !!(sym && sym.respond_to?(:is_param) && sym.is_param)
  end

  sig { params(node: AST::LambdaLit, bg_heap: T::Set[String]).void }
  private_class_method def self.mark_lambda_captures_heap!(node, bg_heap)
    names = T.let(Set.new, T::Set[String])
    node.captures.each { |capture| names << capture.name.to_s }
    return if names.empty?

    body = node.body.is_a?(Array) ? node.body : [node.body]
    walk_body(body) do |child|
      next unless child.is_a?(AST::Identifier)
      next unless names.include?(child.name.to_s)
      mark_symbol_heap!(child.symbol, bg_heap, child.name.to_s)
    end
  end

  sig { params(call: AST::FuncCall, fn_nodes: FnNodes).returns(T::Array[AST::Param]) }
  private_class_method def self.params_for_call(call, fn_nodes)
    fn = fn_nodes[call.name.to_s]
    return fn.params if fn
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    sig ? sig.params : []
  end

  sig { params(call: AST::MethodCall).returns(T::Array[AST::Param]) }
  private_class_method def self.params_for_method_call(call)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    sig ? sig.params : []
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.borrowed_return?(fn, expr)
    return false unless fn.return_lifetime
    returned = T.let(Set.new, T::Set[String])
    collect_identifier_names!(expr, returned)
    if fn.return_lifetime == :wildcard
      param_names = T.let(Set.new, T::Set[String])
      fn.params.each { |param| param_names << param.name.to_s }
      return !(returned & param_names).empty?
    end
    borrowed = T.let(Set.new, T::Set[String])
    Array(fn.return_lifetime).each do |source|
      borrowed << source.name.to_s if source.respond_to?(:name)
    end
    !(returned & borrowed).empty?
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.owning_return_needs_heap_placement?(fn, expr, schema_lookup)
    return false if borrowed_return?(fn, expr)
    ti = owning_return_type(fn, expr)
    return false unless ti
    top_heap_ptr = ti.heap_ptr?
    ti = ti.value_payload_type
    return false unless ti
    return false if ti.primitive? || ti.void? || ti.any?
    if expr.is_a?(AST::Identifier) && expr.symbol
      symbol = expr.symbol
      decl = symbol.respond_to?(:reg) ? symbol.reg : nil
      mutated = decl.respond_to?(:var_mutated) && decl.var_mutated == true
      return false if (symbol&.rodata_provenance? && !mutated) || symbol&.borrow_provenance?
    end
    if expr.is_a?(AST::Identifier) && symbol_heap?(expr.symbol)
      return true if ti.string? || ti.heap_ptr? || ti.recursive_cleanup_shape?(schema_lookup)
    end
    expr_t = Type.from_node(expr)
    return false if !expr.is_a?(AST::Identifier) && (expr_t&.rodata? || expr_t&.provenance == :borrow)
    return false if ti.rodata? || ti.provenance == :borrow
    ti.string? || top_heap_ptr || ti.heap_ptr? || ti.resource? || ti.ownership != :affine ||
      ti.recursive_cleanup_shape?(schema_lookup) ||
      ti.needs_cleanup?(schema_lookup) ||
      ti.needs_explicit_cleanup?(:heap, schema_lookup) ||
      type_contains_cleanup_payload?(ti, schema_lookup)
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped).returns(T.nilable(Type)) }
  private_class_method def self.owning_return_type(fn, expr)
    declared = Type.from_node(fn.return_type)
    declared || Type.from_node(expr)
  end

  sig { params(fn: AST::FunctionDef, expr: T.untyped).void }
  private_class_method def self.mark_heap_return!(fn, expr)
    ret = fn.return_type
    ret = ret.value_payload_type if ret.is_a?(Type)
    ret.provenance = :heap if ret.respond_to?(:provenance=)
    fn.heap_carry_return = true if fn.respond_to?(:heap_carry_return=)

    names = T.let(Set.new, T::Set[String])
    collect_identifier_names!(expr, names)
    return if names.empty?
    fn.heap_carry_return_vars ||= Set.new if fn.respond_to?(:heap_carry_return_vars)
    names.each { |name| fn.heap_carry_return_vars << name } if fn.respond_to?(:heap_carry_return_vars)
    mark_decl_symbols_heap_by_name!(fn.body, names)
  end

  sig { params(body: T::Array[T.untyped], names: T::Set[String]).void }
  private_class_method def self.mark_decl_symbols_heap_by_name!(body, names)
    walk_body(body) do |node|
      next unless (node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)) && names.include?(node.name.to_s)
      mark_symbol_heap!(node.symbol)
    end
  end

  sig { params(fn: AST::FunctionDef, schema_lookup: T.nilable(Proc)).void }
  private_class_method def self.mark_heap_return_facts!(fn, schema_lookup)
    walk_body(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value
      mark_heap_return!(fn, node.value) if owning_return_needs_heap_placement?(fn, node.value, schema_lookup)
    end
  end

  sig { params(expr: T.untyped, names: T::Set[String]).void }
  private_class_method def self.collect_identifier_names!(expr, names)
    stack = T.let([expr], T::Array[T.untyped])
    until stack.empty?
      node = unwrap_value(stack.pop)
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::Identifier)
        names << node.name.to_s
        next
      end
      AST.wrapped_children(node).each { |child| stack << child if child.is_a?(AST::Locatable) }
      node.class.members.each do |member|
        value = node[member]
        if value.is_a?(Array)
          value.each { |child| stack << child if child.is_a?(AST::Locatable) }
        elsif value.is_a?(Hash)
          value.each_value { |child| stack << child if child.is_a?(AST::Locatable) }
        elsif value.is_a?(AST::Locatable)
          stack << value
        end
      end
    end
  end

  sig { params(fn: AST::FunctionDef, target: T.untyped).returns(T::Boolean) }
  private_class_method def self.heap_destination?(fn, target)
    root = AST.root_identifier(target)
    return false unless root
    return true if symbol_heap?(root.symbol)
    sym = symbol_for_name(fn, root.name.to_s)
    symbol_heap?(sym)
  end

  sig { params(value: T.untyped, fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.call_result_is_heap?(value, fn_nodes, schema_lookup)
    call = unwrap_value(value)
    call = unwrap_value(call.left) if call.is_a?(AST::BinaryOp) && call.op == :OR_RESCUE
    return false unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
    callee = fn_nodes[call.name.to_s]
    return false if callee && function_def_has_return_lifetime?(callee)
    return call_result_is_heap_for_callee?(call, callee, schema_lookup) if callee

    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    return false unless sig
    return false unless sig.return_lifetime.empty?
    dep = signature_heap_return_from_args?(call, sig)
    return dep unless dep.nil?

    return true if sig.respond_to?(:heap_carry_return) && sig.heap_carry_return == true
    return true if sig.heap_return_alloc?
    false
  end

  sig { params(call: T.untyped, callee: AST::FunctionDef, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.call_result_is_heap_for_callee?(call, callee, schema_lookup)
    dep = heap_return_from_args?(call.args, callee.params, callee.heap_carry_return_vars, callee.return_type, schema_lookup)
    return dep unless dep.nil?

    callee.heap_carry_return == true || body_has_heap_return_binding?(callee.body)
  end

  sig { params(call: T.untyped, sig_obj: FunctionSignature).returns(T.nilable(T::Boolean)) }
  private_class_method def self.signature_heap_return_from_args?(call, sig_obj)
    heap_return_from_args?(call.args, sig_obj.params, sig_obj.heap_carry_return_vars, sig_obj.return_type, nil)
  end

  sig { params(args: T::Array[T.untyped], params: T::Array[AST::Param], returned_names: T.untyped, return_type: T.untyped, schema_lookup: T.nilable(Proc)).returns(T.nilable(T::Boolean)) }
  private_class_method def self.heap_return_from_args?(args, params, returned_names, return_type = nil, schema_lookup = nil)
    return nil unless returned_names && !returned_names.empty?
    by_name = T.let({}, T::Hash[String, Integer])
    params.each_with_index { |param, idx| by_name[param.name.to_s] = idx }
    has_param_return = T.let(false, T::Boolean)
    returned_names.each do |name|
      idx = by_name[name.to_s]
      unless idx
        return true
      end
      has_param_return = true
      arg = args[idx]
      return true if expr_produces_heap?(arg)
    end
    if has_param_return
      ret = Type.from_node(return_type)
      ret = ret.success_type if ret
      return true if ret&.string? || ret&.recursive_cleanup_shape?(schema_lookup)
      return false
    end
    nil
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.expr_produces_heap?(expr)
    node = unwrap_value(expr)
    node = unwrap_value(node.left) if node.is_a?(AST::BinaryOp) && node.op == :OR_RESCUE
    return false if node.respond_to?(:storage) && [:rodata, :borrow].include?(node.storage)
    return false if node.respond_to?(:rodata_provenance?) && node.rodata_provenance?
    return false if node.respond_to?(:borrow_provenance?) && node.borrow_provenance?
    return true if node.respond_to?(:heap_storage?) && node.heap_storage?
    return true if node.respond_to?(:symbol) && node.symbol&.heap_storage?
    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.op == :ADD && node.string_concat
    ti = Type.from_node(node)
    return false unless ti
    ti.heap_ptr? || ti.recursive_cleanup_shape?(nil)
  end

  sig { params(fn: AST::FunctionDef).returns(T::Boolean) }
  private_class_method def self.function_def_has_return_lifetime?(fn)
    rl = fn.return_lifetime
    return false if rl.nil?
    return true if rl == :wildcard
    !Array(rl).empty?
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Boolean) }
  private_class_method def self.body_has_heap_return_binding?(body)
    found = T.let(false, T::Boolean)
    walk_body(body) do |node|
      next unless node.is_a?(AST::ReturnNode)
      found = true if expr_has_heap_identifier?(node.value)
    end
    found
  end

  sig { params(node: T.untyped).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.symbol_for_binding_node(node)
    return node.symbol if (node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)) && node.respond_to?(:symbol)
    nil
  end

  sig { params(sym: T.nilable(SymbolEntry), names: T.nilable(T::Set[String]), name: T.nilable(String)).returns(T::Boolean) }
  private_class_method def self.mark_symbol_heap!(sym, names = nil, name = nil)
    sym_entry = canonical_symbol(sym)
    return false unless sym_entry
    return false if sym_entry.heap_storage? || sym_entry.borrow_provenance?
    sym_entry.storage = :heap
    names << name if names && name
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.mark_symbol_borrow!(sym)
    sym_entry = canonical_symbol(sym)
    return false unless sym_entry
    return false if sym_entry.heap_storage? || sym_entry.borrow_provenance?
    sym_entry.storage = :borrow
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.mark_reassigned_symbol_heap!(sym)
    sym_entry = canonical_symbol(sym)
    return false unless sym_entry
    return false if sym_entry.heap_storage? || sym_entry.borrow_provenance?
    sym_entry.storage = :heap
    true
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T.nilable(SymbolEntry)) }
  private_class_method def self.canonical_symbol(sym)
    return nil unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
  end

  sig { params(sym: T.nilable(SymbolEntry)).returns(T::Boolean) }
  private_class_method def self.symbol_heap?(sym)
    canonical_symbol(sym)&.heap_storage? == true
  end
end
