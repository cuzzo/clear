# typed: strict
require "sorbet-runtime"
require_relative "../../ast/lexer"
require_relative "../../backends/zig_type"
require_relative "../../compiler/entrypoint"
require_relative "../../semantic/capability_plan"

module MIRLoweringCapabilities
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  SYNC_WRAP_CONSTRUCTORS = T.let({
    locked: "lockedCreate",
    write_locked: "rwLockedCreate",
    always_mutable: "refCellCreate",
    versioned: "versionedCreate",
    atomic: "atomicCreate",
    atomic_ptr: "atomicPtrCreate",
    local: nil,
  }.freeze, T::Hash[Symbol, T.nilable(String)])

  SYNC_WRAP_TYPES = T.let({
    locked: "CheatLib.Locked",
    write_locked: "CheatLib.RwLocked",
    always_mutable: "CheatLib.RefCell",
    versioned: "CheatLib.Versioned",
    atomic: "CheatLib.Atomic",
    atomic_ptr: "CheatLib.AtomicPtr",
    local: nil,
  }.freeze, T::Hash[Symbol, T.nilable(String)])

  CapabilitySpec = T.type_alias { CapabilityPlan::CapabilityTransition }
  CapabilityVarNode = T.type_alias { T.any(AST::Identifier, AST::GetField, AST::GetIndex) }
  FieldPathNode = T.type_alias { T.any(AST::Identifier, AST::GetField) }
  AstReturnSearchNode = T.type_alias do
    T.nilable(T.any(
      AST::Node,
      AST::RawBody,
      Lexer::Token,
      T::Hash[BasicObject, BasicObject],
      Symbol,
      String,
      Integer,
      Float,
      TrueClass,
      FalseClass,
      Type,
    ))
  end
  WithBindingNode = T.type_alias { T.any(String, MIR::Emittable, T::Array[MIR::Emittable]) }

  class FallibleClauseFact < T::Struct
    const :var_name, String
    const :alias_name, String
    const :action_kind, AST::ErrorActionKind
    const :retries, T.nilable(Integer)
    const :matched_types, T::Array[Symbol]
    const :bubble_types, T::Array[Symbol]
    const :action_mir, T::Array[MIR::Emittable], default: []
    const :exit_msg_mir, T.nilable(MIR::Emittable)
  end

  class WithCapabilityBindingContext < T::Struct
    const :node, AST::WithBlock
    const :cap, CapabilitySpec
    const :var_node, CapabilityVarNode
    const :var_name, String
    const :alias_name, String
    const :resolved_type, T.nilable(Type)
    const :var_sync, T.nilable(Symbol)
    const :var_storage, T.nilable(Symbol)
    const :zig_var, String
    const :clause, T.nilable(AST::ErrorClause)
    const :with_label, T.nilable(String)
    const :needs_sort, T::Boolean
    const :rt_name, String
  end

  class WithBindingMaterialization < T::Struct
    extend T::Sig

    const :bindings, T::Array[WithBindingNode]
    const :fallible_clauses, T::Array[FallibleClauseFact]

    sig { params(binding: WithBindingNode).void }
    def add_binding(binding)
      bindings << binding
    end

    sig { params(clause: FallibleClauseFact).void }
    def add_fallible_clause(clause)
      fallible_clauses << clause
    end
  end

  class LockBindingPlan < T::Struct
    const :guard_var, String
    const :alias_name, String
    const :lock_expr, MIR::Emittable
    const :lock_sync, T.nilable(Symbol)
    const :clause, T.nilable(AST::ErrorClause)
    const :with_label, T.nilable(String)
    const :with_node, AST::WithBlock
  end

  class MutableSnapshotCap < T::Struct
    const :var_node, CapabilityVarNode
    const :alias_name, String
    const :source, MIR::Emittable
    const :bare_type, Type
    const :conflict_error, Symbol
  end

  class MutableSnapshotPlan < T::Struct
    const :node, AST::WithBlock
    const :with_label, T.nilable(String)
    const :rt_name, String
    const :alloc, Symbol
    const :body_mir, T::Array[MIR::Emittable]
    const :retries, T.nilable(Integer)
    const :capabilities, T::Array[MutableSnapshotCap]
  end

  sig { params(sync: T.nilable(Symbol), atomic_ptr: T::Boolean).returns(T.nilable(String)) }
  def sync_wrap_constructor(sync, atomic_ptr:)
    return nil unless sync
    SYNC_WRAP_CONSTRUCTORS[atomic_ptr ? :atomic_ptr : sync]
  end

  sig { params(sync: T.nilable(Symbol), bare_zig_t: String, atomic_ptr: T::Boolean).returns(T.nilable(String)) }
  def sync_wrap_type(sync, bare_zig_t, atomic_ptr:)
    return nil unless sync
    wrapper = SYNC_WRAP_TYPES[atomic_ptr ? :atomic_ptr : sync]
    wrapper ? "#{wrapper}(#{bare_zig_t})" : nil
  end

  # Zig expression naming the locked-inner. Identifier → its Zig name (or
  # DO-capture rename). GetField → the chained field path (e.g.
  # `env.vars`), built recursively for nested fields.
  sig { params(var_node: CapabilityVarNode, var_name: String).returns(String) }
  def with_cap_zig_target(var_node, var_name)
    T.bind(self, MIRLowering) rescue nil
    if var_node.is_a?(AST::GetField)
      build_field_path_zig(var_node)
    else
      decl = var_node.respond_to?(:symbol) ? var_node.symbol&.reg : nil
      mapped = decl ? function_state.decl_zig_names[decl.object_id] : nil
      capture_state.do_capture_map&.dig(var_name) || mapped || var_name
    end
  end

  # True when the WITH-bound entity is a function parameter (vs. a local
  # binding). Parameters' runtime wrappers come from the caller and may
  # not be statically known at this fn's codegen time.
  sig { params(var_node: CapabilityVarNode).returns(T::Boolean) }
  def with_cap_is_param?(var_node)
    T.bind(self, MIRLowering) rescue nil
    return false unless var_node.is_a?(AST::Identifier)
    var_node.symbol&.is_param == true
  end

  # Recursively build the Zig string for a (possibly nested) field path.
  # Stops at the root Identifier; intermediate GetFields chain via `.`.
  sig { params(node: FieldPathNode).returns(String) }
  def build_field_path_zig(node)
    T.bind(self, MIRLowering) rescue nil
    case node
    when AST::Identifier
      capture_state.do_capture_map&.dig(node.name) || node.name
    when AST::GetField
      "#{build_field_path_zig(node.target)}.#{node.field}"
    else
      node.to_s
    end
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String), rt_name: String).returns(WithBindingMaterialization) }
  def with_binding_materialization(node, with_label, rt_name)
    materialization = WithBindingMaterialization.new(bindings: [], fallible_clauses: [])
    caps = with_capability_specs(node)
    clause = T.cast(node.lock_error_clause, T.nilable(AST::ErrorClause))
    fallible_caps = caps.select { |cap| [:EXCLUSIVE, :write_locked_read].include?(cap.capability) }
    needs_sort = fallible_caps.length >= 2

    materialize_sorted_lock_bindings(node, materialization, fallible_caps, clause, with_label) if needs_sort
    caps.each do |cap|
      context = with_capability_binding_context(node, cap, clause, with_label, needs_sort, rt_name)
      materialize_with_capability_binding(materialization, context)
    end
    materialization
  end

  sig { params(node: AST::WithBlock).returns(T::Array[CapabilitySpec]) }
  def with_capability_specs(node)
    CapabilityPlan.require_for(node).all
  end

  sig do
    params(
      node: AST::WithBlock,
      materialization: WithBindingMaterialization,
      fallible_caps: T::Array[CapabilitySpec],
      clause: T.nilable(AST::ErrorClause),
      with_label: T.nilable(String),
    ).void
  end
  def materialize_sorted_lock_bindings(node, materialization, fallible_caps, clause, with_label)
    if clause
      materialization.add_binding(sorted_lock_acquire(fallible_caps, clause, with_label, node))
      fallible_caps.each do |cap|
        var_name = cap.target_label
        alias_name = cap.alias_name
        materialization.add_fallible_clause(build_fallible_clause_mir(var_name, alias_name, clause))
      end
    else
      materialization.add_binding(sorted_lock_acquire(fallible_caps, nil, with_label, node))
    end
  end

  sig do
    params(
      node: AST::WithBlock,
      cap: CapabilitySpec,
      clause: T.nilable(AST::ErrorClause),
      with_label: T.nilable(String),
      needs_sort: T::Boolean,
      rt_name: String,
    ).returns(WithCapabilityBindingContext)
  end
  def with_capability_binding_context(node, cap, clause, with_label, needs_sort, rt_name)
    var_node = T.cast(cap.var_node, CapabilityVarNode)
    var_name = cap.target_label
    alias_name = cap.alias_name
    WithCapabilityBindingContext.new(
      node: node,
      cap: cap,
      var_node: var_node,
      var_name: var_name,
      alias_name: alias_name,
      resolved_type: cap.resolved_type,
      var_sync: cap.sync,
      var_storage: cap.storage,
      zig_var: with_cap_zig_target(var_node, var_name),
      clause: clause,
      with_label: with_label,
      needs_sort: needs_sort,
      rt_name: rt_name,
    )
  end

  sig { params(materialization: WithBindingMaterialization, context: WithCapabilityBindingContext).void }
  def materialize_with_capability_binding(materialization, context)
    case context.cap.capability
    when :multiowned, :shared
      materialization.add_binding(shared_capability_binding(context))
    when :EXCLUSIVE
      exclusive = exclusive_capability_binding(context)
      materialization.add_binding(exclusive) unless exclusive.empty?
      append_fallible_clause(materialization, context) if !exclusive.empty? && context.clause
    when :write_locked_read
      read_lock = read_locked_capability_binding(context)
      materialization.add_binding(read_lock) unless read_lock.empty?
      append_fallible_clause(materialization, context) if !read_lock.empty? && context.clause
    when :BORROWED
      materialization.add_binding(borrowed_capability_binding(context))
    when :RESTRICT
      restrict = restrict_capability_binding(context)
      materialization.add_binding(restrict) unless restrict.empty?
    when :VIEW
      materialization.add_binding(view_capability_binding(context))
    when :SNAPSHOT
      snapshot = snapshot_capability_binding(context)
      materialization.add_binding(snapshot) if snapshot
    when :MATERIALIZED_VIEW
      materialized_view_capability_bindings(context).each { |binding| materialization.add_binding(binding) }
    end
  end

  sig { params(materialization: WithBindingMaterialization, context: WithCapabilityBindingContext).void }
  def append_fallible_clause(materialization, context)
    clause = context.clause
    return unless clause

    materialization.add_fallible_clause(build_fallible_clause_mir(context.var_name, context.alias_name, clause))
  end

  sig { params(var_node: CapabilityVarNode, raw_atomic: T::Boolean).returns(MIR::Emittable) }
  def with_capability_source_mir(var_node, raw_atomic: false)
    lowerer = T.cast(self, MIRLowering)
    prev_locked = lowerer.capability_state.locked_unwrap_map
    prev_rc = lowerer.capability_state.rc_unwrap_map
    prev_raw = lowerer.capability_state.atomic_emit_raw
    lowerer.capability_state.locked_unwrap_map = nil
    lowerer.capability_state.rc_unwrap_map = nil
    lowerer.capability_state.atomic_emit_raw = true if raw_atomic

    begin
      T.cast(lowerer.lower(var_node), MIR::Emittable)
    ensure
      lowerer.capability_state.atomic_emit_raw = prev_raw
      lowerer.capability_state.locked_unwrap_map = prev_locked
      lowerer.capability_state.rc_unwrap_map = prev_rc
    end
  end

  sig { params(alias_name: String).returns(String) }
  def safe_with_capability_alias(alias_name)
    cleaned = (alias_name.end_with?("!") || alias_name.end_with?("?")) ? T.must(alias_name[0..-2]) : alias_name
    cleaned = Compiler::Entrypoint::ZIG_NAME if cleaned == Compiler::Entrypoint::NAME
    ZigType.primitive_numeric_identifier?(cleaned) ? "@\"#{cleaned}\"" : cleaned
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[MIR::Emittable]) }
  def shared_capability_binding(context)
    inner = "__#{context.var_name}_unwrap"
    source = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new(context.zig_var), "ctrl"), "data"))
    [MIR::Let.new(inner, source, false, nil, nil), MIR::Suppress.new(inner)]
  end

  sig { params(context: WithCapabilityBindingContext, lock_expr: MIR::Emittable, lock_sync: T.nilable(Symbol)).returns(LockBindingPlan) }
  def lock_binding_plan(context, lock_expr, lock_sync)
    LockBindingPlan.new(
      guard_var: "__#{context.var_name}_guard_#{context.node.object_id.abs}",
      alias_name: context.alias_name,
      lock_expr: lock_expr,
      lock_sync: lock_sync,
      clause: context.clause,
      with_label: context.with_label,
      with_node: context.node,
    )
  end

  sig { params(plan: LockBindingPlan, acquire_call: MIR::Emittable).returns(T::Array[MIR::Emittable]) }
  def render_lock_binding(plan, acquire_call)
    clause = plan.clause
    if clause
      return [
        MIR::FallibleLockBinding.new(
          plan.guard_var,
          plan.alias_name,
          acquire_call,
          lock_failure_action(clause, plan.with_label, plan.with_node),
          clause.retries,
          clause.matched_types,
          clause.bubble_types,
          plan.with_node.token&.line.to_s,
          "__acq_#{plan.with_node.object_id.abs}_#{plan.guard_var}",
          T.cast(self, MIRLowering).runtime_binding_name,
        ),
      ]
    end

    [
      MIR::Let.new(plan.guard_var, acquire_call, true, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(plan.guard_var), "release", [], false, MIR::CallableContract.no_ownership(0))),
      MIR::Let.new(plan.alias_name, MIR::MethodCall.new(MIR::Ident.new(plan.guard_var), "get", [], false, MIR::CallableContract.no_ownership(0)), false, nil, nil),
      MIR::Suppress.new(plan.alias_name),
    ]
  end

  sig { params(context: WithCapabilityBindingContext).returns(MIR::Emittable) }
  def exclusive_lock_expr(context)
    is_arc = SymbolEntry.rc_storage?(context.var_storage) || context.resolved_type&.any_rc?
    is_param = with_cap_is_param?(context.var_node)
    source = with_capability_source_mir(context.var_node)
    return MIR::CapabilityLockTarget.new(source, false, true) if is_param && !is_arc

    MIR::CapabilityLockTarget.new(source, is_arc, false)
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(Symbol)) }
  def exclusive_lock_sync(context)
    is_param = with_cap_is_param?(context.var_node)
    context.node.polymorphic && is_param ? nil : context.var_sync
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[MIR::Emittable]) }
  def exclusive_capability_binding(context)
    return [] if context.needs_sort

    plan = lock_binding_plan(context, exclusive_lock_expr(context), exclusive_lock_sync(context))
    render_lock_binding(plan, MIR::LockAcquire.new(plan.lock_expr, plan.lock_sync, !plan.clause.nil?))
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[MIR::Emittable]) }
  def read_locked_capability_binding(context)
    return [] if context.needs_sort

    is_arc = SymbolEntry.rc_storage?(context.var_storage) || context.resolved_type&.any_rc?
    lock_expr = MIR::CapabilityLockTarget.new(with_capability_source_mir(context.var_node), is_arc, false)
    plan = lock_binding_plan(context, lock_expr, nil)
    render_lock_binding(plan, MIR::MethodCall.new(lock_expr, plan.clause ? "readOrErr" : "read", [], false, MIR::CallableContract.no_ownership(0)))
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[MIR::Emittable]) }
  def borrowed_capability_binding(context)
    source_mir = with_capability_source_mir(context.var_node)
    is_param = with_cap_is_param?(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    aliased_value = if context.node.polymorphic
      MIR::CapabilityUnwrap.new(source_mir)
	    elsif borrowed_const_param_alias?(context, is_param)
	      MIR::Deref.new(source_mir)
	    else
	      source_mir
	    end
    [MIR::Let.new(safe_alias, aliased_value, false, nil, nil), MIR::Suppress.new(safe_alias)]
  end

  sig { params(context: WithCapabilityBindingContext, is_param: T::Boolean).returns(T::Boolean) }
	  def borrowed_const_param_alias?(context, is_param)
	    return false unless is_param
	    return false unless context.var_sync.nil? || context.var_sync == :local

	    sym = context.var_node.symbol
	    return false unless sym && !sym.mutable

	    source_type = Type.new(sym.type)
	    return false if source_type.non_string_array? && !source_type.collection?

	    true
	  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[MIR::Emittable]) }
  def restrict_capability_binding(context)
    return [] unless context.var_sync.nil? || context.var_sync == :local

    source_mir = with_capability_source_mir(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    value = if context.node.polymorphic
      MIR::CapabilityUnwrap.new(source_mir)
    elsif with_cap_is_param?(context.var_node)
      MIR::Deref.new(source_mir)
    elsif context.cap.alias_mutable
      MIR::AddressOf.new(source_mir)
    else
      source_mir
    end
    stmts = T.let([MIR::Let.new(safe_alias, value, false, nil, nil)], T::Array[MIR::Emittable])
    stmts << MIR::Suppress.new(safe_alias) unless context.var_sync == :local || context.cap.alias_mutable
    stmts
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[MIR::Emittable]) }
  def view_capability_binding(context)
    source_mir = with_capability_source_mir(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    rt = context.resolved_type || Type.new(:Any)
    inner_t = rt.future? ? rt.tense_type : rt
    wrapped_inner = inner_t.wrapped_type
    is_value_shape = inner_t.primitive? || inner_t.string? ||
                     (inner_t.optional? && wrapped_inner &&
                      (wrapped_inner.primitive? || wrapped_inner.string?))
    wants_release = !is_value_shape && (inner_t.collection_value? || !inner_t.primitive?)
    view_expr = MIR::MethodCall.new(source_mir, "view", [], false, MIR::CallableContract.no_ownership(0))
    stmts = T.let([MIR::Let.new(safe_alias, view_expr, wants_release, nil, nil)], T::Array[MIR::Emittable])
    if wants_release
      stmts << MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(safe_alias), "release", [], false, MIR::CallableContract.no_ownership(0)))
    end
    stmts.concat(coop_yield_mir)
    stmts << MIR::Suppress.new(safe_alias)
    stmts
  end

  sig { returns(T::Array[MIR::Emittable]) }
  def coop_yield_mir
    scheduler = MIR::FieldGet.new(MIR::Ident.new("CheatHeader"), "scheduler")
    active_scheduler = MIR::FieldGet.new(scheduler, "active_scheduler")
    [
      MIR::IfStmt.new(
        MIR::FieldGet.new(scheduler, "scheduler_running"),
        [
          MIR::ExprStmt.new(MIR::MethodCall.new(active_scheduler, "drainChannels", [], false, MIR::CallableContract.no_ownership(0)), false),
          MIR::ExprStmt.new(MIR::MethodCall.new(active_scheduler, "coopYield", [], false, MIR::CallableContract.no_ownership(0)), false),
        ],
        nil,
      ),
    ]
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(MIR::SnapshotRead)) }
  def snapshot_capability_binding(context)
    return nil if CapabilityPlan.require_for(context.node).mutable_snapshot?

    source_mir = with_capability_source_mir(context.var_node, raw_atomic: true)
    safe_alias = safe_with_capability_alias(context.alias_name)
    guard_var = "__#{context.var_name}_snap_#{context.node.object_id.abs}"
    MIR::SnapshotRead.new(MIR::CapabilityUnwrap.new(source_mir), context.rt_name, safe_alias, guard_var, [])
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[WithBindingNode]) }
  def materialized_view_capability_bindings(context)
    source_mir = with_capability_source_mir(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    rt = context.resolved_type || Type.new(:Any)
    is_collection = rt.observable_array_future? || rt.array?
    materialize = MIR::MethodCall.new(
      source_mir,
      "materialize",
      [MIR::AllocatorRef.new(:heap)],
      true,
      MIR::CallableContract.no_ownership(1),
      is_collection ? :heap : nil,
    )
    return [MIR::Let.new(safe_alias, materialize, true, nil, "_ = &#{safe_alias};")] unless is_collection

    entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    MIR::BindingMaterialization.new(
      name: safe_alias,
      expr: materialize,
      alloc: :heap,
      type_info: rt.tense_type,
      mutable: true,
      suppression: "_ = &#{safe_alias};",
      cleanup_entry: entry,
      scope: :heap
    ).statements
  end

  sig { params(node: AST::WithBlock, clause: T.nilable(AST::ErrorClause)).returns(T.nilable(String)) }
  def with_block_control_label(node, clause)
    return nil unless clause && (clause.action == AST::ErrorActionKind::Pass || clause.action == AST::ErrorActionKind::Block)

    "__with_#{node.object_id.abs}"
  end

  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def mutable_snapshot_with?(node)
    CapabilityPlan.require_for(node).mutable_snapshot?
  end

  sig do
    params(
      node: AST::WithBlock,
      materialization: WithBindingMaterialization,
      with_label: T.nilable(String),
    ).returns(T::Array[MIR::Emittable])
  end
  def with_block_body_stmts(node, materialization, with_label)
    with_capability_alias_maps(node) do
      if mutable_snapshot_with?(node)
        materialization.add_binding(emit_snapshot_mutable_call(node, with_label))
        []
      else
        lowered_body = T.cast(self, MIRLowering).lower_body(node.body)
        wrap_body_with_guard(node, lowered_body, with_label)
      end
    end
  end

  sig { params(node: AST::WithBlock).returns(T::Array[String]) }
  def with_block_borrow_names(node)
    with_capability_specs(node).filter_map do |cap|
      var_node = T.cast(cap.var_node, CapabilityVarNode)
      var_node.is_a?(AST::Identifier) ? var_node.name.to_s : nil
    end
  end

  sig { params(materialization: WithBindingMaterialization, node: AST::WithBlock).returns(T.nilable(MIR::Emittable)) }
  def with_block_inline_bindings(materialization, node)
    string_bindings = materialization.bindings.filter_map { |binding| binding if binding.is_a?(String) }.reject(&:empty?)
    return nil if string_bindings.empty?

    Kernel.raise "WITH binding materialization still produced pre-emission Zig text; structural MIR binding nodes are required"
  end

  sig { params(materialization: WithBindingMaterialization).returns(T::Array[MIR::Emittable]) }
  def structured_with_bindings(materialization)
    materialization.bindings.flat_map do |binding|
      if binding.is_a?(Array)
        binding
      elsif binding.is_a?(MIR::Emittable)
        [binding]
      else
        []
      end
    end
  end

  sig do
    params(
      node: AST::WithBlock,
      materialization: WithBindingMaterialization,
      body_stmts: T::Array[MIR::Emittable],
      with_label: T.nilable(String),
    ).returns(T.any(MIR::BlockExpr, MIR::ScopeBlock))
  end
  def assemble_with_block(node, materialization, body_stmts, with_label)
    stmts = T.let([], T::Array[MIR::Emittable])
    inline_bindings = with_block_inline_bindings(materialization, node)
    stmts << inline_bindings if inline_bindings
    stmts.concat(structured_with_bindings(materialization))
    stmts.concat(body_stmts)
    with_label ? MIR::BlockExpr.new(with_label, stmts) : MIR::ScopeBlock.new(stmts)
  end

  sig { params(node: AST::WithBlock).returns(T.any(MIR::BlockExpr, MIR::ScopeBlock)) }
  def lower_with_block(node)
    T.bind(self, MIRLowering) rescue nil
    return lower_with_match_block(node) if node.arms

    # Universal polymorphic WITH lowers to a helper that dispatches by
    # actual family at the call site.
    if node.universal_poly && with_capability_specs(node).length == 1
      return lower_polymorphic_universal(node)
    end
    rt_name = runtime_binding_name
    clause = T.cast(node.lock_error_clause, T.nilable(AST::ErrorClause))
    with_label = with_block_control_label(node, clause)
    materialization = with_binding_materialization(node, with_label, rt_name)
    assemble_with_block(node, materialization, with_block_body_stmts(node, materialization, with_label), with_label)
  end

  LockedUnwrapMap = T.type_alias { T::Hash[String, T.any(String, T::Boolean)] }
  RcUnwrapMap = T.type_alias { T::Hash[String, String] }
  AliasAllocMap = T.type_alias { T::Hash[String, T.nilable(Symbol)] }
  AliasOwnerMap = T.type_alias { T::Hash[String, String] }

  sig do
    type_parameters(:Result)
      .params(node: AST::WithBlock, blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_capability_alias_maps(node, &blk)
    T.bind(self, MIRLowering) rescue nil
    prev_locked = capability_state.locked_unwrap_map
    prev_rc = capability_state.rc_unwrap_map
    prev_alias_alloc = capability_state.with_alias_alloc_map
    prev_alias_owner = capability_state.with_alias_owner_map
    locked_map = T.let((prev_locked || {}).dup, LockedUnwrapMap)
    rc_map = T.let((prev_rc || {}).dup, RcUnwrapMap)
    alias_alloc_map = T.let((prev_alias_alloc || {}).dup, AliasAllocMap)
    alias_owner_map = T.let((prev_alias_owner || {}).dup, AliasOwnerMap)
    capability_state.locked_unwrap_map = locked_map
    capability_state.rc_unwrap_map = rc_map
    capability_state.with_alias_alloc_map = alias_alloc_map
    capability_state.with_alias_owner_map = alias_owner_map

    with_capability_specs(node).each do |cap|
      var_node = T.cast(cap.var_node, CapabilityVarNode)
      var_name = cap.target_label
      alias_name = cap.alias_name
      if cap.alias_explicit
        alias_alloc_map[alias_name] = placement_for_node(var_node)
        alias_owner_map[alias_name] = var_name.to_s
      end
      case cap.capability
      when :EXCLUSIVE, :write_locked_read
        locked_map[alias_name] = true
        # Also map original var_name to alias so field accesses on the original
        # variable get rewritten to use the unwrapped inner alias.
        locked_map[var_name] = alias_name if alias_name != var_name
      when :multiowned, :shared
        rc_map[var_name] = "__#{var_name}_unwrap"
      end
    end

    blk.call
  ensure
    T.bind(self, MIRLowering) rescue nil
    capability_state.locked_unwrap_map = prev_locked
    capability_state.rc_unwrap_map = prev_rc
    capability_state.with_alias_alloc_map = prev_alias_alloc
    capability_state.with_alias_owner_map = prev_alias_owner
  end

  # Structured representation of a fallible-acquire clause for the BC
  # backend. The Zig backend renders the clause inline as Zig text via
  # `emit_fallible_lock_binding`; the BC backend can't parse the Zig
  # block, so it consumes this descriptor instead. `action_mir` is the
  # already-lowered MIR body (only for `:block`); `exit_msg_mir` is the
  # lowered message expression (only for `:exit`). `matched_types` and
  # `bubble_types` are the annotator-resolved selector lists; `retries`
  # is the RETRY(N) count or nil.
  sig { params(var_name: String, alias_name: String, clause: AST::ErrorClause).returns(FallibleClauseFact) }
  def build_fallible_clause_mir(var_name, alias_name, clause)
    T.bind(self, MIRLowering) rescue nil
    action_mir = T.let([], T::Array[MIR::Emittable])
    exit_msg_mir = T.let(nil, T.nilable(MIR::Emittable))
    case clause.action
    when AST::ErrorActionKind::Block
      action_mir = lower_body(clause.body)
    when AST::ErrorActionKind::Exit
      exit_msg_mir = lower(T.must(clause.message))
    end
    FallibleClauseFact.new(
      var_name: var_name.to_s,
      alias_name: alias_name.to_s,
      action_kind: clause.action,
      retries: clause.retries,
      matched_types: clause.matched_types,
      bubble_types: clause.bubble_types,
      action_mir: action_mir,
      exit_msg_mir: exit_msg_mir,
    )
  end


  sig { params(node: AST::WithBlock).returns(MIR::ScopeBlock) }
  def lower_with_match_block(node)
    T.bind(self, MIRLowering) rescue nil
    cap = CapabilityPlan.require_for(node).first_transition
    var_node = T.cast(cap.var_node, CapabilityVarNode)
    cell = with_capability_source_mir(var_node, raw_atomic: true)
    alias_name = cap.alias_name
    safe_alias = safe_with_capability_alias(alias_name)
    snapshot_mode = node.respond_to?(:snapshot_mode) && node.snapshot_mode

    arms_meta = T.must(node.arms).map { |arm|
      MIR::WithMatchArm.new(
        family: arm.family,
        guard_var: "__#{alias_name}_match_#{node.object_id.abs}",
        body: lower_body(arm.body),
      )
    }
    MIR::ScopeBlock.new([MIR::WithMatchDispatch.new(cell, safe_alias, snapshot_mode, runtime_binding_name, arms_meta)])
  end

  # Emit a single-cell or multi-cell snapshot transaction whose closure
  # runs the WITH body. Conflict handlers become catch arms.
  #
  # Single-cell shape:
  #   cell.update(rt, alloc, struct {
  #     fn run(va: *T) void { <body_zig> }
  #   }.run, .{}) catch |__err| switch (__err) {
  #     error.UpdateRetriesExhausted => { <conflict_action> },
  #     else => return __err,
  #   };
  #
  # Multi-cell shape:
  #   CheatLib.versionedUpdateMulti(.{a, b, ...}, rt, alloc, struct {
  #     fn run(views: anytype) anyerror!void {
  #       const va = views[0]; _ = &va;
  #       const vb = views[1]; _ = &vb;
  #       <body_zig>
  #     }
  #   }.run, .{}) catch |__err| switch (__err) {
  #     error.UpdateRetriesExhausted => { <conflict_action> },
  #     else => return __err,
  #   };
  # Return structured MIR so the checker can see the transaction body and
  # runtime heap allocation instead of treating them as opaque generated code.
  sig { params(node: AST::WithBlock).returns(MIR::ScopeBlock) }
  def lower_polymorphic_universal(node)
    T.bind(self, MIRLowering) rescue nil
    cap = CapabilityPlan.require_for(node).first_transition
    var_node   = T.cast(cap.var_node, CapabilityVarNode)
    var_name   = cap.target_label
    alias_name = cap.alias_name
    safe_alias = zig_safe_name(alias_name)
    # Lower the cell raw, with no auto-`.load()` injection. The atomic-
    # cell read path that visit_Identifier installs (line 4056 in
    # annotator/helpers/cell access) wraps `@atomic` reads in `.load()`,
    # which returns a value -- but `polymorphicMutate` needs the cell
    # OBJECT to dispatch by `@hasDecl`. Set capability_state.atomic_emit_raw so the
    # surrounding lowering returns the bare cell expression.
    cell_mir = MIR::AddressOf.new(with_capability_source_mir(var_node, raw_atomic: true))
    # The body's `x` alias is a `*T` -- grab the bare T (post-Arc,
    # post-sync-wrapper) for the closure signature.
    resolved_source = cap.resolved_type
    rt_obj = Type.from_node!(resolved_source, context: "WITH polymorphic capability resolved type")
    bare_type = rt_obj.respond_to?(:bare_data_type) ? rt_obj.bare_data_type : rt_obj
    # Keep the universal path on the same alias-attribution contract as the
    # concrete WITH path.  Structural operations in the callback (for example
    # a HashMap write through `cache AS writable`) must retain the original
    # parameter as their allocator owner; attributing them to the callback-only
    # alias leaves MIRChecker with no parameter or AllocMark to validate.
    body_mir = with_capability_alias_maps(node) { lower_body(node.body) }
    guard_cond = combined_guard_cond(node)
    if polymorphic_flow_required?(node)
      guard_fail = guard_cond ? guard_fail_flow_body(node) : []
      return MIR::ScopeBlock.new([MIR::PolymorphicMutateFlow.new(
        cell_mir, runtime_binding_name, safe_alias, bare_type,
        Type.new(current_function_return_payload_zig || :Void),
        body_mir, guard_cond, guard_fail
      )])
    else
      body_mir = wrap_body_with_guard(node, body_mir, nil)
      MIR::ScopeBlock.new([MIR::PolymorphicMutate.new(cell_mir, runtime_binding_name, safe_alias, bare_type, body_mir)])
    end
  end

  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def polymorphic_flow_required?(node)
    T.bind(self, MIRLowering) rescue nil
    return true if with_capability_specs(node).any? { |cap| cap.guard_expr }
    ast_contains_return?(node.body)
  end

  sig { params(node: AstReturnSearchNode).returns(T::Boolean) }
  def ast_contains_return?(node)
    T.bind(self, MIRLowering) rescue nil
    case node
    when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type, Lexer::Token, AST::FunctionDef
      false
    when Array
      node.any? { |item| ast_contains_return?(item) }
    when Hash
      node.values.any? { |item| ast_contains_return?(item) }
    when AST::ReturnNode
      true
    else
      node.respond_to?(:each_pair) && T.unsafe(node).each_pair.any? { |_, v| ast_contains_return?(v) }
    end
  end

  sig { params(node: AST::WithBlock).returns(T::Array[MIR::Emittable]) }
  def guard_fail_flow_body(node)
    T.bind(self, MIRLowering) rescue nil
    clause = T.cast(node.lock_error_clause, T.nilable(AST::ErrorClause))
    return [] unless clause && clause.matched_types.include?(:GuardFail)

    line = node.token&.line.to_s
    result = T.let([], T::Array[MIR::Emittable])
    case clause.action
    when AST::ErrorActionKind::Return
      result << MIR::ReturnStmt.new(lower(T.must(clause.value)))
    when AST::ErrorActionKind::Raise
      result << MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "setError", [
        MIR::EnumTag.new(variant: "Transient"),
        MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), "GuardFail")),
        MIR::Lit.new(zig_string_lit("WITH GUARD predicate failed")),
        MIR::Lit.new(line),
      ], false, MIR::CallableContract.no_ownership(4)), false)
      result << MIR::PolymorphicFlowSignal.new(:raise_no_commit, nil)
    when AST::ErrorActionKind::Exit
      msg_mir = lower(T.must(clause.message))
      result << MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "setError", [
        MIR::EnumTag.new(variant: "Transient"),
        MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), "GuardFail")),
        msg_mir,
        MIR::Lit.new(line),
      ], false, MIR::CallableContract.no_ownership(4)), false)
      result << MIR::PolymorphicFlowSignal.new(:raise_no_commit, nil)
    when AST::ErrorActionKind::Block
      result.concat(lower_body(clause.body))
    else
      result
    end
    result
  end

  sig { params(callee: String, args: T::Array[MIR::Emittable]).returns(MIR::Call) }
  def no_ownership_call(callee, args)
    MIR::Call.new(callee, args, false, false, MIR::CallableContract.no_ownership(args.length))
  end

  # Emit MIR for each PRE clause on a function definition. Each
  # predicate is lowered to a guarded if-statement that, when the
  # predicate is false, sets PreconditionFail on the runtime context
  # and returns the CheatError sentinel. Fail-fast: the first failing
  # PRE returns; later PREs are not evaluated.
  sig { params(node: AST::FunctionDef).returns(T::Array[MIR::Emittable]) }
  def lower_pre_clauses(node)
    T.bind(self, MIRLowering) rescue nil
    pre_clauses = node.respond_to?(:pre_clauses) ? (node.pre_clauses || []) : []
    return [] if pre_clauses.empty?

    pre_clauses.map do |entry|
      expr   = entry[:expr]
      source = entry[:source]
      cond = lower(expr)
      line = expr.token ? expr.token.line.to_s : "0"

      msg_text = if source && !source.empty?
        "PRE failed: #{source}"
      else
        "precondition failed"
      end
      msg_zig = zig_string_lit(msg_text)

      MIR::IfStmt.new(MIR::UnaryOp.new("!", cond), [
        MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "setError", [
          MIR::EnumTag.new(variant: "Input"),
          MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), "PreconditionFail")),
          MIR::Lit.new(msg_zig),
          MIR::Lit.new(line),
        ], false, MIR::CallableContract.no_ownership(4)), false),
        MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError")),
      ], nil)
    end
  end

  # Escape an arbitrary Ruby string for embedding as a Zig string
  # literal. `\` and `"` are escape-prefixed; named-escape control
  # characters (\n \r \t) get their named form; every other byte in
  # 0x00..0x1F or 0x7F gets a `\xNN` hex escape. Anything 0x20+
  # (printable + UTF-8 high bytes) passes through verbatim — Zig
  # accepts UTF-8 in string literals.
  sig { params(text: String).returns(String) }
  def zig_string_lit(text)
    T.bind(self, MIRLowering) rescue nil
    out = +'"'
    text.each_byte do |b|
      case b
      when 0x5c  then out << '\\\\'      # backslash
      when 0x22  then out << '\\"'        # double quote
      when 0x0a  then out << '\\n'
      when 0x0d  then out << '\\r'
      when 0x09  then out << '\\t'
      when 0x00..0x1f, 0x7f
        out << format('\\x%02x', b)
      else
        out << b.chr(Encoding::ASCII_8BIT)
      end
    end
    out << '"'
    out
  end

  sig { params(node: AST::WithBlock, body_mir: T::Array[MIR::Node], with_label: T.nilable(String)).returns(T::Array[MIR::Node]) }
  def wrap_body_with_guard(node, body_mir, with_label)
    T.bind(self, MIRLowering) rescue nil
    guard_cond = combined_guard_cond(node)
    return body_mir unless guard_cond

    fail_body = guard_fail_body(node, with_label)
    [MIR::IfStmt.new(guard_cond, body_mir, fail_body)]
  end

  # Lower every per-capability `guard_expr` and AND them together so the
  # body runs only when every predicate holds (multi-object consistency).
  sig { params(node: AST::WithBlock).returns(T.nilable(MIR::BinOp)) }
  def combined_guard_cond(node)
    T.bind(self, MIRLowering) rescue nil
    guarded = CapabilityPlan.require_for(node).guarded
    return nil if guarded.empty?
    guarded.map { |g| lower(T.must(g.guard_expr)) }
           .reduce { |acc, e| MIR::BinOp.new("and", acc, e) }
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String)).returns(T::Array[MIR::Emittable]) }
  def guard_fail_body(node, with_label)
    T.bind(self, MIRLowering) rescue nil
    clause = node.lock_error_clause
    return [] unless clause && clause.matched_types.include?(:GuardFail)

    error_action_stmts(clause, with_label, node, :GuardFail, "WITH GUARD predicate failed")
  end

  sig { params(clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock, error_type: Symbol, default_msg: String).returns(T::Array[MIR::Emittable]) }
  def error_action_stmts(clause, with_label, with_node, error_type, default_msg)
    T.bind(self, MIRLowering) rescue nil
    line = with_node.token&.line.to_s
    err_name = error_type.to_s
    kind = AST.kind_of_type(error_type) || :Transient
    case clause.action
    when AST::ErrorActionKind::Raise
      [
        MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "setError", [
          MIR::EnumTag.new(variant: kind.to_s),
          MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), err_name)),
          MIR::Lit.new(zig_string_lit(default_msg)),
          MIR::Lit.new(line),
        ], false, MIR::CallableContract.no_ownership(4)), false),
        MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError")),
      ]
    when AST::ErrorActionKind::Exit
      msg_mir = lower(T.must(clause.message))
      [
        MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "setError", [
          MIR::EnumTag.new(variant: kind.to_s),
          MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), err_name)),
          msg_mir,
          MIR::Lit.new(line),
        ], false, MIR::CallableContract.no_ownership(4)), false),
        MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError")),
      ]
    when AST::ErrorActionKind::Pass
      [MIR::BreakStmt.new(T.must(with_label), nil)]
    when AST::ErrorActionKind::Return
      [MIR::ReturnStmt.new(lower(T.must(clause.value)))]
    when AST::ErrorActionKind::Block
      lower_body(clause.body) + [MIR::BreakStmt.new(T.must(with_label), nil)]
    else
      raise "Internal: unknown lock action #{clause.action}"
    end
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String)).returns(MutableSnapshotPlan) }
  def mutable_snapshot_plan(node, with_label)
    lowerer = T.cast(self, MIRLowering)
    body_mir = lowerer.lower_body(node.body)
    rt_name = lowerer.runtime_binding_name
    MutableSnapshotPlan.new(
      node: node,
      with_label: with_label,
      rt_name: rt_name,
      alloc: :heap,
      body_mir: body_mir,
      retries: node.lock_error_clause&.retries,
      capabilities: with_capability_specs(node).map { |cap| mutable_snapshot_cap(lowerer, cap) },
    )
  end

  sig { params(lowerer: MIRLowering, cap: CapabilitySpec).returns(MutableSnapshotCap) }
  def mutable_snapshot_cap(lowerer, cap)
    var_node = T.cast(cap.var_node, CapabilityVarNode)
    sym = var_node.symbol
    resolved_type = cap.resolved_type
    MutableSnapshotCap.new(
      var_node: var_node,
      alias_name: cap.alias_name,
      source: lowerer.with_capability_source_mir(var_node, raw_atomic: true),
      bare_type: resolved_type.bare_data_type,
      conflict_error: sym && sym.atomic? && sym.indirect? ? :AtomicConflict : :MvccConflict,
    )
  end

  sig { params(plan: MutableSnapshotPlan, cap: MutableSnapshotCap).returns(MIR::SnapshotTransaction) }
  def single_mutable_snapshot_txn(plan, cap)
    conflict_action = conflict_failure_action(plan.node.lock_error_clause, plan.with_label, plan.node, cap.conflict_error)
    MIR::SnapshotTransaction.new(
      MIR::CapabilityUnwrap.new(cap.source),
      plan.rt_name,
      plan.alloc,
      safe_with_capability_alias(cap.alias_name),
      cap.bare_type,
      plan.body_mir,
      conflict_action,
      plan.retries,
      plan.with_label,
      cap.conflict_error == :AtomicConflict,
    )
  end

  sig { params(plan: MutableSnapshotPlan).returns(MIR::SnapshotMultiTxn) }
  def multi_mutable_snapshot_txn(plan)
    conflict_action = conflict_failure_action(plan.node.lock_error_clause, plan.with_label, plan.node, :MvccConflict)
    MIR::SnapshotMultiTxn.new(
      plan.capabilities.map(&:source),
      plan.rt_name,
      plan.alloc,
      plan.capabilities.map { |cap| safe_with_capability_alias(cap.alias_name) },
      plan.body_mir,
      conflict_action,
      plan.retries,
      plan.with_label,
    )
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String)).returns(T.any(MIR::SnapshotTransaction, MIR::SnapshotMultiTxn)) }
  def emit_snapshot_mutable_call(node, with_label)
    plan = mutable_snapshot_plan(node, with_label)
    single_cap = plan.capabilities[0] unless plan.capabilities[1]
    single_cap ? single_mutable_snapshot_txn(plan, single_cap) : multi_mutable_snapshot_txn(plan)
  end

  # Build the user's snapshot-conflict action using the conflict error chosen
  # for the cell family. Retry loops are handled around the transaction call,
  # not inside this action. The emitter owns conversion to Zig.
  sig { params(clause: T.nilable(AST::ErrorClause), with_label: T.nilable(String), with_node: AST::WithBlock, conflict_error: Symbol).returns(MIR::FailureAction) }
  def conflict_failure_action(clause, with_label, with_node, conflict_error = :MvccConflict)
    T.bind(self, MIRLowering) rescue nil
    msg = conflict_error == :AtomicConflict ? "atomic CAS retries exhausted" : "MVCC commit conflict"
    return default_failure_action(with_label, with_node, conflict_error, msg) unless clause

    failure_action_from_clause(clause, with_label, with_node, conflict_error, msg)
  end

  sig { params(clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock).returns(MIR::FailureAction) }
  def lock_failure_action(clause, with_label, with_node)
    failure_action_from_clause(clause, with_label, with_node, :LockTimeout, "lock acquire timed out")
  end

  sig { params(with_label: T.nilable(String), with_node: AST::WithBlock, error_type: Symbol, default_msg: String).returns(MIR::FailureAction) }
  def default_failure_action(with_label, with_node, error_type, default_msg)
    T.bind(self, MIRLowering) rescue nil
    MIR::FailureAction.new(
      kind: MIR::FailureActionKind::Raise,
      error_type: error_type,
      error_kind: AST.kind_of_type(error_type) || :Transient,
      default_message: default_msg,
      line: with_node.token&.line.to_s,
      rt_name: runtime_binding_name,
      with_label: with_label,
    )
  end

  sig { params(clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock, error_type: Symbol, default_msg: String).returns(MIR::FailureAction) }
  def failure_action_from_clause(clause, with_label, with_node, error_type, default_msg)
    T.bind(self, MIRLowering) rescue nil
    kind = clause_failure_action_kind(clause.action)
    message_mir = T.let(nil, T.nilable(MIR::Emittable))
    return_mir = T.let(nil, T.nilable(MIR::Emittable))
    body_mir = T.let([], T::Array[MIR::Emittable])
    case clause.action
    when AST::ErrorActionKind::Exit
      message_mir = T.cast(lower(T.must(clause.message)), MIR::Emittable)
    when AST::ErrorActionKind::Return
      return_mir = T.cast(lower(T.must(clause.value)), MIR::Emittable)
    when AST::ErrorActionKind::Block
      body_mir = lower_body(clause.body)
    end
    MIR::FailureAction.new(
      kind: kind,
      error_type: error_type,
      error_kind: AST.kind_of_type(error_type) || :Transient,
      default_message: default_msg,
      line: with_node.token&.line.to_s,
      rt_name: runtime_binding_name,
      with_label: with_label,
      message: message_mir,
      return_value: return_mir,
      body: body_mir,
    )
  end

  sig { params(action: AST::ErrorActionKind).returns(MIR::FailureActionKind) }
  def clause_failure_action_kind(action)
    case action
    when AST::ErrorActionKind::Raise
      MIR::FailureActionKind::Raise
    when AST::ErrorActionKind::Exit
      MIR::FailureActionKind::Exit
    when AST::ErrorActionKind::Pass
      MIR::FailureActionKind::Pass
    when AST::ErrorActionKind::Return
      MIR::FailureActionKind::Return
    when AST::ErrorActionKind::Block
      MIR::FailureActionKind::Block
    else
      Kernel.raise "Internal: unknown lock action #{action}"
    end
  end

  # Build the per-capture entry list shared by the panicking and
  # fallible sorted-acquire emitters. `with_node` is the WithBlock AST
  # node; its object_id provides a per-WITH suffix so locals declared
  # at the bindings level (`__sort_guard_*`, `__held_*`) can never
  # collide with locals from a sibling or nested WITH that happens to
  # be lowered into the same Zig scope. Each WITH wraps its bindings
  # in its own labeled block today, so collisions are impossible in
  # practice, but the suffix makes the property defensible against
  # future lowering changes.
  sig { params(fallible_caps: T::Array[CapabilitySpec], fallible: T::Boolean, with_node: T.nilable(AST::WithBlock)).returns(T::Array[MIR::SortedLockAcquireEntry]) }
  def build_sorted_acquire_entries(fallible_caps, fallible:, with_node: nil)
    T.bind(self, MIRLowering) rescue nil
    suffix = with_node ? "_#{with_node.object_id.abs}" : ""
    fallible_caps.each_with_index.map do |cap, i|
      var_node = T.cast(cap.var_node, CapabilityVarNode)
      var_name   = cap.target_label
      alias_name = cap.alias_name
      resolved   = cap.resolved_type
      source_mir = with_capability_source_mir(var_node)
      var_storage = cap.storage
      is_arc = SymbolEntry.rc_storage?(var_storage) || resolved&.any_rc?
      lock_expr = MIR::CapabilityLockTarget.new(source_mir, is_arc, false)
      addr_expr = MIR::CapabilityLockAddress.new(source_mir, is_arc)
      var_sync   = cap.sync
      panic_method, err_method = case cap.capability
                                 when :EXCLUSIVE
                                   var_sync == :write_locked ? %w[write writeOrErr] : %w[acquire acquireOrErr]
                                 when :write_locked_read
                                   %w[read readOrErr]
                                 end
      MIR::SortedLockAcquireEntry.new(
        index: i,
        alias_name: alias_name.to_s,
        guard_var: "__sort_guard#{suffix}_#{i}",
        held_var: "__held#{suffix}_#{i}",
        lock_expr: lock_expr,
        address_expr: addr_expr,
        method_name: (fallible ? err_method : panic_method).to_s,
      )
    end
  end

  sig { params(fallible_caps: T::Array[CapabilitySpec], clause: T.nilable(AST::ErrorClause), with_label: T.nilable(String), with_node: AST::WithBlock).returns(MIR::SortedLockAcquire) }
  def sorted_lock_acquire(fallible_caps, clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    fallible = !clause.nil?
    MIR::SortedLockAcquire.new(
      build_sorted_acquire_entries(fallible_caps, fallible: fallible, with_node: with_node),
      clause ? lock_failure_action(clause, with_label, with_node) : nil,
      clause&.matched_types || [],
      clause&.bubble_types || [],
      clause&.retries,
      with_node.token&.line.to_s,
      "__acq_sort_#{with_node.object_id.abs}",
      runtime_binding_name,
      fallible,
    )
  end

  private :emit_snapshot_mutable_call,
    :polymorphic_flow_required?

  private :append_fallible_clause
  private :assemble_with_block
  private :ast_contains_return?
  private :borrowed_capability_binding
  private :borrowed_const_param_alias?
  private :build_fallible_clause_mir
  private :build_field_path_zig
  private :build_sorted_acquire_entries
  private :coop_yield_mir
  private :default_failure_action
  private :error_action_stmts
  private :exclusive_capability_binding
  private :exclusive_lock_expr
  private :exclusive_lock_sync
  private :clause_failure_action_kind
  private :guard_fail_flow_body
  private :lower_polymorphic_universal
  private :lower_with_match_block
  private :materialize_sorted_lock_bindings
  private :materialize_with_capability_binding
  private :materialized_view_capability_bindings
  private :multi_mutable_snapshot_txn
  private :mutable_snapshot_cap
  private :mutable_snapshot_plan
  private :mutable_snapshot_with?
  private :read_locked_capability_binding
  private :restrict_capability_binding
  private :safe_with_capability_alias
  private :shared_capability_binding
  private :single_mutable_snapshot_txn
  private :snapshot_capability_binding
  private :sorted_lock_acquire
  private :structured_with_bindings
  private :view_capability_binding
  private :with_binding_materialization
  private :with_block_body_stmts
  private :with_block_control_label
  private :with_block_inline_bindings
  private :with_cap_is_param?
  private :with_cap_zig_target
  private :with_capability_alias_maps
  private :with_capability_binding_context
  private :with_capability_specs

end
