# typed: strict
require "sorbet-runtime"

module MIRLoweringVariables
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  class IndexedAssignmentDispatch < T::Struct
    const :target_var, T.nilable(String)
    const :shard_direct, T::Boolean
    const :template_kind, IntrinsicTemplateKind
    const :key_type, T.nilable(Type)
    const :value_type, T.nilable(Type)
    const :resolved_allocs, MIR::InlineAllocMetadata
    const :sink_alloc, Symbol
  end

  class AutoLockAssignmentFacts < T::Struct
    const :var_name, String
    const :sync, T.nilable(Symbol)
    const :guard_var, String
    const :alias_var, String
    const :zig_var, String
    const :field, String
    const :cleanup_alloc, T.nilable(Symbol)
    const :alloc_sym, Symbol
  end

  class AssignmentTargetPlan < T::Struct
    const :target, MIR::Emittable
    const :cleanup_field, T.nilable(AST::GetField)
  end

  class VarDeclFacts < T::Struct
    const :ft, Type
    const :binding_entry, CleanupEntry
    const :has_mir_drop, T::Boolean
    const :actually_mutated, T::Boolean
    const :forced_var, T::Boolean
    const :keyword_mutable, T::Boolean
    const :annotation, T.nilable(Type)
    const :heap_return_var, T::Boolean
    const :decl_alloc, Symbol
    const :init_ownership_effect, MIR::OwnershipEffect
    const :source_owned_binding, T::Boolean
    const :has_caps, T::Boolean
    const :bare_zig, String
    const :generic_id, T::Boolean
  end

  sig do
    params(
      node: AST::VarDecl,
      type_info: Type,
      binding_entry: CleanupEntry,
      heap_return_var: T::Boolean,
      heap_return_binding_allocates: T::Boolean,
    ).returns(MIR::Placement::BindingFact)
  end
  def binding_placement_fact(node, type_info, binding_entry, heap_return_var, heap_return_binding_allocates)
    T.bind(self, MIRLowering) rescue nil
    storage = (node.symbol&.heap_storage? || heap_return_binding_allocates) ? :heap : :frame
    cleanup_alloc = if storage == :heap
      :heap
    elsif heap_return_var
      :frame
    elsif binding_entry.present?
      binding_entry.alloc
    else
      alloc_for_node(node)
    end
    alloc = MIR::Placement.binding_alloc(storage: storage, cleanup_alloc: cleanup_alloc, default: :frame)
    scope = binding_entry.present? ? binding_entry.scope : MIR::Placement.cleanup_scope(alloc)
    MIR::Placement::BindingFact.new(
      name: node.name.to_s,
      type_info: type_info,
      storage: storage,
      alloc: alloc,
      scope: scope,
      heap_return: heap_return_var,
      escape_reason: storage == :heap ? :symbol_storage : nil,
    )
  end

  sig { params(node: AST::FunctionDef, mutable_scalar_params: T::Set[String]).returns(T.nilable(String)) }
  def tied_shared_family_return_param(node, mutable_scalar_params)
    T.bind(self, MIRLowering) rescue nil
    ret = node.return_type
    return nil unless ret.is_a?(Type) && ret.polymorphic_shared?
    return nil unless ret.generic_type_parameter?
    params = node.params.select do |p|
      pt = p.type
      pt.shared? && pt.resolved == ret.resolved
    end
    return nil unless params.size == 1
    name = params.first[:name]
    zig_name = mutable_scalar_params.include?(name) ? "_m_#{name}" : name
    "@TypeOf(#{zig_name})"
  end

  # ================================================================
  # Declarations
  # ================================================================

  # Compose Group-1 (sync + ownership) wrappers around a Group-2 (data
  # shape) construction. Used by every collection-init path so the
  # construction concern (initCapacity / `T{}` / etc.) is decoupled from
  # the wrapping concern (Locked → RwLocked → RefCell → Arc/Rc).
  #
  # The inner construction MUST be the bare data shape — no
  # sync/ownership wrappers in its zig type. Use `Type#bare_data_type`
  # to derive that before passing to ContainerInit / similar.
  #
  # `inner_mir`    : MIR node whose Zig string evaluates to the bare inner.
  # `bare_zig_t`   : the inner's Zig type (used to spell out wrap types).
  # `ft`           : the full Type (carries .sync and .ownership).
  # `alloc`        : :heap | :frame | :static — used by arcCreate/rcCreate.
  #
  # Returns the wrapped MIR node (typically MIR::CapWrap).
  sig { params(inner_mir: MIR::Node, bare_zig_t: String, ft: Type, alloc: Symbol).returns(MIR::Node) }
  def compose_capability_wrap(inner_mir, bare_zig_t, ft, alloc)
    T.bind(self, MIRLowering) rescue nil
    # AtomicPtr and primitive Atomic use distinct constructors.
    is_atomic_ptr = ft.atomic_ptr?
    sync_fn = sync_wrap_constructor(ft.sync, atomic_ptr: is_atomic_ptr)
    sync_t = sync_wrap_type(ft.sync, bare_zig_t, atomic_ptr: is_atomic_ptr)
    # Atomic wrappers skip the ownership wrap; the cell is the shareable
    # synchronization object.
    own_fn  = case ft.ownership
              when :shared      then (ft.atomic? ? nil : "arcCreate")
              when :multiowned  then (ft.atomic? ? nil : "rcCreate")
              end
    if sync_fn && own_fn
      MIR::CapWrap.new(inner_mir, bare_zig_t, :both, sync_fn, sync_t, own_fn, alloc)
    elsif sync_fn
      MIR::CapWrap.new(inner_mir, bare_zig_t, :sync_only, sync_fn, sync_t, nil, alloc)
    elsif own_fn
      MIR::CapWrap.new(inner_mir, bare_zig_t, :own_only, nil, nil, own_fn, alloc)
    else
      inner_mir
    end
  end

  sig { params(node: AST::VarDecl).returns(MIR::NodeRoot) }
  def lower_var_decl(node)
    T.bind(self, MIRLowering) rescue nil
    facts = var_decl_facts(node)

    # Every allocating sub-expression of the value -- collection init,
    # pipeline, COLLECT, toList, concat -- inherits this binding's
    # finalized placement. ONE allocator per binding, read off the
    # decl's symbol; no per-branch threading.
    init = with_decl_alloc(facts.decl_alloc) do
      lower_var_decl_init(node, facts.ft, facts.bare_zig, facts.has_caps, facts.decl_alloc)
    end
    init = ensure_cleanup_binding_owns_string_init(init, facts, node.value)

    safe_name = var_decl_safe_name(node, facts.has_mir_drop)
    function_state.binding_types[safe_name] = facts.ft
    stamp_var_decl_init_target!(init, safe_name, facts.decl_alloc)

    let_node = MIR::Let.new(
      safe_name,
      init,
      facts.keyword_mutable,
      facts.annotation,
      var_decl_suppression(safe_name, node, facts, init)
    )
    init_effect = MIR::OwnershipEffect.of(init)
    if var_decl_source_transfer_required?(node, facts, init_effect)
      let_node = T.cast(with_ownership_consumption_for_value(
        let_node,
        init,
        node.value,
        "var init",
        :owned_sink,
        target_alloc: facts.decl_alloc,
      ), MIR::Let)
    end

    nodes = var_decl_materialization_plan(
      node,
      facts,
      safe_name,
      init,
      let_node
    ).statements

    owner_marks = field_owner_move_marks(node)
    nodes.concat(owner_marks)

    nodes.size == 1 ? T.must(nodes.first) : nodes
  end

  sig { params(init: MIR::Node, facts: VarDeclFacts, ast_value: AST::Node).returns(MIR::Node) }
  def ensure_cleanup_binding_owns_string_init(init, facts, ast_value)
    return init unless facts.has_mir_drop
    return init unless facts.ft.string?

    effect = MIR::OwnershipEffect.of(init)
    return init if effect.produces_owned
    return init if ast_value.is_a?(AST::Identifier) && AST.moved?(ast_value)

    MIR::DupeSlice.new(init, facts.decl_alloc)
  end

  sig { params(node: AST::VarDecl).returns(VarDeclFacts) }
  def var_decl_facts(node)
    T.bind(self, MIRLowering) rescue nil
    is_mutable = node.respond_to?(:mutable) && node.mutable
    ft = Type.new(node.full_type!)
    is_mutable ||= ft.dynamic_stream? || ft.bounded_stream? || ft.shared_promise? || ft.open_stream? || ft.inf_stream?
    is_mutable ||= ft.collection?
    is_mutable ||= ft.any_sync?
    is_mutable ||= ft.resource? || node.resource_close_plan
    is_mutable = false if ft.local?
    # Plain T bindings borrowed by reference need Zig `var`; otherwise
    # &binding produces *const T and the callee cannot write back.
    is_mutable = true if node.symbol&.poly_borrow_target || node.symbol&.mutable_ref_target

    # Post-dataflow cleanup entry (cleanup_decisions! refinements are correct here).
    # For same-name vars in different scopes, alloc is overridden per-declaration
    # via alloc_for_node(node) which reads the storage set by escape analysis.
    is_mutable = is_mutable == true
    node_entry = node.respond_to?(:mir_binding_entry) ? node.mir_binding_entry : nil
    decl_name = node.name.to_s
    binding_entry = node_entry || function_state.bindings[decl_name] || CleanupEntry::NONE
    empty_optional_init = optional_nil_initializer?(ft, node.value)
    binding_entry = CleanupEntry::NONE if empty_optional_init
    has_mir_drop = binding_entry.needs_cleanup? && !binding_entry.match_as?
    heap_return_var = !empty_optional_init && current_function_heap_carry_return_var?(node.name.to_s)
    heap_return_binding_allocates = (heap_return_var && escaping_value_alloc(ft) == :heap) == true
    placement = binding_placement_fact(node, ft, binding_entry, heap_return_var, heap_return_binding_allocates)

    actually_mutated = is_mutable && node.respond_to?(:var_mutated) && node.var_mutated == true
    actually_mutated = actually_mutated == true
    is_heap = placement.heap?
    has_mutable_cleanup = has_mir_drop || ft.collection? || ft.dynamic_stream? || ft.bounded_stream? || ft.shared_promise? ||
                          ft.open_stream? || ft.inf_stream? || (ft.array? && ft.dynamic?) ||
                          is_heap || ft.resource? || node.resource_close_plan
    forced_var = is_mutable && has_mutable_cleanup
    forced_var = forced_var == true
    # Borrowed-by-reference bindings force Zig `var` even when local mutation
    # analysis only sees field mutation through the callee.
    by_ref_borrow = node.symbol&.mutable_ref_target == true || node.symbol&.poly_borrow_target == true
    keyword_mutable = is_mutable && (actually_mutated || forced_var || by_ref_borrow)

    zig_type = transpile_type(node.full_type!)
    needs_annotation = ZigTypeMapper::ZIG_PRIMITIVES.include?(zig_type) || ft.fn_type? ||
                       (node.value.is_a?(AST::Literal) && node.value.type == :NIL) ||
                       (ft.string? && is_heap)  # ""/literal infers *const [0:0]u8 without annotation
    annotation = needs_annotation ? Type.new(zig_type) : nil

    # Resolve init value - special handling for collection types.
    # Per-declaration storage (set by escape analysis) takes precedence over the
    # name-keyed cleanup plan (which may be stale for same-name vars in different scopes).
    # Escape analysis stamping (:heap) takes precedence. For :frame, trust the
    # cleanup_bindings alloc (which correctly handles sharded/pool/always-heap types).
    base_decl_alloc = placement.alloc
    next_owned_alloc = if node.value.is_a?(AST::NextExpr)
      next_result_owned_alloc(Type.from_node!(node.value.expr, context: "NEXT source"), ft, base_decl_alloc)
    end
    source_owned_alloc = owned_binding_source_alloc(node.value)
    init_ownership_effect = if next_owned_alloc
      MIR::OwnershipEffect.owned(alloc: next_owned_alloc)
    elsif source_owned_alloc
      MIR::OwnershipEffect.owned(alloc: source_owned_alloc)
    else
      MIR::OwnershipEffect.none
    end
    # Destination placement is authoritative once escape analysis stamped the
    # binding heap. Source-owned alloc flow is only allowed for non-escaping
    # bindings; otherwise a frame source can poison a heap-return destination
    # and the checker quite correctly rejects the transfer.
    decl_alloc = MIR::Placement.explicit_heap?(base_decl_alloc) ? :heap : (init_ownership_effect.alloc || base_decl_alloc)
    # Group 2 (data shape) is constructed against the BARE type — no
    # sync/ownership wrappers. Group 1 wrapping is applied via
    # compose_capability_wrap once the inner is built. This separation is
    # what makes "@<shape>:<sync>:<ownership>" combinations compose without
    # per-shape × per-cap glue.
    has_caps = !!((ft.any_sync? || ft.ownership != :affine) && !ft.striped?)
    bare_ft = has_caps ? ft.bare_data_type : ft
    bare_zig = transpile_type(bare_ft)

    VarDeclFacts.new(
      ft: ft,
      binding_entry: binding_entry,
      has_mir_drop: has_mir_drop,
      actually_mutated: actually_mutated,
      forced_var: forced_var,
      keyword_mutable: keyword_mutable,
      annotation: annotation,
      heap_return_var: heap_return_var == true,
      decl_alloc: decl_alloc,
      init_ownership_effect: init_ownership_effect,
      source_owned_binding: !source_owned_alloc.nil?,
      has_caps: has_caps,
      bare_zig: bare_zig,
      generic_id: ft.id_handle?
    )
  end

  sig { params(type_info: Type, value: AST::Node).returns(T::Boolean) }
  def optional_nil_initializer?(type_info, value)
    return false unless type_info.optional?
    node = T.let(value, AST::Node)
    node = node.value while node.is_a?(AST::Cast)
    node.is_a?(AST::Literal) && node.type == :NIL ? true : false
  end

  sig { params(value: AST::Node).returns(T.nilable(Symbol)) }
  def owned_binding_source_alloc(value)
    T.bind(self, MIRLowering) rescue nil
    return nil if value.is_a?(AST::CopyNode) || value.is_a?(AST::CloneNode)
    node = value.is_a?(AST::MoveNode) ? value.value : value
    return nil unless node.is_a?(AST::Identifier)
    ti = Type.from_node!(node, context: "owned binding source")
    return nil unless ownership_tracked_transfer_type?(ti)

    entry = function_state.bindings[node.name.to_s]
    return nil unless entry&.needs_cleanup?

    entry.alloc
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, init_effect: MIR::OwnershipEffect).returns(T::Boolean) }
  def var_decl_source_transfer_required?(node, facts, init_effect)
    T.bind(self, MIRLowering) rescue nil
    return false if var_decl_source_borrowed?(node)
    return true if facts.source_owned_binding
    return false if init_effect.produces_owned

    ownership_tracked_transfer_type?(facts.ft)
  end

  sig { params(node: AST::VarDecl).returns(T::Boolean) }
  def var_decl_source_borrowed?(node)
    return true if AST.container_borrow?(node)

    node.symbol&.borrow_provenance? == true
  end

  sig { params(node: AST::VarDecl, has_mir_drop: T::Boolean).returns(String) }
  def var_decl_safe_name(node, has_mir_drop)
    T.bind(self, MIRLowering) rescue nil
    decl_name_map = function_state.decl_zig_names
    alloc_marked_names = function_state.alloc_marked_names
    rename_map = function_state.rename_map
    # `_` is not a valid Zig binding identifier; a discarded value that
    # still needs cleanup must bind to a unique temp. binding_entry
    # stays keyed by `_` so its cleanup recipe is preserved.
    if node.name.to_s == "_"
      safe_name = "__discard_#{lowering_counters.next_tmp_id}"
    else
      safe_name = zig_safe_name(node.name)
    end

    # Disambiguate when two variables in the same function would share a Zig
    # name AND both emit AllocMarks (has_mir_drop).  The MIR checker's flat
    # name-keyed allocs dict conflates them; appending the source line makes
    # the names unique so the checker sees independent containers.
    original_safe = safe_name
    if alloc_marked_names.key?(safe_name)
      safe_name = "#{safe_name}_L#{node.line}"
    end
    alloc_marked_names[safe_name] = true
    decl_name_map[node.object_id] = safe_name
    # Name-keyed view used by AST markers lowered later. Overwrites when the
    # same name is re-declared in a sibling branch; lowering order matches the
    # lexical order in which AST markers reference each decl.
    rename_map[original_safe] = safe_name

    safe_name
  end

  sig { params(safe_name: String, node: AST::VarDecl, facts: VarDeclFacts, init: MIR::Node).returns(T.nilable(String)) }
  def var_decl_suppression(safe_name, node, facts, init)
    lowering = T.unsafe(self)
    return nil unless current_function_context

    owned_cleanup_value = (facts.has_mir_drop ||
                           (lowering.mir_allocates?(init) && lowering.ownership_bearing_type?(facts.ft))) == true
    if facts.keyword_mutable
      if facts.actually_mutated && node.var_used && !facts.forced_var
        nil
      else
        "_ = &#{safe_name};"
      end
    else
      return nil if node.var_used
      owned_cleanup_value ? "_ = &#{safe_name};" : "_ = #{safe_name};"
    end
  end

  sig { params(init: MIR::Node, safe_name: String, decl_alloc: Symbol).void }
  def stamp_var_decl_init_target!(init, safe_name, decl_alloc)
    T.bind(self, MIRLowering) rescue nil
    if mir_allocates?(init)
      stamp_allocating_result_target!(init, safe_name, alloc: decl_alloc)
    end
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def var_decl_materialization_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    return classified_cleanup_var_decl_plan(node, facts, safe_name, init, let_node) if facts.has_mir_drop
    return owned_return_call_var_decl_plan(node, facts, safe_name, init, let_node) if owned_return_call_init?(init) && !facts.generic_id
    return transfer_only_var_decl_plan(node, facts, safe_name, init, let_node) if transfer_only_var_decl?(facts, init)
    return mutated_owned_var_decl_plan(node, facts, safe_name, init, let_node) if mutated_owned_var_decl?(facts, init)
    return binding_metadata_var_decl_plan(node, facts, safe_name, init, let_node) if facts.binding_entry.present? && !facts.binding_entry.needs_cleanup?
    return allocating_init_var_decl_plan(node, facts, safe_name, init, let_node) if mir_allocates?(init) && !facts.generic_id

    MIR::MaterializationPacket.value_only(let_node)
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def classified_cleanup_var_decl_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    drop_entry = facts.binding_entry
    build_drop_entry!(drop_entry, node.full_type!, node)
    drop_entry = drop_entry.with_moved_guard if facts.ft.bounded_stream?
    init_effect = MIR::OwnershipEffect.of(init)
    node_alloc = MIR::Placement.explicit_heap?(facts.decl_alloc) ? :heap : (init_effect.alloc || facts.init_ownership_effect.alloc || drop_entry.alloc || facts.decl_alloc)
    drop_entry = drop_entry.with_alloc(node_alloc)
    function_state.bindings[node.name.to_s] = drop_entry
    mark_guarded_cleanup_name!(safe_name) if drop_entry.has_moved_guard?
    MIR::MaterializationPacket.owned(
      var_decl_alloc_mark(safe_name, node_alloc, facts.ft, drop_entry),
      let_node,
      MIR::Cleanup.new(safe_name, drop_entry)
    )
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def owned_return_call_var_decl_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    mir_alloc = mir_owned_alloc(init) || facts.decl_alloc
    cleanup_entry = hoist_cleanup_entry(init, node) || CleanupEntry.build(:uniform, alloc: mir_alloc, has_moved_guard: true)
    build_drop_entry!(cleanup_entry, node.full_type!, node)
    cleanup_entry.mark_moved_guard!
    mark_guarded_cleanup_name!(safe_name)
    MIR::MaterializationPacket.owned(
      var_decl_alloc_mark(safe_name, mir_alloc, facts.ft, facts.binding_entry),
      let_node,
      MIR::Cleanup.new(safe_name, cleanup_entry)
    )
  end

  sig { params(facts: VarDeclFacts, init: MIR::Node).returns(T::Boolean) }
  def transfer_only_var_decl?(facts, init)
    !facts.heap_return_var && owned_return_transfer_binding?(facts.binding_entry, init) && !facts.generic_id
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def transfer_only_var_decl_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    mir_alloc = mir_owned_alloc(init) || facts.decl_alloc
    MIR::MaterializationPacket.owned(
      var_decl_alloc_mark(safe_name, mir_alloc, facts.ft, facts.binding_entry),
      let_node
    )
  end

  sig { params(facts: VarDeclFacts, init: MIR::Node).returns(T::Boolean) }
  def mutated_owned_var_decl?(facts, init)
    T.bind(self, MIRLowering) rescue nil
    facts.binding_entry.present? && !facts.binding_entry.needs_cleanup? && facts.actually_mutated &&
      ownership_bearing_type?(facts.ft) &&
      (!facts.ft.string? || mir_allocates?(init) || owned_return_call_init?(init))
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def mutated_owned_var_decl_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    mir_alloc = mir_owned_alloc(init) || facts.binding_entry.alloc || facts.decl_alloc
    cleanup_entry = CleanupEntry.build(facts.ft.string? ? :heap_string : :uniform, alloc: mir_alloc, has_moved_guard: true)
    build_drop_entry!(cleanup_entry, node.full_type!, node)
    mark_guarded_cleanup_name!(safe_name)
    MIR::MaterializationPacket.owned(
      var_decl_alloc_mark(safe_name, mir_alloc, facts.ft, facts.binding_entry),
      let_node,
      MIR::Cleanup.new(safe_name, cleanup_entry)
    )
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def binding_metadata_var_decl_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    binding_entry = facts.binding_entry
    return MIR::MaterializationPacket.value_only(let_node) unless mir_allocates?(init) ||
                                                               (MIR::Placement.heap?(binding_entry.alloc) && binding_entry.kind != :none)

    mir_alloc = mir_owned_alloc(init) || facts.decl_alloc
    alloc_mark = var_decl_alloc_mark(safe_name, mir_alloc, facts.ft, binding_entry)
    return MIR::MaterializationPacket.owned(alloc_mark, let_node) unless ownership_bearing_type?(facts.ft)

    cleanup_entry = moved_guard_cleanup_entry(facts.ft, mir_alloc, node)
    mark_guarded_cleanup_name!(safe_name)
    MIR::MaterializationPacket.owned(alloc_mark, let_node, MIR::Cleanup.new(safe_name, cleanup_entry))
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: MIR::Node, let_node: MIR::Let).returns(MIR::MaterializationPacket) }
  def allocating_init_var_decl_plan(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    mir_alloc = mir_owned_alloc(init) || facts.decl_alloc
    alloc_mark = var_decl_alloc_mark(safe_name, mir_alloc, facts.ft, facts.binding_entry)
    return MIR::MaterializationPacket.owned(alloc_mark, let_node) unless type_requires_alloc_cleanup?(facts.ft, mir_alloc)

    cleanup_entry = T.must(hoist_cleanup_entry(init, node))
    build_drop_entry!(cleanup_entry, node.full_type!, node)
    mark_guarded_cleanup_name!(safe_name) if cleanup_entry.has_moved_guard?
    MIR::MaterializationPacket.owned(alloc_mark, let_node, MIR::Cleanup.new(safe_name, cleanup_entry))
  end

  sig { params(name: String).void }
  def mark_guarded_cleanup_name!(name)
    T.bind(self, MIRLowering) rescue nil
    function_state.guarded_cleanup_names[name] = true
  end

  sig { params(ft: Type, alloc: Symbol, node: AST::VarDecl).returns(CleanupEntry) }
  def moved_guard_cleanup_entry(ft, alloc, node)
    T.bind(self, MIRLowering) rescue nil
    entry = CleanupEntry.build(ft.string? ? :heap_string : :uniform, alloc: alloc, has_moved_guard: true)
    build_drop_entry!(entry, node.full_type!, node)
    entry.mark_moved_guard!
    entry
  end

  sig { params(ft: Type, alloc: Symbol).returns(T::Boolean) }
  def type_requires_alloc_cleanup?(ft, alloc)
    T.bind(self, MIRLowering) rescue nil
    return false if ft.primitive? || ft.void? || ft.any? || ft.id_handle?
    return true if ft.needs_cleanup?(mir_schema_lookup)
    return true if ft.needs_explicit_cleanup?(alloc, mir_schema_lookup)

    MIR::Placement.explicit_heap?(alloc) && (ft.string? || ft.heap_ptr? || ft.collection_value? ||
      ft.any_sync? || ft.any_rc? || ft.link? || ft.indirect? ||
      ft.recursive_cleanup_shape?(mir_schema_lookup))
  end

  sig { params(name: String, alloc: Symbol, type_info: Type, binding_entry: CleanupEntry).returns(MIR::AllocMark) }
  def var_decl_alloc_mark(name, alloc, type_info, binding_entry)
    mark = MIR::AllocMark.new(name, alloc, type_info,
      MIR::Placement.explicit_heap?(alloc) ? :heap : (binding_entry.present? ? binding_entry.scope : :iteration))
    mark
  end

  sig do
    params(
      node: AST::VarDecl,
      ft: Type,
      bare_zig: String,
      has_caps: T::Boolean,
      decl_alloc: Symbol
    ).returns(MIR::Node)
  end
  def lower_var_decl_init(node, ft, bare_zig, has_caps, decl_alloc)
    T.bind(self, MIRLowering) rescue nil
    if node.value.is_a?(AST::NextExpr)
      return lower_next_expr(node.value, decl_alloc)
    end

    rhs = node.value
    rhs_unwrapped = (rhs.is_a?(AST::BinaryOp) && rhs.op == :OR_RESCUE) ? rhs.left : rhs
    if rhs.is_a?(AST::BinaryOp) && rhs.op == :OR_RESCUE
      placed = with_expected_type(ft) { lower(rhs) }
      return place_value_for_destination(placed, rhs, decl_alloc, ft)
    end

    if ft.pool?
      return lower(node.value) if rhs_unwrapped.is_a?(AST::MoveNode) || AST.call?(rhs_unwrapped) || !rhs_unwrapped.is_a?(AST::ListLit)
      inner = MIR::ContainerInit.new(bare_zig, :pool, decl_alloc, ft.capacity)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    if ft.set_collection?
      return lower(node.value) if rhs.is_a?(AST::BinaryOp) && rhs.smooth?
      return lower(node.value) if rhs_unwrapped.is_a?(AST::MoveNode) || AST.call?(rhs_unwrapped) || !rhs_unwrapped.is_a?(AST::ListLit)
      inner = MIR::ContainerInit.new(bare_zig, :set_empty, nil, nil)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    if ft.list_collection?
      return lower(node.value) if rhs_unwrapped.is_a?(AST::MoveNode)
      return lower_next_expr(rhs_unwrapped, decl_alloc) if rhs_unwrapped.is_a?(AST::NextExpr)
      return lower(node.value) if AST.call?(rhs_unwrapped)
      if list_collection_copy?(rhs_unwrapped)
        return MIR::DeepCopy.new(lower(rhs_unwrapped.value), ft.zig_type, nil, :full_value, decl_alloc)
      end
      return lower(node.value) unless rhs_unwrapped.is_a?(AST::ListLit)
      return with_expected_type(ft) { lower(node.value) } unless rhs_unwrapped.items.empty?
      ft_capacity = ft.capacity
      init_kind = ft_capacity.is_a?(Integer) && ft_capacity > 0 ? :list_capacity : :array_list_empty
      init_capacity = init_kind == :list_capacity ? ft_capacity : nil
      inner = MIR::ContainerInit.new(bare_zig, init_kind, decl_alloc, init_capacity)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    if ft.fixed_soa?
      inner = MIR::ContainerInit.new(bare_zig, :list_capacity, decl_alloc, ft.capacity)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    retain_source = node.value.is_a?(AST::MoveNode) ? node.value.value : node.value
    return make_rc_retain(retain_source) if node.value.was_moved != true && rc_retain_needed?(retain_source)

    placed = with_expected_type(ft) { lower(node.value) }
    placed = place_value_for_destination(placed, node.value, decl_alloc, ft)
    if has_caps && !placed.is_a?(MIR::CapWrap) && !source_already_has_declared_capability?(node.value, ft)
      compose_capability_wrap(placed, bare_zig, ft, decl_alloc)
    else
      placed
    end
  end

  sig { params(source_node: AST::Node, target_type: Type).returns(T::Boolean) }
  def source_already_has_declared_capability?(source_node, target_type)
    node = T.let(source_node, AST::Node)
    node = node.value while node.is_a?(AST::Cast)
    return false if node.is_a?(AST::CapabilityWrap)

    source_type = Type.from_node!(node, context: "capability source type")
    return false unless source_type.ownership == target_type.ownership
    return false unless source_type.sync == target_type.sync
    return false unless source_type.layout == target_type.layout
    return false unless source_type.shard_count == target_type.shard_count
    true
  end

  sig { params(rhs: AST::Node).returns(T::Boolean) }
  def list_collection_copy?(rhs)
    (rhs.is_a?(AST::CopyNode) || rhs.is_a?(AST::CloneNode)) &&
      rhs.value.full_type!(context: "collection copy source").list_collection?
  end

  sig { params(node: AST::VarDecl).returns(T::Array[MIR::Stmt]) }
  def field_owner_move_marks(node)
    T.bind(self, MIRLowering) rescue nil

    value = node.value
    return [] unless value.is_a?(AST::GetField)
    return [] unless field_access_moves_owner?(value)

    root = AST.root_identifier(value)
    return [] unless root

    source_name = root.name.to_s
    safe = zig_safe_name(source_name)
    rename_map = function_state.rename_map
    safe = rename_map[safe].to_s if rename_map.key?(safe)
    entry = function_state.bindings[source_name] || CleanupEntry::NONE
    return [] unless entry.present?

    guarded_names = function_state.guarded_cleanup_names
    guarded = entry.has_moved_guard? || guarded_names[safe] == true
    ownership_transfer_marks(safe, :owned_sink, target_alloc: entry.alloc, move_guarded: guarded)
  end

  sig { params(value: AST::GetField).returns(T::Boolean) }
  def field_access_moves_owner?(value)
    return true if AST.moved?(value)
    return true if value.respond_to?(:indirect_field) && value.indirect_field == true

    Type.indirect_type?(value.full_type!(context: "field owner move"))
  end

  sig { params(binding_entry: CleanupEntry, init: MIR::Node).returns(T::Boolean) }
  def owned_return_transfer_binding?(binding_entry, init)
    T.bind(self, MIRLowering) rescue nil
    return false if binding_entry.needs_cleanup?
    return false unless binding_entry.present?
    return false unless binding_entry.heap? || binding_entry.alloc == :cleanup

    return false if init.is_a?(MIR::Call)

    return false unless init.respond_to?(:stdlib_def)

    sig = FunctionSignature.unwrap(T.unsafe(init).stdlib_def)
    return false unless sig&.emits_allocating?
    return true if sig.heap_return_alloc?

    metadata = init.respond_to?(:allocs) ? T.unsafe(init).allocs : nil
    return metadata.any_heap? == true if metadata.is_a?(MIR::InlineAllocMetadata)

    false
  end

  sig { params(init: T.nilable(MIR::Node)).returns(T::Boolean) }
  def owned_return_call_init?(init)
    return owned_return_call_init?(init.expr) if init.is_a?(MIR::Cast)
    return owned_return_call_init?(init.expr) if init.is_a?(MIR::TryExpr)
    !!(init.is_a?(MIR::Call) && init.owned_return?)
  end

  sig { params(node: AST::Node).returns(T.nilable(CleanupEntry)) }
  def cleanup_entry_for_ast_binding(node)
    symbol = T.let(nil, T.nilable(SymbolEntry))
    symbol = T.unsafe(node).symbol if node.respond_to?(:symbol)
    decl = symbol&.reg
    if decl && decl.respond_to?(:mir_binding_entry)
      entry = decl.mir_binding_entry
      return entry if entry
    end
    nil
  end

  sig { params(node: AST::BindExpr).returns(MIR::NodeRoot) }
  def lower_bind_expr(node)
    T.bind(self, MIRLowering) rescue nil
    if node.mode == :decl
      # Proxy to VarDecl logic. Copy mir_binding_entry so lower_var_decl
      # uses node-identity lookup rather than the name-keyed dict.
      proxy = AST::VarDecl.new(node.token, node.name, node.type, node.value, false)
      AST.stamp_synthetic_type!(proxy, node.full_type!(context: "bind expression proxy"), context: "synthetic AST type")
      proxy.storage = node.storage
      proxy.slot_size = node.slot_size
      proxy.resource_close_plan = node.resource_close_plan
      proxy.var_used = node.var_used
      proxy.container_borrow = node.container_borrow if node.respond_to?(:container_borrow) && proxy.respond_to?(:container_borrow=)
      proxy.symbol = node.symbol if node.respond_to?(:symbol) && proxy.respond_to?(:symbol=)
      proxy.mir_binding_entry = node.mir_binding_entry if node.respond_to?(:mir_binding_entry) && proxy.respond_to?(:mir_binding_entry=)
      result = lower_var_decl(proxy)
      # Line-suffix disambiguation in lower_var_decl stores the renamed Zig
      # name under `proxy.object_id`. Annotator-resolved references point to
      # the original BindExpr (`node`), not the proxy, so without this the
      # reference lowering misses the map and emits the unsuffixed name,
      # producing `var x_L8 = ...; ... x.len` which is undeclared Zig.
      decl_name_map = function_state.decl_zig_names
      if decl_name_map.key?(proxy.object_id)
        safe_name = T.must(decl_name_map[proxy.object_id])
        decl_name_map[node.object_id] = safe_name
        symbol_reg = node.symbol&.reg
        decl_name_map[symbol_reg.object_id] = safe_name if symbol_reg
      end
      result
    else
      # Atomic compound assignments must emit cell methods; the desugared
      # load+store form would race.
      if node.auto_atomic_op
        return lower_atomic_assignment(node)
      end

      target_name = assignment_storage_name(node.name.to_s, renamed: true)
      rp = node.reassign_cleanup
      # The new value's allocating expression inherits the reassigned
      # binding's allocator (one allocator per binding).
      binding_entry = cleanup_entry_for_ast_binding(node) || function_state.bindings[node.name.to_s] || CleanupEntry::NONE
      heap_return_var = current_function_heap_carry_return_var?(node.name.to_s)
      assign_alloc = if heap_return_var
        :heap
      else
        rp ? alloc_from_sym(rp.alloc!) : (binding_entry.present? ? binding_entry.alloc : nil)
      end
      value = with_decl_alloc(assign_alloc) do
        lowered = lower(node.value)
        place_value_for_destination(lowered, node.value, assign_alloc, node.full_type!)
      end
      value = copy_container_borrow_if_needed(value, node.value)
      stamp_allocating_result_target!(value, target_name, alloc: assign_alloc) if assign_alloc && value
      value = hoist_alloc(value, node.value, err_cleanup: true) if value && mir_allocates?(value) &&
        !fallible_self_fallback_reassign?(target_name, value)
      result = if rp
        MIR::ReassignWithCleanup.new(target_name, value, rp.zig_type!, alloc_from_sym(rp.alloc!))
      elsif heap_return_var && node.full_type!(context: "reassign target").needs_explicit_cleanup?(:heap, mir_schema_lookup)
        target_type = node.full_type!(context: "reassign target")
        MIR::ReassignWithCleanup.new(target_name, value, transpile_type(target_type), :heap)
      else
        MIR::Set.new(MIR::Ident.new(target_name), value)
      end
      result = with_ownership_consumption_for_value(result, value, node.value, result.class.name.to_s,
        target_alloc: result.is_a?(MIR::ReassignWithCleanup) ? result.alloc : assign_alloc)
      result
    end
  end

  sig { params(node: AST::DestructuringAssignment).returns(MIR::DestructureSet) }
  def lower_destructuring_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    value = T.cast(lower(node.value), MIR::Emittable)
    targets = node.targets.map { |target| lower_destructure_target(target) }
    MIR::DestructureSet.new(targets, value)
  end

  sig { params(target: AST::DestructureTarget).returns(MIR::DestructureTarget) }
  def lower_destructure_target(target)
    T.bind(self, MIRLowering)

    if target.name.to_s == "_"
      return MIR::DestructureTarget.new("_", nil, nil)
    end

    symbol = target.symbol
    declared = symbol&.reg.equal?(target)
    safe_name = zig_safe_name(target.name)
    if declared
      function_state.decl_zig_names[target.object_id] = safe_name
      function_state.decl_zig_names[symbol.reg.object_id] = safe_name if symbol&.reg
    end

    declaration_kind = declared ? destructure_declaration_kind(target) : nil
    annotation = declared && target.type ? Type.new(transpile_type(target.full_type!)) : nil
    MIR::DestructureTarget.new(safe_name, declaration_kind, annotation)
  end

  sig { params(target: AST::DestructureTarget).returns(Symbol) }
  def destructure_declaration_kind(target)
    return :const unless target.mutable

    ft = Type.from_node!(target, context: "destructure target declaration")
    forced_var = ft.collection? || ft.dynamic_stream? || ft.bounded_stream? ||
                 ft.shared_promise? || ft.open_stream? || ft.inf_stream? ||
                 (ft.array? && ft.dynamic?) || ft.any_sync? || ft.resource?
    target.var_mutated == true || forced_var ? :var : :const
  end

  sig { params(name: String, renamed: T::Boolean).returns(String) }
  def assignment_storage_name(name, renamed:)
    capture_mapped_name(name) || zig_local_name(name, renamed: renamed)
  end

  sig { params(name: String).returns(T.nilable(String)) }
  def capture_mapped_name(name)
    T.bind(self, MIRLowering) rescue nil
    capture_state.do_capture_map&.dig(name)
  end

  sig { params(name: String, renamed: T::Boolean).returns(String) }
  def zig_local_name(name, renamed:)
    T.bind(self, MIRLowering) rescue nil
    safe = zig_safe_name(name)
    return safe unless renamed

    function_state.rename_map.fetch(safe, safe)
  end

  sig { params(name: String, value: MIR::Node).returns(T::Boolean) }
  def fallible_self_fallback_reassign?(name, value)
    expr = value
    expr = expr.expr if expr.is_a?(MIR::Cast)
    expr.is_a?(MIR::TryCatch) &&
      expr.capture.nil? &&
      expr.catch_body.is_a?(MIR::Ident) &&
      expr.catch_body.name.to_s == name.to_s
  end

  # Emit `cell.<op>(arg)` for atomic assignments. The annotator stamped
  # `auto_atomic_op` based on shape:
  #   `c = v`       (compound_op nil)        -> :store    -> cell.store(v)
  #   `c += n`      (compound_op :ADD)       -> :fetchAdd -> cell.fetchAdd(n)
  #   `c -= n`      (compound_op :SUB)       -> :fetchSub -> cell.fetchSub(n)
  #
  # Compound forms grab the operand from the desugared BinaryOp's right side
  # (parser desugared
  # `c += n` to `c = c + n`, so node.value.right is `n`). The plain
  # form passes node.value as-is.
  sig { params(node: AST::BindExpr).returns(MIR::ExprStmt) }
  def lower_atomic_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    op_name = node.auto_atomic_op.to_s
    target_name = node.name.is_a?(String) ? node.name : node.name.name
    safe = zig_local_name(target_name, renamed: true)
    # A bare write to a mutable scalar atomic param may not create the usual
    # shadow variable, so resolve through param mangling explicitly.
    if current_function_mutable_scalar_param?(target_name)
      safe = "_m_#{target_name}"
    end
    target_ident = MIR::Ident.new(capture_mapped_name(target_name) || safe)
    # Dereference the bare cell pointer before calling the method; Zig does
    # not auto-deref far enough for these atomic operations.
    cell = MIR::Deref.new(target_ident)

    arg_ast = if node.compound_op
                # Desugared form: node.value is BinaryOp(target, op, rhs).
                # Pull the rhs (the original `n` from `c += n`).
                node.value.right
              else
                node.value
              end
    arg = lower(arg_ast)
    method_call = MIR::MethodCall.new(cell, op_name, [arg], false, MIR::CallableContract.no_ownership(1))
    # `store` returns void; the fetch_* ops return the old value that
    # Zig requires us to consume. We discard since CLEAR's `c += n`
    # statement form ignores the result.
    discard = node.auto_atomic_op != :store
    MIR::ExprStmt.new(method_call, discard)
  end

  sig { params(node: AST::Assignment).returns(MIR::Node) }
  def lower_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    special_result = special_assignment_result(node)
    return special_result if special_result

    plan = assignment_target_plan(node)
    value = assignment_value(node)
    result = MIR::Set.new(plan.target, value)
    with_ownership_consumption_for_value(result, value, node.value, "MIR::Set")
    mark_field_assignment_cleanup!(result, plan)

    result
  end

  sig { params(node: AST::Assignment).returns(T.nilable(MIR::Stmt)) }
  def special_assignment_result(node)
    name = node.name
    return T.cast(lower_indexed_assignment(node), MIR::Stmt) if name.is_a?(AST::GetIndex)
    return T.cast(lower_auto_lock_assignment(node), MIR::Stmt) if name.is_a?(AST::GetField) && node.auto_lock
    return lower_field_assignment_with_cleanup(node) if name.is_a?(AST::GetField) && node.field_pre_cleanup

    nil
  end

  sig { params(node: AST::Assignment).returns(AssignmentTargetPlan) }
  def assignment_target_plan(node)
    T.bind(self, MIRLowering) rescue nil
    name = node.name
    if name.is_a?(String)
      return AssignmentTargetPlan.new(
        target: MIR::Ident.new(assignment_storage_name(name, renamed: false)),
        cleanup_field: nil,
      )
    end

    field = name.is_a?(AST::GetField) ? name : nil
    cleanup_field = field && !node.field_pre_cleanup ? field : nil
    AssignmentTargetPlan.new(
      target: T.cast(lower(name), MIR::Emittable),
      cleanup_field: cleanup_field,
    )
  end

  sig { params(node: AST::Assignment).returns(MIR::Emittable) }
  def assignment_value(node)
    T.bind(self, MIRLowering) rescue nil
    value = T.cast(lower(node.value), MIR::Emittable)
    copy_container_borrow_if_needed(value, node.value)
  end

  sig { params(result: MIR::Set, plan: AssignmentTargetPlan).void }
  def mark_field_assignment_cleanup!(result, plan)
    field = plan.cleanup_field
    result.needs_field_cleanup = true if field && field_assignment_requires_cleanup?(field)
    nil
  end

  sig { params(field: AST::GetField).returns(T::Boolean) }
  def field_assignment_requires_cleanup?(field)
    T.bind(self, MIRLowering) rescue nil
    field_type = field.full_type!
    return true if field_type.needs_cleanup?(mir_schema_lookup)
    return false unless field_type.string?

    !!field_assignment_root_identifier(field)&.symbol&.heap_storage?
  end

  sig { params(field: AST::GetField).returns(T.nilable(AST::Identifier)) }
  def field_assignment_root_identifier(field)
    root = T.let(field.target, T.untyped)
    root = root.target while root.is_a?(AST::GetField)
    root.is_a?(AST::Identifier) ? root : nil
  end

  sig { params(value: MIR::Node, target_alloc: T.nilable(Symbol)).returns(T::Array[MIR::Stmt]) }
  def ownership_marks_for_transferred_temp(value, target_alloc: nil)
    T.bind(self, MIRLowering) rescue nil
    return [] unless value.is_a?(MIR::Ident)
    name = value.name.to_s
    entry = function_state.bindings[name] || CleanupEntry::NONE
    guarded = pipeline_guarded_cleanup_name?(name)
    return [] unless guarded || entry.present?
    alloc = target_alloc || (entry.present? ? entry.alloc : :heap)
    ownership_transfer_marks(name, :owned_sink, target_alloc: alloc, move_guarded: guarded)
  end

  sig { params(node: AST::Assignment).returns(MIR::Node) }
  def lower_indexed_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    target_node = node.name.target
    ti = target_node.full_type!(context: "indexed assignment target")

    # VM path: the bc_emitter has native MAP_PUT / NATIVE_CALL list-set!
    # dispatch on MIR::Set(IndexGet, val); avoid the registry-templated
    # Zig backend path.
    return lower_direct_indexed_set(node, cast_index: false) if bc_target?

    receiver_type = Type.new(ti)

    # Raw fixed-size arrays (`Int64[N]`): emit native Zig indexed assignment.
    # The CheatLib.setAt template takes `container: anytype` and copies the
    # array by value -- the helper sees a const local and `container[i] = v`
    # fails. Mirrors direct_index_get's read path for the same shape.
    #
    # The `!collection?` guard excludes `T[N]@list`, `T[N]@pool`, `T[N]@set`,
    # which all happen to be `fixed?` (they declare capacity at the array
    # shape) but use registry-driven indexed access. Only raw `T[N]`
    # without a collection annotation falls through to native assignment.
    if receiver_type.fixed? && !receiver_type.string? && !receiver_type.collection?
      return lower_direct_indexed_set(node, cast_index: true)
    end

    # Resolve INDEX_OPS :set entry via dispatch_key
    kind = ti.dispatch_key
    op_spec = kind && INDEX_OPS.dig(kind, :set)

    target = lower(target_node)
    idx = lower(node.name.index)

    # Fallback for unknown container types or missing registry entries
    unless op_spec
      val = lower(node.value)
      return MIR::ExprStmt.new(emit_builtin(:setAt, [target, idx, val]), false)
    end
    op = FunctionSignature.unwrap(IntrinsicRegistry.fs(op_spec, :"#{kind}_set"))
    raise "indexed assignment: missing registry signature for #{kind}" unless op

    # HashMap (string/numeric, possibly sharded/striped/Arc-wrapped):
    # emit the structural MIR::ShardedMapPut. Both backends consume it
    # directly, so the checker has visibility into key dupe / value
    # transforms / shard-direct vs routed dispatch from the node fields.
    if kind == :string_map || kind == :numeric_map
      return lower_map_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
    end

    # Non-HashMap kinds (array, list, pool, set_collection) keep their
    # registry template path below. The BC backend already returned above
    # with a structural Set(IndexGet, value).
    lower_template_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
  end

  sig { params(node: AST::Assignment, cast_index: T::Boolean).returns(MIR::Set) }
  def lower_direct_indexed_set(node, cast_index:)
    T.bind(self, MIRLowering) rescue nil
    target = lower(node.name.target)
    idx = lower(node.name.index)
    idx = MIR::Cast.new(idx, "usize", :intCast) if cast_index
    target_alloc = placement_for_node(node.name.target)
    value_type = Type.from_node!(node.value, context: "direct indexed assignment value")
    val = with_decl_alloc(target_alloc) { lower(node.value) }
    if ownership_tracked_transfer_type?(value_type)
      val = materialize_owned_sink_value(val, node.value, target_alloc, value_type)
      val = hoist_alloc(val, node.value, err_cleanup: true) if mir_allocates?(val)
    end
    set = MIR::Set.new(MIR::IndexGet.new(target, idx), val)
    with_ownership_consumption_for_value(set, val, node.value, "MIR::Set", target_alloc: target_alloc)
    set
  end

  sig do
    params(
      node: AST::Assignment,
      target_node: AST::Node,
      receiver_type: Type,
      target: MIR::Node,
      idx: MIR::Node,
      kind: Symbol,
      op: FunctionSignature
    ).returns(MIR::ShardedMapPut)
  end
  def lower_map_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
    T.bind(self, MIRLowering) rescue nil
    shard = shard_context
    dispatch = indexed_assignment_dispatch(kind, receiver_type, target_node, node, op)
    sink_type = receiver_type.value_type
    val = with_sink_type(sink_type) do
      with_decl_alloc(dispatch.sink_alloc) { lower(node.value) }
    end

    # Map keys are duped internally by put -- always frame-allocate the
    # key expression so it's cleaned by arena rewind (no orphaned heap
    # temporary).
    if kind == :string_map && idx.is_a?(MIR::ConcatStr)
      idx = MIR::ConcatStr.new(idx.parts, alloc_expr(:frame), idx.rt_expr)
    end
    idx = hoist_alloc(idx, node.name.index) if kind == :string_map
    # Map put takes ownership of the stored value on success. If the value
    # expression produces owned children, expose that temporary to MIRChecker
    # with error-only cleanup: normal cleanup would double-free after the map owns it.
    val = materialize_owned_sink_value(val, node.value, dispatch.sink_alloc) unless dispatch.shard_direct && rodata_ownership_ast?(node.value)
    val = hoist_alloc(val, node.value, err_cleanup: true)

    if !bc_target? && receiver_type.rc_map?
      # Auto-deref Arc/Rc-wrapped containers (Zig-only -- BC has no
      # .ctrl.data wrapping and a single MapRef cell holds the data).
      target = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(target, "ctrl"), "data"))
    end
    if dispatch.shard_direct
      return T.cast(with_ownership_consumption_for_value(
        MIR::ShardedMapPut.new(target, idx, val,
          MIR::Ident.new(T.must(shard)[:idx]),
          MIR::Ident.new(T.must(shard)[:key]),
          kind, op, dispatch.key_type, dispatch.value_type, dispatch.resolved_allocs, dispatch.template_kind,
          extract_root_var_name(target_node)),
        val,
        node.value,
        "MIR::ShardedMapPut",
        target_alloc: dispatch.sink_alloc,
      ), MIR::ShardedMapPut)
    end
    T.cast(with_ownership_consumption_for_value(
      MIR::ShardedMapPut.new(target, idx, val, nil, nil, kind, op, dispatch.key_type, dispatch.value_type, dispatch.resolved_allocs, dispatch.template_kind,
        extract_root_var_name(target_node)),
      val,
      node.value,
      "MIR::ShardedMapPut",
      target_alloc: dispatch.sink_alloc,
    ), MIR::ShardedMapPut)
  end

  sig do
    params(
      node: AST::Assignment,
      target_node: AST::Node,
      receiver_type: Type,
      target: MIR::Node,
      idx: MIR::Node,
      kind: Symbol,
      op: FunctionSignature
    ).returns(MIR::Node)
  end
  def lower_template_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
    T.bind(self, MIRLowering) rescue nil

    val_node = node.value
    value_type_for_transfer = Type.from_node!(val_node, context: "indexed assignment value transfer")
    owns_transferred_value = ownership_tracked_transfer_type?(value_type_for_transfer)
    dispatch = indexed_assignment_dispatch(
      kind,
      receiver_type,
      target_node,
      node,
      op
    )

    sink_type = receiver_type.value_type || value_type_for_transfer
    val = with_decl_alloc(dispatch.sink_alloc) do
      with_sink_type(sink_type) { lower(node.value) }
    end
    if op.intrinsic_takes_value? && owns_transferred_value && !dispatch.shard_direct
      val = materialize_owned_sink_value(val, val_node, dispatch.sink_alloc, sink_type)
      val = hoist_alloc(val, val_node, err_cleanup: true)
      if val.is_a?(MIR::Ident)
        move_mark_field!(val_node)
      end
    end
    ownership_operands = ownership_operands_for_value(
      val,
      val_node,
      "indexed assignment",
      dispatch.sink_alloc,
    )
    consumed_names = T.let(ownership_operands.filter_map { |operand|
      next nil unless operand.kind == :owned_binding
      operand.name
    }, T::Array[String])

    entry = op
    ownership_contract = MIR::OwnershipContract.consume_operands(ownership_operands)
    setAt_stmt = MIR::ExprStmt.new(MIR::IndexedStore.new(
      target: target,
      index: idx,
      value: val,
      entry: entry,
      template_kind: dispatch.template_kind,
      map_kind: kind,
      ownership_contract: ownership_contract,
      allocs: dispatch.resolved_allocs,
      target_var: extract_root_var_name(target_node),
      key_type: dispatch.key_type,
      value_type: dispatch.value_type,
    ), false)
    post_transfer_marks = consumed_names.flat_map do |name|
      guarded = pipeline_guarded_cleanup_name?(name)
      ownership_transfer_marks(name, :owned_sink, target_alloc: dispatch.sink_alloc, move_guarded: guarded)
    end

    # Emit pre-cleanup for non-Copy element types in list collections so the
    # overwritten element is freed before the new value is written in place.
    if kind == :array || kind == :list
      elem_ti = T.must(receiver_type.element_type)
      if ownership_tracked_transfer_type?(elem_ti)
        elem_zig = elem_ti.zig_type
        cleanup_call = emit_builtin(:cleanupAt, [
          MIR::Ident.new(elem_zig),
          target,
          MIR::AllocatorRef.new(dispatch.sink_alloc),
          idx,
        ])
        return MIR::ScopeBlock.new([MIR::ExprStmt.new(cleanup_call, false), setAt_stmt, *post_transfer_marks])
      end
    end

    return MIR::ScopeBlock.new([setAt_stmt, *post_transfer_marks]) if post_transfer_marks.any?

    setAt_stmt
  end

  sig do
    params(
      kind: Symbol,
      receiver_type: Type,
      target_node: AST::Node,
      assignment: AST::Assignment,
      op: FunctionSignature
    ).returns(IndexedAssignmentDispatch)
  end
  def indexed_assignment_dispatch(kind, receiver_type, target_node, assignment, op)
    T.bind(self, MIRLowering) rescue nil

    target_var = indexed_assignment_target_var(target_node)
    shard = shard_context
    shard_direct = !!(shard && target_var == shard[:map] && op.intrinsic_template(IntrinsicTemplateKind::ShardDirectZig))
    template_kind = if shard_direct
      IntrinsicTemplateKind::ShardDirectZig
    elsif (receiver_type.sharded? || receiver_type.striped?) && op.intrinsic_template(IntrinsicTemplateKind::ShardedZig)
      IntrinsicTemplateKind::ShardedZig
    else
      IntrinsicTemplateKind::Zig
    end
    resolved_allocs = indexed_assignment_allocs(op, target_node, assignment)
    receiver_alloc = T.unsafe(self).send(:placement_for_node, target_node)
    IndexedAssignmentDispatch.new(
      target_var: target_var,
      shard_direct: shard_direct,
      template_kind: template_kind,
      key_type: (kind == :numeric_map ? receiver_type.key_type : nil),
      value_type: (kind == :numeric_map ? receiver_type.value_type : nil),
      resolved_allocs: resolved_allocs,
      sink_alloc: resolved_allocs.value_alloc || resolved_allocs.primary || resolved_allocs.shard_alloc || receiver_alloc
    )
  end

  sig { params(target_node: AST::Node).returns(T.nilable(String)) }
  def indexed_assignment_target_var(target_node)
    target_node.is_a?(AST::Identifier) ? target_node.name.to_s : nil
  end

  sig do
    params(
      op: FunctionSignature,
      target_node: AST::Node,
      assignment: AST::Assignment
    ).returns(MIR::InlineAllocMetadata)
  end
  def indexed_assignment_allocs(op, target_node, assignment)
    T.bind(self, MIRLowering) rescue nil

    MIR::InlineAllocMetadata.new(
      alloc: indexed_assignment_resolved_alloc(op, IntrinsicAllocationKind::Alloc, target_node, assignment),
      key_alloc: indexed_assignment_resolved_alloc(op, IntrinsicAllocationKind::KeyAlloc, target_node, assignment),
      val_alloc: indexed_assignment_resolved_alloc(op, IntrinsicAllocationKind::ValAlloc, target_node, assignment),
      shard_alloc: indexed_assignment_resolved_alloc(op, IntrinsicAllocationKind::ShardAlloc, target_node, assignment),
    )
  end

  sig { params(op: FunctionSignature, alloc_key: IntrinsicAllocationKind, target_node: AST::Node, assignment: AST::Assignment).returns(T.nilable(Symbol)) }
  def indexed_assignment_resolved_alloc(op, alloc_key, target_node, assignment)
    T.bind(self, MIRLowering) rescue nil

    registry_alloc = indexed_assignment_registry_alloc(op, alloc_key)
    return nil unless registry_alloc

    resolve_alloc_sym(registry_alloc, target_node, assignment)
  end

  sig { params(op: FunctionSignature, alloc_key: IntrinsicAllocationKind).returns(T.nilable(Symbol)) }
  def indexed_assignment_registry_alloc(op, alloc_key)
    op.intrinsic_alloc(alloc_key)
  end

  sig { params(node: AST::Assignment).returns(MIR::ScopeBlock) }
  def lower_field_assignment_with_cleanup(node)
    T.bind(self, MIRLowering) rescue nil
    target = lower(node.name.target)
    field = node.name.field.to_s
    # Field cleanup uses the container binding's finalized placement.
    alloc_sym = placement_for_node(root_receiver_node(node.name) || node.name)
    value = with_decl_alloc(alloc_sym) do
      lowered = lower(node.value)
      place_value_for_destination(lowered, node.value, alloc_sym, node.name.full_type!)
    end
    value = materialize_owned_sink_value(value, node.value, alloc_sym)
    alloc = MIR::AllocatorRef.new(alloc_sym)
    field_get = MIR::FieldGet.new(target, field)
    # The field name is known statically; comptime resolves the type from the
    # binding's actual shape at emission.
    type_expr = MIR::TypeOf.new(field_get)
    cleanup_call = MIR::Call.new("CheatLib.cleanup", [
      type_expr, alloc, MIR::AddressOf.new(field_get)
    ], false, false, MIR::CallableContract.no_ownership(3))
    assign = MIR::Set.new(field_get, value)
    with_ownership_consumption_for_value(assign, value, node.value, "MIR::Set", target_alloc: alloc_sym)
    MIR::ScopeBlock.new([MIR::ExprStmt.new(cleanup_call, false), assign])
  end

  sig { params(node: AST::Assignment).returns(MIR::Node) }
  def lower_auto_lock_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    facts = auto_lock_assignment_facts(node)

    len_guard = ->(old_name, alloc_sym) {
      MIR::IfStmt.new(
        MIR::BinOp.new(">", MIR::ListLength.new(MIR::Ident.new(old_name)), MIR::Lit.new("0")),
        [MIR::ExprStmt.new(MIR::FreeSlice.new(MIR::Ident.new(old_name), alloc_sym), false)],
        nil
      )
    }

    if SymbolEntry.always_mutable_sync?(facts.sync)
      value = auto_lock_assignment_value(node, facts.alloc_sym)
      value_pending = flush_pending
      get_field = MIR::FieldGet.new(MIR::MethodCall.new(MIR::Ident.new(facts.zig_var), "get", [], false,
        MIR::CallableContract.no_ownership(0)), facts.field)
      if facts.cleanup_alloc
        stmts = T.let([
          *value_pending,
          MIR::Let.new("__old", get_field, false, nil, nil),
          T.cast(with_ownership_consumption_for_value(MIR::Set.new(get_field, value), value, node.value, "MIR::Set",
            target_alloc: facts.alloc_sym), MIR::Set),
        ], T::Array[MIR::Node])
        stmts << len_guard.call("__old", facts.cleanup_alloc)
        return MIR::ScopeBlock.new(append_ownership_transfers_for_mir_body(stmts))
      else
        set = MIR::Set.new(get_field, value)
        with_ownership_consumption_for_value(set, value, node.value, "MIR::Set", target_alloc: facts.alloc_sym)
        return set
      end
    end

    acquire_method = SymbolEntry.write_locked_sync?(facts.sync) ? "write" : "acquire"
    prev_locked = capability_state.locked_unwrap_map
    capability_state.locked_unwrap_map = (prev_locked || {}).merge({ facts.alias_var => true, facts.var_name => facts.alias_var })
    value = auto_lock_assignment_value(node, facts.alloc_sym)
    value_pending = flush_pending
    capability_state.locked_unwrap_map = prev_locked
    alias_field = MIR::FieldGet.new(MIR::Ident.new(facts.alias_var), facts.field)
    stmts = T.let([
      MIR::Let.new(facts.guard_var, MIR::MethodCall.new(MIR::Ident.new(facts.zig_var), acquire_method, [], false,
        MIR::CallableContract.no_ownership(0)), true, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(facts.guard_var), "release", [], false,
        MIR::CallableContract.no_ownership(0))),
      MIR::Let.new(facts.alias_var, MIR::MethodCall.new(MIR::Ident.new(facts.guard_var), "get", [], false,
        MIR::CallableContract.no_ownership(0)), false, nil, nil),
      *value_pending,
    ], T::Array[MIR::Node])
    if facts.cleanup_alloc
      stmts << MIR::Let.new("__old", alias_field, false, nil, nil)
      stmts << T.cast(with_ownership_consumption_for_value(MIR::Set.new(alias_field, value), value, node.value, "MIR::Set",
        target_alloc: facts.alloc_sym), MIR::Set)
      stmts << len_guard.call("__old", facts.cleanup_alloc)
    else
      stmts << T.cast(with_ownership_consumption_for_value(MIR::Set.new(alias_field, value), value, node.value, "MIR::Set",
        target_alloc: facts.alloc_sym), MIR::Set)
    end
    MIR::ScopeBlock.new(append_ownership_transfers_for_mir_body(stmts))
  end

  sig { params(node: AST::Assignment).returns(AutoLockAssignmentFacts) }
  def auto_lock_assignment_facts(node)
    T.bind(self, MIRLowering) rescue nil
    auto_lock = T.let(node.auto_lock, AST::AutoLockPlan)
    var_name = auto_lock.var
    cleanup_alloc = T.let(node.field_pre_cleanup, T.nilable(Symbol))
    AutoLockAssignmentFacts.new(
      var_name: var_name,
      sync: auto_lock.sync,
      guard_var: "__#{var_name}_guard",
      alias_var: "__#{var_name}_inner",
      zig_var: (capture_state.do_capture_map&.dig(var_name) || var_name).to_s,
      field: node.name.field.to_s,
      cleanup_alloc: cleanup_alloc,
      alloc_sym: cleanup_alloc || placement_for_node(root_receiver_node(node.name) || node.name)
    )
  end

  sig { params(node: AST::Assignment, alloc_sym: Symbol).returns(MIR::Node) }
  def auto_lock_assignment_value(node, alloc_sym)
    T.bind(self, MIRLowering) rescue nil
    value = with_decl_alloc(alloc_sym) do
      lowered = lower(node.value)
      placed = place_value_for_destination(lowered, node.value, alloc_sym, node.name.full_type!)
      materialize_owned_sink_value(placed, node.value, alloc_sym, node.name.full_type!)
    end
    value && mir_allocates?(value) ? hoist_alloc(value, node.value, err_cleanup: true) : value
  end

  # ================================================================
  # Control flow
  # ================================================================


  private :allocating_init_var_decl_plan
  private :assignment_target_plan
  private :assignment_value
  private :auto_lock_assignment_facts
  private :auto_lock_assignment_value
  private :binding_metadata_var_decl_plan
  private :binding_placement_fact
  private :classified_cleanup_var_decl_plan
  private :cleanup_entry_for_ast_binding
  private :compose_capability_wrap
  private :ensure_cleanup_binding_owns_string_init
  private :field_access_moves_owner?
  private :field_assignment_requires_cleanup?
  private :field_assignment_root_identifier
  private :field_owner_move_marks
  private :indexed_assignment_allocs
  private :indexed_assignment_registry_alloc
  private :indexed_assignment_resolved_alloc
  private :indexed_assignment_target_var
  private :list_collection_copy?
  private :lower_atomic_assignment
  private :lower_auto_lock_assignment
  private :lower_direct_indexed_set
  private :lower_field_assignment_with_cleanup
  private :lower_indexed_assignment
  private :lower_map_indexed_assignment
  private :lower_template_indexed_assignment
  private :lower_var_decl
  private :lower_var_decl_init
  private :destructure_declaration_kind
  private :lower_destructure_target
  private :mark_field_assignment_cleanup!
  private :mark_guarded_cleanup_name!
  private :moved_guard_cleanup_entry
  private :mutated_owned_var_decl?
  private :mutated_owned_var_decl_plan
  private :optional_nil_initializer?
  private :owned_binding_source_alloc
  private :owned_return_call_init?
  private :owned_return_call_var_decl_plan
  private :owned_return_transfer_binding?
  private :source_already_has_declared_capability?
  private :special_assignment_result
  private :stamp_var_decl_init_target!
  private :transfer_only_var_decl?
  private :transfer_only_var_decl_plan
  private :type_requires_alloc_cleanup?
  private :var_decl_alloc_mark
  private :var_decl_facts
  private :var_decl_materialization_plan
  private :var_decl_safe_name
  private :var_decl_source_borrowed?
  private :var_decl_source_transfer_required?
  private :var_decl_suppression

end
