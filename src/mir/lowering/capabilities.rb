# typed: strict
require "sorbet-runtime"
require_relative "../../ast/lexer"
require_relative "../../backends/zig_type"

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

  CapabilitySpecValue = T.type_alias { T.any(AST::Node, Type, Symbol, String, T::Boolean, NilClass) }
  CapabilitySpec = T.type_alias { T.any(AST::Capability, T::Hash[Symbol, CapabilitySpecValue]) }
  CapabilityVarNode = T.type_alias { T.any(AST::Identifier, AST::GetField) }
  WithBindingNode = T.type_alias { T.any(String, MIR::Node) }

  class FallibleClauseFact < T::Struct
    const :var_name, String
    const :alias_name, String
    const :action_kind, Symbol
    const :retries, T.nilable(Integer)
    const :matched_types, T::Array[Symbol]
    const :bubble_types, T::Array[Symbol]
    const :action_mir, T.nilable(T::Array[MIR::Emittable])
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

  class FallibleLockBindingPlan < T::Struct
    const :acquire_call, String
    const :guard_var, String
    const :alias_name, String
    const :clause, AST::ErrorClause
    const :with_label, T.nilable(String)
    const :with_node, AST::WithBlock
    const :rt_name, String
    const :action_zig, String
    const :retries, T.nilable(Integer)
    const :matched_types, T::Array[Symbol]
    const :bubble_types, T::Array[Symbol]
    const :acquire_block, String
    const :source_line, String
  end

  class SortedAcquireEntry < T::Struct
    const :index, Integer
    const :alias_name, String
    const :guard_var, String
    const :held_var, String
    const :lock_expr, String
    const :addr_expr, String
    const :method_name, String
  end

  class LockBindingPlan < T::Struct
    const :guard_var, String
    const :alias_name, String
    const :lock_expr, String
    const :lock_sync, T.nilable(Symbol)
    const :clause, T.nilable(AST::ErrorClause)
    const :with_label, T.nilable(String)
    const :with_node, AST::WithBlock
  end

  class MutableSnapshotCap < T::Struct
    const :var_node, CapabilityVarNode
    const :alias_name, String
    const :source_zig, String
    const :bare_type_zig, String
    const :conflict_error, Symbol
  end

  class MutableSnapshotPlan < T::Struct
    const :node, AST::WithBlock
    const :with_label, T.nilable(String)
    const :rt_name, String
    const :alloc_zig, String
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

  sig { params(var_node: CapabilityVarNode).returns(String) }
  def with_cap_var_name(var_node)
    T.bind(self, MIRLowering) rescue nil
    case var_node
    when AST::GetField then var_node.field.to_s
    else
      var_node.respond_to?(:name) ? var_node.name : var_node.to_s
    end
  end

  # Sync + storage flags for the bound entity.
  # Identifier → from the symbol entry (post-propagation).
  # GetField   → from the field's declared type (carries @sync/@ownership
  #              from the struct field declaration).
  #
  # Inside a fiber-like callback (BG/BG STREAM/DO/CONCURRENT), prefer
  # the LIVE SymbolEntry from capture_state.current_fiber_capture_symbols. The AST
  # node's var_node.symbol can carry a stale snapshot of sync/storage;
  # the live entry was refreshed by EscapeAnalysis.propagate_caller_sync!
  # and recorded into capture_analysis.capture_symbols during annotation.
  # This is what makes WITH EXCLUSIVE c inside a
  # CONCURRENT EACH callback take the direct c.ctrl.data.* Arc-unwrap
  # path (storage = :shared) instead of the polymorphic c.* path that
  # only works for non-Arc parameters.
  sig { params(var_node: CapabilityVarNode).returns(T::Array[T.nilable(Symbol)]) }
  def with_cap_sync_storage(var_node)
    T.bind(self, MIRLowering) rescue nil
    if var_node.is_a?(AST::GetField)
      ft = var_node.full_type!(context: "WITH field capability")
      sync = ft.sync
      storage = ft.ownership_storage
      return [sync, storage]
    end
    if var_node.is_a?(AST::Identifier) &&
       (live = capture_state.current_fiber_capture_symbols&.dig(var_node.name))
      return [live.sync, live.storage]
    end
    sym = var_node.symbol
    ti = var_node.full_type!(context: "WITH capability variable")
    [sym&.sync || ti&.sync, sym&.storage]
  end

  sig { params(capability: T.any(AST::Capability, T::Hash[Symbol, T.untyped])).returns(T::Array[T.untyped]) }
  def with_alias_ownership_marks(capability)
    []
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

  # Comptime-dispatched lock target: at compile time, Zig picks
  # `x.ctrl.data.*` if the underlying type is `Arc(...)` (has a `ctrl`
  # field), else the bare value. The same fn body then works for both
  # `Locked(T)` and `Arc(Locked(T))` callers without runtime overhead.
  # Mutable parameters arrive as `*T`, so probe and deref through `*`.
  sig { params(zig_var: String).returns(String) }
  def comptime_arc_unwrap_expr(zig_var)
    T.bind(self, MIRLowering) rescue nil
    "#{with_match_unwrap_value(zig_var)}.*"
  end

  sig { params(lock_expr: String, var_sync: T.nilable(Symbol), fallible: T::Boolean).returns(String) }
  def lock_acquire_call_expr(lock_expr, var_sync, fallible)
    T.bind(self, MIRLowering) rescue nil
    if var_sync == :write_locked
      return "#{lock_expr}.#{fallible ? "writeOrErr" : "write"}()"
    end
    if var_sync == :locked
      return "#{lock_expr}.#{fallible ? "acquireOrErr" : "acquire"}()"
    end

    write_method = fallible ? "writeOrErr" : "write"
    acquire_method = fallible ? "acquireOrErr" : "acquire"
    "(if (comptime @hasDecl(@TypeOf(#{lock_expr}), \"#{write_method}\")) " \
      "#{lock_expr}.#{write_method}() else #{lock_expr}.#{acquire_method}())"
  end

  # Recursively build the Zig string for a (possibly nested) field path.
  # Stops at the root Identifier; intermediate GetFields chain via `.`.
  sig { params(node: T.untyped).returns(String) }
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
    fallible_caps = caps.select { |cap| [:EXCLUSIVE, :write_locked_read].include?(cap[:capability]) }
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
    node.capabilities || []
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
      materialization.add_binding(emit_sorted_lock_acquires_fallible(fallible_caps, clause, with_label, node))
      fallible_caps.each do |cap|
        var_name = with_cap_var_name(T.cast(cap[:var_node], CapabilityVarNode))
        alias_name = (cap[:alias] || var_name).to_s
        materialization.add_fallible_clause(build_fallible_clause_mir(var_name, alias_name, clause))
      end
    else
      materialization.add_binding(emit_sorted_lock_acquires(fallible_caps, node))
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
    var_node = T.cast(cap[:var_node], CapabilityVarNode)
    var_name = with_cap_var_name(var_node)
    alias_name = (cap[:alias] || var_name).to_s
    resolved = with_cap_resolved_type(cap)
    var_sync, var_storage = with_cap_sync_storage(var_node)
    WithCapabilityBindingContext.new(
      node: node,
      cap: cap,
      var_node: var_node,
      var_name: var_name,
      alias_name: alias_name,
      resolved_type: resolved,
      var_sync: var_sync,
      var_storage: var_storage,
      zig_var: with_cap_zig_target(var_node, var_name),
      clause: clause,
      with_label: with_label,
      needs_sort: needs_sort,
      rt_name: rt_name,
    )
  end

  sig { params(cap: CapabilitySpec).returns(T.nilable(Type)) }
  def with_cap_resolved_type(cap)
    resolved_type = cap[:resolved_type]
    return nil unless resolved_type

    Type.from_node!(resolved_type, context: "WITH capability resolved_type")
  end

  sig { params(materialization: WithBindingMaterialization, context: WithCapabilityBindingContext).void }
  def materialize_with_capability_binding(materialization, context)
    case context.cap[:capability]
    when :multiowned, :shared
      materialization.add_binding(shared_capability_binding(context))
    when :EXCLUSIVE
      exclusive = exclusive_capability_binding(context)
      materialization.add_binding(exclusive) if exclusive
      append_fallible_clause(materialization, context) if exclusive && context.clause
    when :write_locked_read
      read_lock = read_locked_capability_binding(context)
      materialization.add_binding(read_lock) if read_lock
      append_fallible_clause(materialization, context) if read_lock && context.clause
    when :BORROWED
      materialization.add_binding(borrowed_capability_binding(context))
    when :RESTRICT
      restrict = restrict_capability_binding(context)
      materialization.add_binding(restrict) if restrict
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

  sig { params(var_node: CapabilityVarNode).returns(String) }
  def with_capability_source_zig(var_node)
    lowerer = T.cast(self, MIRLowering)
    T.cast(lowerer.emit_expr(lowerer.lower(var_node)), String)
  end

  sig { params(alias_name: String).returns(String) }
  def safe_with_capability_alias(alias_name)
    cleaned = (alias_name.end_with?("!") || alias_name.end_with?("?")) ? T.must(alias_name[0..-2]) : alias_name
    cleaned = "clearMain" if cleaned == "main"
    ZigType.primitive_numeric_identifier?(cleaned) ? "@\"#{cleaned}\"" : cleaned
  end

  sig { params(context: WithCapabilityBindingContext).returns(String) }
  def shared_capability_binding(context)
    inner = "__#{context.var_name}_unwrap"
    "const #{inner} = #{context.zig_var}.ctrl.data.*;\n_ = &#{inner};"
  end

  sig { params(context: WithCapabilityBindingContext, lock_expr: String, lock_sync: T.nilable(Symbol)).returns(LockBindingPlan) }
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

  sig { params(plan: LockBindingPlan, acquire_call: String).returns(String) }
  def render_lock_binding(plan, acquire_call)
    clause = plan.clause
    return emit_fallible_lock_binding(acquire_call, plan.guard_var, plan.alias_name, clause, plan.with_label, plan.with_node) if clause

    "var #{plan.guard_var} = #{acquire_call};\ndefer #{plan.guard_var}.release();\nconst #{plan.alias_name} = #{plan.guard_var}.get();\n_ = &#{plan.alias_name};"
  end

  sig { params(context: WithCapabilityBindingContext).returns(String) }
  def exclusive_lock_expr(context)
    is_arc = SymbolEntry.rc_storage?(context.var_storage) || context.resolved_type&.any_rc?
    is_param = with_cap_is_param?(context.var_node)
    return comptime_arc_unwrap_expr(context.zig_var) if is_param && !is_arc

    is_arc ? "#{context.zig_var}.ctrl.data.*" : context.zig_var
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(Symbol)) }
  def exclusive_lock_sync(context)
    is_param = with_cap_is_param?(context.var_node)
    context.node.polymorphic && is_param ? nil : context.var_sync
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(String)) }
  def exclusive_capability_binding(context)
    return nil if context.needs_sort

    plan = lock_binding_plan(context, exclusive_lock_expr(context), exclusive_lock_sync(context))
    render_lock_binding(plan, lock_acquire_call_expr(plan.lock_expr, plan.lock_sync, !plan.clause.nil?))
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(String)) }
  def read_locked_capability_binding(context)
    return nil if context.needs_sort

    is_arc = SymbolEntry.rc_storage?(context.var_storage) || context.resolved_type&.any_rc?
    lock_expr = is_arc ? "#{context.zig_var}.ctrl.data.*" : context.zig_var
    plan = lock_binding_plan(context, lock_expr, nil)
    render_lock_binding(plan, plan.clause ? "#{lock_expr}.readOrErr()" : "#{lock_expr}.read()")
  end

  sig { params(context: WithCapabilityBindingContext).returns(String) }
  def borrowed_capability_binding(context)
    source_zig = with_capability_source_zig(context.var_node)
    is_param = with_cap_is_param?(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    if borrowed_const_param_alias?(context, is_param)
      aliased_value = with_match_unwrap_value(source_zig)
      "const #{safe_alias} = #{aliased_value};\n_ = &#{safe_alias};"
    else
      "const #{safe_alias} = #{source_zig};\n_ = &#{safe_alias};"
    end
  end

  sig { params(context: WithCapabilityBindingContext, is_param: T::Boolean).returns(T::Boolean) }
  def borrowed_const_param_alias?(context, is_param)
    sym = context.var_node.symbol
    is_param && (context.var_sync.nil? || context.var_sync == :local) &&
      sym && !sym.mutable
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(String)) }
  def restrict_capability_binding(context)
    return nil unless context.var_sync.nil? || context.var_sync == :local

    source_zig = with_capability_source_zig(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    if with_cap_is_param?(context.var_node)
      "const #{safe_alias} = #{with_match_unwrap_value(source_zig)};"
    elsif context.var_sync == :local
      "const #{safe_alias} = #{source_zig};"
    elsif context.cap[:alias_mutable]
      "const #{safe_alias} = &#{source_zig};"
    else
      "const #{safe_alias} = #{source_zig};\n_ = &#{safe_alias};"
    end
  end

  sig { params(context: WithCapabilityBindingContext).returns(String) }
  def view_capability_binding(context)
    source_zig = with_capability_source_zig(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    rt = context.resolved_type || Type.new(:Any)
    inner_t = rt.future? ? rt.tense_type : rt
    wrapped_inner = inner_t.wrapped_type
    is_value_shape = inner_t.primitive? || inner_t.string? ||
                     (inner_t.optional? && wrapped_inner &&
                      (wrapped_inner.primitive? || wrapped_inner.string?))
    wants_release = !is_value_shape && (inner_t.collection_value? || !inner_t.primitive?)
    coop_yield = "if (CheatHeader.scheduler.scheduler_running) { CheatHeader.scheduler.active_scheduler.drainChannels(); CheatHeader.scheduler.active_scheduler.coopYield(); }"
    if wants_release
      "var #{safe_alias} = #{source_zig}.view();\ndefer #{safe_alias}.release();\n#{coop_yield}\n_ = &#{safe_alias};"
    else
      "const #{safe_alias} = #{source_zig}.view();\n#{coop_yield}\n_ = &#{safe_alias};"
    end
  end

  sig { params(context: WithCapabilityBindingContext).returns(T.nilable(MIR::SnapshotRead)) }
  def snapshot_capability_binding(context)
    any_mutable = with_capability_specs(context.node).any? { |cap| cap[:capability] == :SNAPSHOT && cap[:alias_mutable] }
    return nil if any_mutable

    source_zig = with_capability_source_zig(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    guard_var = "__#{context.var_name}_snap_#{context.node.object_id.abs}"
    MIR::SnapshotRead.new(with_match_unwrap_value(source_zig), context.rt_name, safe_alias, guard_var, nil)
  end

  sig { params(context: WithCapabilityBindingContext).returns(T::Array[WithBindingNode]) }
  def materialized_view_capability_bindings(context)
    source_zig = with_capability_source_zig(context.var_node)
    safe_alias = safe_with_capability_alias(context.alias_name)
    rt = context.resolved_type || Type.new(:Any)
    is_collection = rt.observable_array_future? || rt.array?
    materialize = MIR::MethodCall.new(
      MIR::Ident.new(source_zig),
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
    return nil unless clause && (clause.action == :pass || clause.action == :block)

    "__with_#{node.object_id.abs}"
  end

  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def mutable_snapshot_with?(node)
    with_capability_specs(node).any? do |cap|
      cap[:capability] == :SNAPSHOT && cap[:alias_mutable]
    end
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
      var_node = cap[:var_node]
      var_node.is_a?(AST::Identifier) ? var_node.name.to_s : nil
    end
  end

  sig { params(node: AST::WithBlock).returns(T::Array[MIR::Emittable]) }
  def with_alias_ownership_stmts(node)
    with_capability_specs(node).flat_map do |cap|
      with_alias_ownership_marks(cap)
    end
  end

  sig { params(materialization: WithBindingMaterialization, node: AST::WithBlock).returns(T.nilable(MIR::ZigTemplate)) }
  def with_block_inline_bindings(materialization, node)
    string_bindings = materialization.bindings.filter_map { |binding| binding if binding.is_a?(String) }.reject(&:empty?)
    all_bindings = string_bindings.join("\n")
    return nil if all_bindings.empty?

    bindings_iz = MIR::ZigTemplate.new(all_bindings, [], "with_block_bindings")
    stdlib_def = FunctionSignature.intrinsic_contract(borrows: with_block_borrow_names(node))
    clauses = materialization.fallible_clauses
    stdlib_def.emit.fallible_clauses = clauses unless clauses.empty?
    bindings_iz.stdlib_def = stdlib_def
    bindings_iz
  end

  sig { params(materialization: WithBindingMaterialization).returns(T::Array[MIR::Emittable]) }
  def structured_with_bindings(materialization)
    materialization.bindings.filter_map do |binding|
      binding if binding.is_a?(MIR::Emittable)
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
    stmts = with_alias_ownership_stmts(node)
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
    if node.universal_poly && (node.capabilities || []).length == 1
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

    (node.capabilities || []).each do |cap|
      var_node = cap[:var_node]
      var_name = var_node.respond_to?(:name) ? var_node.name : var_node.to_s
      alias_name = (cap[:alias] || var_name).to_s
      if cap[:alias]
        alias_alloc_map[alias_name] = T.unsafe(self).send(:placement_for_node, var_node)
        alias_owner_map[alias_name] = var_name.to_s
      end
      case cap[:capability]
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
    action_mir = T.let(nil, T.nilable(T::Array[MIR::Emittable]))
    exit_msg_mir = T.let(nil, T.nilable(MIR::Emittable))
    case clause.action
    when :block
      action_mir = lower_body(T.must(clause.body))
    when :exit
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


  # WITH MATCH lowers to a comptime if-else chain that probes the bound
  # variable's wrapper type. Zig elides not-taken branches, so one function
  # body works for every family declared in REQUIRES.
  #
  # Family probes:
  #   :VERSIONED  -> @hasDecl(<inner_type>, "Inner")
  #                  Versioned(T) re-exports `pub const Inner = T`;
  #                  Locked(T) and bare T do not.
  #   :LOCKED   -> @hasField(<inner_type>, "mutex")
  #                  Locked(T) has a `mutex` field; bare T doesn't.
  #   :LOCAL      -> else branch (no probe; runtime fallback).
  #
  # Each probe is wrapped in a comptime Arc unwrap so bare and Arc-wrapped
  # callers share the same generated body.

  # Per-family probe for WITH MATCH dispatch. Routes through the
  # comptime helper `CheatLib.WithMatchInner` (runtime-header.zig)
  # which peels off an outer pointer and an outer Arc-wrapper to
  # reach the cell type. The same probe then matches whether the
  # caller's binding is `@versioned`, `@shared:versioned`, `@locked`,
  # or `@shared:locked` -- the parameter shape (pointer-to-T vs
  # value-Arc(T)) is invisible to the probe.
  #
  # Recognized families today: LOCKED, VERSIONED. ACTOR and LOCK_FREE
  # are parser-reserved but have no probe yet (raise on use). See
  # WithMatchCheck.LOCKED_SYNCS / VERSIONED_SYNCS for the inverse
  # mapping that classifies a binding's family at the call site.
  sig { params(family: Symbol, zig_var: String, node: T.nilable(AST::WithBlock)).returns(String) }
  def with_match_probe_for_family(family, zig_var, node = nil)
    T.bind(self, MIRLowering) rescue nil
    inner_t = "CheatLib.WithMatchInner(@TypeOf(#{zig_var}))"
    snapshot = node.respond_to?(:snapshot_mode) && T.must(node).snapshot_mode
    case family
    # Versioned and AtomicPtr both expose `pub const Inner = T`, so a
    # bare `@hasDecl(..., "Inner")` probe would match AtomicPtr too.
    # That's harmless in non-SNAPSHOT WITH MATCH (Versioned/AtomicPtr
    # never appear in those polymorphic call sites today) but
    # silently miscompiles in SNAPSHOT MATCH where AtomicPtr cells
    # are first-class. Tighten with `!@hasDecl(..., "compareAndPublish")`
    # which is unique to AtomicPtr -- routes AtomicPtr cells to the
    # ATOMIC arm in SNAPSHOT MATCH.
    when :VERSIONED
      if snapshot
        "(@hasDecl(#{inner_t}, \"Inner\") and !@hasDecl(#{inner_t}, \"compareAndPublish\"))"
      else
        "@hasDecl(#{inner_t}, \"Inner\")"
      end
    when :LOCKED then "@hasField(#{inner_t}, \"mutex\")"
    # Primitive atomics expose `cmpxchgStrong`; AtomicPtr exposes
    # `compareAndPublish`. Pick the probe from the surrounding mode.
    when :ATOMIC
      if snapshot
        "@hasDecl(#{inner_t}, \"compareAndPublish\")"
      else
        "@hasDecl(#{inner_t}, \"cmpxchgStrong\")"
      end
    else
      raise "WITH MATCH: no probe for family #{family.inspect} (only " \
            ":VERSIONED, :LOCKED, :ATOMIC are wired today)"
    end
  end

  # Resolve to a `*Inner` value regardless of param shape. Invalid
  # expressions in not-taken comptime branches are elided by Zig.
  sig { params(zig_var: String).returns(String) }
  def with_match_unwrap_value(zig_var)
    T.bind(self, MIRLowering) rescue nil
    is_ptr  = "@typeInfo(@TypeOf(#{zig_var})) == .pointer"
    inner_t = "@typeInfo(@TypeOf(#{zig_var})).pointer.child"
    "(if (comptime #{is_ptr}) " \
      "(if (comptime @typeInfo(#{inner_t}) == .@\"struct\") " \
        "(if (comptime @hasField(#{inner_t}, \"ctrl\")) #{zig_var}.ctrl.data else #{zig_var}) " \
       "else " \
        "(if (comptime @typeInfo(#{inner_t}) == .pointer) " \
          "(if (comptime @typeInfo(@typeInfo(#{inner_t}).pointer.child) == .@\"struct\") " \
            "(if (comptime @hasField(@typeInfo(#{inner_t}).pointer.child, \"ctrl\")) #{zig_var}.*.ctrl.data else #{zig_var}.*) " \
           "else #{zig_var}.*) " \
         "else #{zig_var})) " \
    "else " \
      "(if (comptime @typeInfo(@TypeOf(#{zig_var})) == .@\"struct\") " \
        "(if (comptime @hasField(@TypeOf(#{zig_var}), \"ctrl\")) #{zig_var}.ctrl.data else &#{zig_var}) " \
       "else &#{zig_var}))"
  end

  # Per-arm prelude that binds the user's alias (`va` in
  # `WITH c AS va MATCH`) to a `*Inner` for this arm's family.
  # Both VERSIONED and LOCKED arms produce `const <alias>: *T = ...`
  # so the body's `<alias>.field` access lowers identically across
  # families. The Guard's `defer release()` handles teardown.
  sig { params(family: Symbol, zig_var: String, alias_name: String, node: AST::WithBlock).returns(T.nilable(String)) }
  def with_match_arm_prelude(family, zig_var, alias_name, node)
    T.bind(self, MIRLowering) rescue nil
    safe_alias = zig_safe_name(alias_name)
    rt_name = runtime_binding_name
    unwrap = with_match_unwrap_value(zig_var)
    guard_var = "__#{alias_name}_match_#{node.object_id.abs}"
    case family
    when :VERSIONED
      <<~ZIG.rstrip
        var #{guard_var} = #{unwrap}.*.read(#{rt_name});
        defer #{guard_var}.release();
        const #{safe_alias} = #{guard_var}.get();
        _ = &#{safe_alias};
      ZIG
    when :LOCKED
      <<~ZIG.rstrip
        var #{guard_var} = #{unwrap}.*.acquire();
        defer #{guard_var}.release();
        const #{safe_alias} = #{guard_var}.get();
        _ = &#{safe_alias};
      ZIG
    # Atomic primitives have no Guard/acquire/release; the alias binds
    # directly to the cell pointer so arm bodies can call atomic methods.
    #
    # In SNAPSHOT MATCH, AtomicPtr binds through a Guard like VERSIONED.
    # Mutable publish-via-CAS requires a larger lowering change.
    when :ATOMIC
      if node.respond_to?(:snapshot_mode) && node.snapshot_mode
        <<~ZIG.rstrip
          var #{guard_var} = #{unwrap}.*.read(#{rt_name});
          defer #{guard_var}.release();
          const #{safe_alias} = #{guard_var}.get();
          _ = &#{safe_alias};
        ZIG
      else
        <<~ZIG.rstrip
          const #{safe_alias} = #{unwrap};
          _ = &#{safe_alias};
        ZIG
      end
    end
  end

  sig { params(node: AST::WithBlock).returns(MIR::ScopeBlock) }
  def lower_with_match_block(node)
    T.bind(self, MIRLowering) rescue nil
    cap = node.capabilities.first
    var_name = with_cap_var_name(cap[:var_node])
    zig_var  = with_cap_zig_target(cap[:var_node], var_name)
    alias_name = cap[:alias] || var_name

    arms_meta = node.arms.map { |arm|
      {
        family:      arm[:family],
        probe:       with_match_probe_for_family(arm[:family], zig_var, node),
        prelude_zig: with_match_arm_prelude(arm[:family], zig_var, alias_name, node),
        body:        lower_body(arm[:body]),
      }
    }
    MIR::ScopeBlock.new([MIR::WithMatchDispatch.new(zig_var, arms_meta)])
  end

  # Emit the acquire-or-catch binding for a fallible lock under a
  # WithBlock#lock_error_clause. The switch dispatches per error type
  # using the error registry:
  #   - Types in clause.matched_types  -> run the user action.
  #   - Types in clause.bubble_types   -> setError(kind, name) + return
  #                                         error.CheatError.
  # Deadlock is always in bubble_types unless the user explicitly selected
  # it (e.g. `ON :Deadlock -> { ... }`), in which case its action runs.
  sig { params(acquire_call: String, guard_var: String, alias_name: String, clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock).returns(FallibleLockBindingPlan) }
  def fallible_lock_binding_plan(acquire_call, guard_var, alias_name, clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    rt_name = runtime_binding_name
    FallibleLockBindingPlan.new(
      acquire_call: acquire_call,
      guard_var: guard_var,
      alias_name: alias_name,
      clause: clause,
      with_label: with_label,
      with_node: with_node,
      rt_name: rt_name,
      action_zig: emit_lock_action_zig(clause, with_label, with_node),
      retries: clause.retries,
      matched_types: clause.matched_types,
      bubble_types: clause.bubble_types,
      acquire_block: "__acq_#{with_node.object_id.abs}_#{guard_var}",
      source_line: with_node.token&.line.to_s,
    )
  end

  sig { params(plan: FallibleLockBindingPlan).returns(String) }
  def fallible_lock_error_handler(plan)
    matched_arms = plan.matched_types.map do |type_name|
      matched_errs = "error.#{AST.zig_name_of_type(type_name)}"
      body = plan.retries ? "if (__retry + 1 < #{plan.retries}) continue;\n#{plan.action_zig}" : plan.action_zig
      "#{matched_errs} => { #{body} }"
    end
    bubble_arms = plan.bubble_types.map do |type_name|
      zig = AST.zig_name_of_type(type_name)
      kind = AST.kind_of_type(type_name)
      %Q(error.#{zig} => { #{plan.rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{zig}), "lock #{zig}", #{plan.source_line}); return error.CheatError; })
    end
    arms = matched_arms + bubble_arms
    "switch (__err) {\n#{arms.join(",\n")}\n}"
  end

  sig { params(plan: FallibleLockBindingPlan).returns(String) }
  def fallible_lock_acquire_expr(plan)
    handler = fallible_lock_error_handler(plan)
    if plan.retries
      <<~ZIG.rstrip
        #{plan.acquire_block}: {
          var __retry: usize = 0;
          while (true) : (__retry += 1) {
            if (#{plan.acquire_call}) |__g| {
              break :#{plan.acquire_block} __g;
            } else |__err| {
              #{handler}
            }
          }
        }
      ZIG
    else
      <<~ZIG.rstrip
        #{plan.acquire_block}: {
          if (#{plan.acquire_call}) |__g| {
            break :#{plan.acquire_block} __g;
          } else |__err| {
            #{handler}
          }
        }
      ZIG
    end
  end

  sig { params(acquire_call: String, guard_var: String, alias_name: String, clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock).returns(String) }
  def emit_fallible_lock_binding(acquire_call, guard_var, alias_name, clause, with_label, with_node)
    plan = fallible_lock_binding_plan(acquire_call, guard_var, alias_name, clause, with_label, with_node)
    <<~ZIG.rstrip
      var #{plan.guard_var} = #{fallible_lock_acquire_expr(plan)};
      defer #{plan.guard_var}.release();
      const #{plan.alias_name} = #{plan.guard_var}.get();
      _ = &#{plan.alias_name};
    ZIG
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
  # runtime heap allocation instead of treating them as opaque InlineZig.
  sig { params(node: AST::WithBlock).returns(MIR::ScopeBlock) }
  def lower_polymorphic_universal(node)
    T.bind(self, MIRLowering) rescue nil
    cap = node.capabilities.first
    var_node   = cap[:var_node]
    var_name   = with_cap_var_name(var_node)
    alias_name = cap[:alias] || var_name
    safe_alias = zig_safe_name(alias_name)
    # Emit the cell raw, with no auto-`.load()` injection. The atomic-
    # cell read path that visit_Identifier installs (line 4056 in
    # annotator/helpers/cell access) wraps `@atomic` reads in `.load()`,
    # which returns a value -- but `polymorphicMutate` needs the cell
    # OBJECT to dispatch by `@hasDecl`. Set capability_state.atomic_emit_raw so the
    # surrounding emit_expr returns the bare ident.
    prev_raw = capability_state.atomic_emit_raw
    capability_state.atomic_emit_raw = true
    cell_zig = emit_expr(lower(var_node))
    capability_state.atomic_emit_raw = prev_raw
    cell_zig = "&#{cell_zig}"
    # The body's `x` alias is a `*T` -- grab the bare T (post-Arc,
    # post-sync-wrapper) for the closure signature.
    resolved_source = cap[:resolved_type] || var_node
    rt_obj = Type.from_node!(resolved_source, context: "WITH polymorphic capability resolved type")
    bare_t_zig = rt_obj.respond_to?(:bare_data_type) ? rt_obj.bare_data_type.zig_type : rt_obj.zig_type
    body_mir = lower_body(node.body)
    guard_cond = combined_guard_cond(node)
    if polymorphic_flow_required?(node)
      guard_fail = guard_cond ? guard_fail_flow_body(node) : []
      return MIR::ScopeBlock.new([MIR::PolymorphicMutateFlow.new(
        cell_zig, runtime_binding_name, safe_alias, bare_t_zig,
        current_function_return_payload_zig || "void",
        body_mir, guard_cond, guard_fail
      )])
    else
      body_mir = wrap_body_with_guard(node, body_mir, nil)
      MIR::ScopeBlock.new([MIR::PolymorphicMutate.new(cell_zig, runtime_binding_name, safe_alias, bare_t_zig, body_mir)])
    end
  end

  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def polymorphic_flow_required?(node)
    T.bind(self, MIRLowering) rescue nil
    return true if (node.capabilities || []).any? { |cap| cap[:guard_expr] }
    ast_contains_return?(node.body)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def ast_contains_return?(node)
    T.bind(self, MIRLowering) rescue nil
    case node
    when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      false
    when Array
      node.any? { |item| ast_contains_return?(item) }
    when Hash
      node.values.any? { |item| ast_contains_return?(item) }
    when AST::FunctionDef
      false
    when AST::ReturnNode
      true
    else
      node.respond_to?(:each_pair) && node.each_pair.any? { |_, v| ast_contains_return?(v) }
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
    when :pass
      result
    when :return
      result << MIR::ReturnStmt.new(lower(T.must(clause.value)))
    when :raise
      result << MIR::ExprStmt.new(no_ownership_call("#{runtime_binding_name}.setError", [
        MIR::Ident.new(".Transient"),
        no_ownership_call("@intFromEnum", [MIR::Ident.new("ErrorName.GuardFail")]),
        MIR::Lit.new(zig_string_lit("WITH GUARD predicate failed")),
        MIR::Lit.new(line),
      ]), false)
      result << MIR::PolymorphicFlowSignal.new(:raise_no_commit, nil)
    when :exit
      msg_zig = emit_expr(lower(T.must(clause.message)))
      result << MIR::ExprStmt.new(no_ownership_call("#{runtime_binding_name}.setError", [
        MIR::Ident.new(".Transient"),
        no_ownership_call("@intFromEnum", [MIR::Ident.new("ErrorName.GuardFail")]),
        MIR::Lit.new(msg_zig),
        MIR::Lit.new(line),
      ]), false)
      result << MIR::PolymorphicFlowSignal.new(:raise_no_commit, nil)
    when :block
      result.concat(lower_body(T.must(clause.body)))
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
        MIR::ExprStmt.new(no_ownership_call("#{runtime_binding_name}.setError", [
          MIR::Ident.new(".Input"),
          no_ownership_call("@intFromEnum", [MIR::Ident.new("ErrorName.PreconditionFail")]),
          MIR::Lit.new(msg_zig),
          MIR::Lit.new(line),
        ]), false),
        MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError")),
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

  sig { params(node: AST::WithBlock, body_mir: T::Array[T.untyped], with_label: T.nilable(String)).returns(T::Array[T.untyped]) }
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
    guarded = (node.capabilities || []).select { |cap| cap[:guard_expr] }
    return nil if guarded.empty?
    guarded.map { |g| lower(g[:guard_expr]) }
           .reduce { |acc, e| MIR::BinOp.new("and", acc, e) }
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String)).returns(T.nilable(T::Array[T.untyped])) }
  def guard_fail_body(node, with_label)
    T.bind(self, MIRLowering) rescue nil
    clause = node.lock_error_clause
    return nil unless clause && clause.matched_types.include?(:GuardFail)

    error_action_stmts(clause, with_label, node, :GuardFail, "WITH GUARD predicate failed")
  end

  sig { params(clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock, error_type: Symbol, default_msg: String).returns(T::Array[MIR::Emittable]) }
  def error_action_stmts(clause, with_label, with_node, error_type, default_msg)
    T.bind(self, MIRLowering) rescue nil
    line = with_node.token&.line.to_s
    err_name = error_type.to_s
    kind = AST.kind_of_type(error_type) || :Transient
    case clause.action
    when :raise
      [
        MIR::ExprStmt.new(no_ownership_call("#{runtime_binding_name}.setError", [
          MIR::Ident.new(".#{kind}"),
          no_ownership_call("@intFromEnum", [MIR::Ident.new("ErrorName.#{err_name}")]),
          MIR::Lit.new(zig_string_lit(default_msg)),
          MIR::Lit.new(line),
        ]), false),
        MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError")),
      ]
    when :exit
      msg_zig = emit_expr(lower(T.must(clause.message)))
      [
        MIR::ExprStmt.new(no_ownership_call("#{runtime_binding_name}.setError", [
          MIR::Ident.new(".#{kind}"),
          no_ownership_call("@intFromEnum", [MIR::Ident.new("ErrorName.#{err_name}")]),
          MIR::Lit.new(msg_zig),
          MIR::Lit.new(line),
        ]), false),
        MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError")),
      ]
    when :pass
      [MIR::BreakStmt.new(T.must(with_label), nil)]
    when :return
      [MIR::ReturnStmt.new(lower(T.must(clause.value)))]
    when :block
      lower_body(T.must(clause.body)) + [MIR::BreakStmt.new(T.must(with_label), nil)]
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
      alloc_zig: "#{rt_name}.heapAlloc()",
      body_mir: body_mir,
      retries: node.lock_error_clause&.retries,
      capabilities: with_capability_specs(node).map { |cap| mutable_snapshot_cap(lowerer, cap) },
    )
  end

  sig { params(lowerer: MIRLowering, cap: CapabilitySpec).returns(MutableSnapshotCap) }
  def mutable_snapshot_cap(lowerer, cap)
    var_node = T.cast(cap[:var_node], CapabilityVarNode)
    var_name = with_cap_var_name(var_node)
    sym = var_node.symbol
    resolved_type = Type.from_node!(cap[:resolved_type], context: "mutable snapshot capability type")
    MutableSnapshotCap.new(
      var_node: var_node,
      alias_name: (cap[:alias] || var_name).to_s,
      source_zig: T.must(lowerer.emit_expr(lowerer.lower(var_node))),
      bare_type_zig: resolved_type.bare_data_type.zig_type,
      conflict_error: sym && sym.atomic? && sym.indirect? ? :AtomicConflict : :MvccConflict,
    )
  end

  sig { params(plan: MutableSnapshotPlan, cap: MutableSnapshotCap).returns(MIR::SnapshotTransaction) }
  def single_mutable_snapshot_txn(plan, cap)
    conflict_action = emit_conflict_action_zig(plan.node.lock_error_clause, plan.with_label, plan.node, cap.conflict_error)
    MIR::SnapshotTransaction.new(
      with_match_unwrap_value(cap.source_zig),
      plan.rt_name,
      plan.alloc_zig,
      safe_with_capability_alias(cap.alias_name),
      cap.bare_type_zig,
      plan.body_mir,
      conflict_action,
      plan.retries,
      plan.with_label,
      cap.conflict_error == :AtomicConflict,
    )
  end

  sig { params(plan: MutableSnapshotPlan).returns(String) }
  def mutable_snapshot_cells_tuple(plan)
    cells = plan.capabilities.map(&:source_zig)
    ".{ #{cells.join(", ")} }"
  end

  sig { params(plan: MutableSnapshotPlan).returns(String) }
  def mutable_snapshot_alias_decls(plan)
    plan.capabilities.each_with_index.map do |cap, index|
      safe_alias = safe_with_capability_alias(cap.alias_name)
      "const #{safe_alias} = views[#{index}]; _ = &#{safe_alias};"
    end.join("\n            ")
  end

  sig { params(plan: MutableSnapshotPlan).returns(MIR::SnapshotMultiTxn) }
  def multi_mutable_snapshot_txn(plan)
    conflict_action = emit_conflict_action_zig(plan.node.lock_error_clause, plan.with_label, plan.node, :MvccConflict)
    MIR::SnapshotMultiTxn.new(
      mutable_snapshot_cells_tuple(plan),
      plan.rt_name,
      plan.alloc_zig,
      mutable_snapshot_alias_decls(plan),
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

  # Emit the user's snapshot-conflict action using the conflict error chosen
  # for the cell family. Retry loops are handled around the transaction call,
  # not inside this action.
  sig { params(clause: T.nilable(AST::ErrorClause), with_label: T.nilable(String), with_node: AST::WithBlock, conflict_error: Symbol).returns(String) }
  def emit_conflict_action_zig(clause, with_label, with_node, conflict_error = :MvccConflict)
    T.bind(self, MIRLowering) rescue nil
    line = with_node.token&.line.to_s
    err_name = conflict_error.to_s
    msg = err_name == "AtomicConflict" ? "atomic CAS retries exhausted" : "MVCC commit conflict"
    return %Q(#{runtime_binding_name}.setError(.Transient, @intFromEnum(ErrorName.#{err_name}), "#{msg}", #{line});\nreturn error.CheatError;) unless clause
    emit_error_action_zig(clause, with_label, with_node, conflict_error, msg)
  end

  # Zig statements for the matched-selector action. Must terminate: return
  # / @panic, or break :__with_<id> (for PASS / `-> { }`).
  sig { params(clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock).returns(String) }
  def emit_lock_action_zig(clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    emit_error_action_zig(clause, with_label, with_node, :LockTimeout, "lock acquire timed out")
  end

  sig { params(clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock, error_type: Symbol, default_msg: String).returns(String) }
  def emit_error_action_zig(clause, with_label, with_node, error_type, default_msg)
    T.bind(self, MIRLowering) rescue nil
    line = with_node.token&.line.to_s
    err_name = error_type.to_s
    kind = AST.kind_of_type(error_type) || :Transient
    case clause.action
    when :raise
      %Q(#{runtime_binding_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{err_name}), "#{default_msg}", #{line});\nreturn error.CheatError;)
    when :exit
      msg_zig = emit_expr(lower(T.must(clause.message)))
      %Q(#{runtime_binding_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{err_name}), #{msg_zig}, #{line});\nreturn error.CheatError;)
    when :pass
      "break :#{with_label};"
    when :return
      value_zig = emit_expr(lower(T.must(clause.value)))
      "return #{value_zig};"
    when :block
      body_zig = emit_stmts_zig(lower_body(T.must(clause.body)))
      "#{body_zig}\nbreak :#{with_label};"
    else
      raise "Internal: unknown lock action #{clause.action}"
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
  sig { params(fallible_caps: T::Array[CapabilitySpec], fallible: T::Boolean, with_node: T.nilable(AST::WithBlock)).returns(T::Array[SortedAcquireEntry]) }
  def build_sorted_acquire_entries(fallible_caps, fallible:, with_node: nil)
    T.bind(self, MIRLowering) rescue nil
    suffix = with_node ? "_#{with_node.object_id.abs}" : ""
    fallible_caps.each_with_index.map do |cap, i|
      var_name   = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : cap[:var_node].to_s
      alias_name = cap[:alias] || var_name
      resolved   = cap[:resolved_type]
      zig_var    = capture_state.do_capture_map&.dig(var_name) || var_name
      var_storage = cap[:var_node].symbol&.storage
      is_arc = SymbolEntry.rc_storage?(var_storage) || resolved&.any_rc?
      lock_expr  = is_arc ? "#{zig_var}.ctrl.data.*" : zig_var
      addr_expr  = is_arc ? "#{zig_var}.ctrl.data" : "&#{zig_var}"
      var_sync   = cap[:var_node].symbol&.sync
      panic_method, err_method = case cap[:capability]
                                 when :EXCLUSIVE
                                   var_sync == :write_locked ? %w[write writeOrErr] : %w[acquire acquireOrErr]
                                 when :write_locked_read
                                   %w[read readOrErr]
                                 end
      SortedAcquireEntry.new(
        index: i,
        alias_name: alias_name.to_s,
        guard_var: "__sort_guard#{suffix}_#{i}",
        held_var: "__held#{suffix}_#{i}",
        lock_expr: lock_expr,
        addr_expr: addr_expr,
        method_name: (fallible ? err_method : panic_method).to_s,
      )
    end
  end

  # Emit Zig for acquiring N>=2 fallible lock captures in runtime
  # pointer-address order. Produces:
  #   - one __guardN per capture (undefined, typed via @TypeOf)
  #   - a __ptrs array of usize addresses
  #   - a __order index array, bubble-sorted by __ptrs
  #   - a for-loop over __order with a switch to call the right acquire()
  #   - defer __guardN.release() for each guard
  #   - const alias = __guardN.get() aliases
  # Uses panic-variant acquire methods (acquire / read / write); no
  # ON-clause handling. The fallible-variant emitter sits beside this.
  sig { params(fallible_caps: T::Array[CapabilitySpec], with_node: T.nilable(AST::WithBlock)).returns(String) }
  def emit_sorted_lock_acquires(fallible_caps, with_node = nil)
    T.bind(self, MIRLowering) rescue nil
    n = fallible_caps.length
    entries = build_sorted_acquire_entries(fallible_caps, fallible: false, with_node: with_node)

    guard_decls = entries.map { |e|
      "var #{e.guard_var}: @TypeOf(#{e.lock_expr}.#{e.method_name}()) = undefined;"
    }.join("\n")

    ptr_init = entries.map { |e| "@intFromPtr(#{e.addr_expr})" }.join(", ")
    order_init = (0...n).to_a.join(", ")

    switch_arms = entries.map { |e|
      "#{e.index} => #{e.guard_var} = #{e.lock_expr}.#{e.method_name}(),"
    }.join("\n                ")

    defer_releases = entries.map { |e| "defer #{e.guard_var}.release();" }.join("\n")
    alias_decls    = entries.map { |e|
      "const #{e.alias_name} = #{e.guard_var}.get();\n_ = &#{e.alias_name};"
    }.join("\n")

    <<~ZIG.rstrip
      #{guard_decls}
      {
          const __ptrs = [_]usize{ #{ptr_init} };
          var __order = [_]u8{ #{order_init} };
          var __i: usize = 0;
          while (__i < #{n}) : (__i += 1) {
              var __j: usize = 0;
              while (__j + 1 < #{n}) : (__j += 1) {
                  if (__ptrs[__order[__j]] > __ptrs[__order[__j + 1]]) {
                      const __tmp = __order[__j];
                      __order[__j] = __order[__j + 1];
                      __order[__j + 1] = __tmp;
                  }
              }
          }
          for (__order) |__idx| {
              switch (__idx) {
                #{switch_arms}
                else => unreachable,
              }
          }
      }
      #{defer_releases}
      #{alias_decls}
    ZIG
  end

  # Fallible variant of emit_sorted_lock_acquires. Uses the OrErr
  # acquire methods, tracks held guards in a per-cap bool, and on any
  # acquisition error releases held guards in reverse-acquisition order
  # before either retrying (`RETRY(N) THEN ...`) or running the user's
  # ON action. Defers at WITH-scope use the same held-bitmap so they're
  # safe no-ops on the failure path. The on-success path leaves all
  # __heldN flags true; the WITH body runs with all locks held; defers
  # release on scope exit as usual.
  sig { params(fallible_caps: T::Array[CapabilitySpec], clause: AST::ErrorClause, with_label: T.nilable(String), with_node: AST::WithBlock).returns(String) }
  def emit_sorted_lock_acquires_fallible(fallible_caps, clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    n = fallible_caps.length
    entries = build_sorted_acquire_entries(fallible_caps, fallible: true, with_node: with_node)

    action_zig = emit_lock_action_zig(clause, with_label, with_node)
    matched    = clause.matched_types
    bubble     = clause.bubble_types
    retries    = clause.retries
    line       = with_node.token&.line.to_s
    acq_loop   = "__acq_sort_#{with_node.object_id.abs}"

    guard_decls = entries.map { |e|
      "var #{e.guard_var}: @TypeOf(try #{e.lock_expr}.#{e.method_name}()) = undefined;"
    }.join("\n")
    held_decls = entries.map { |e| "var #{e.held_var}: bool = false;" }.join("\n")

    ptr_init   = entries.map { |e| "@intFromPtr(#{e.addr_expr})" }.join(", ")
    order_init = (0...n).to_a.join(", ")

    acquire_arms = entries.map { |e|
      <<~ZIG.rstrip
        #{e.index} => {
                                        if (#{e.lock_expr}.#{e.method_name}()) |__g| {
                                            #{e.guard_var} = __g;
                                            #{e.held_var} = true;
                                        } else |__err_inner| {
                                            __err_caught = __err_inner;
                                            __success = false;
                                        }
                                    },
      ZIG
    }.join("\n                                ")

    release_arms = entries.map { |e|
      "#{e.index} => if (#{e.held_var}) { #{e.guard_var}.release(); #{e.held_var} = false; },"
    }.join("\n                            ")

    handler_arms = []
    unless matched.empty?
      matched_errs = matched.map { |t| "error.#{AST.zig_name_of_type(t)}" }.join(", ")
      handler_arms << "#{matched_errs} => { #{action_zig} }"
    end
    bubble.each do |t|
      zig = AST.zig_name_of_type(t)
      kind = AST.kind_of_type(t)
      handler_arms << %Q(error.#{zig} => { #{runtime_binding_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{zig}), "lock #{zig}", #{line}); return error.CheatError; })
    end
    # Catch-all: __err_caught is `?anyerror`, so Zig requires an else
    # arm. Set a generic System error before propagating so callers
    # don't see CheatError with stale rt.__error content from a prior
    # operation. This path covers Zig errors that aren't in the
    # OrErr method's documented set (defensive).
    handler_arms << %Q(else => |__err_other| { #{runtime_binding_name}.setError(.System, 0, @errorName(__err_other), #{line}); return error.CheatError; })
    handler_switch = "switch (__err_caught.?) {\n                    #{handler_arms.join(",\n                    ")},\n                }"

    retry_branch = if retries
      "if (__retry + 1 < #{retries}) continue;"
    else
      "// no retries configured"
    end

    defer_releases = entries.map { |e| "defer if (#{e.held_var}) #{e.guard_var}.release();" }.join("\n")
    alias_decls    = entries.map { |e|
      "const #{e.alias_name} = #{e.guard_var}.get();\n_ = &#{e.alias_name};"
    }.join("\n")

    <<~ZIG.rstrip
      #{guard_decls}
      #{held_decls}
      #{acq_loop}: {
          var __retry: usize = 0;
          while (true) : (__retry += 1) {
              const __ptrs = [_]usize{ #{ptr_init} };
              var __order = [_]u8{ #{order_init} };
              var __i: usize = 0;
              while (__i < #{n}) : (__i += 1) {
                  var __j: usize = 0;
                  while (__j + 1 < #{n}) : (__j += 1) {
                      if (__ptrs[__order[__j]] > __ptrs[__order[__j + 1]]) {
                          const __tmp = __order[__j];
                          __order[__j] = __order[__j + 1];
                          __order[__j + 1] = __tmp;
                      }
                  }
              }
              var __success = true;
              var __err_caught: ?anyerror = null;
              var __k: usize = 0;
              while (__k < #{n}) : (__k += 1) {
                  const __idx = __order[__k];
                  switch (__idx) {
                      #{acquire_arms}
                      else => unreachable,
                  }
                  if (!__success) break;
              }
              if (__success) break :#{acq_loop};
              var __r: usize = __k;
              while (__r > 0) {
                  __r -= 1;
                  switch (__order[__r]) {
                      #{release_arms}
                      else => unreachable,
                  }
              }
              #{retry_branch}
              #{handler_switch}
              unreachable;
          }
      }
      #{defer_releases}
      #{alias_decls}
    ZIG
  end


end
