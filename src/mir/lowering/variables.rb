# typed: strict
require "sorbet-runtime"

module MIRLoweringVariables
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  class IndexedAssignmentDispatch < T::Struct
    const :target_var, T.nilable(String)
    const :shard_direct, T::Boolean
    const :template_kind, Symbol
    const :template, String
    const :key_zig, T.nilable(String)
    const :val_zig, T.nilable(String)
    const :resolved_allocs, T::Hash[Symbol, Symbol]
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

  class VarDeclFacts < T::Struct
    const :ft, Type
    const :binding_entry, CleanupEntry
    const :has_mir_drop, T::Boolean
    const :actually_mutated, T::Boolean
    const :forced_var, T::Boolean
    const :keyword_mutable, T::Boolean
    const :annotation, T.nilable(String)
    const :heap_return_var, T::Boolean
    const :decl_alloc, Symbol
    const :has_caps, T::Boolean
    const :bare_zig, String
  end

  sig { params(node: AST::FunctionDef, mutable_scalar_params: T::Set[String]).returns(T.nilable(String)) }
  def tied_shared_family_return_param(node, mutable_scalar_params)
    T.bind(self, MIRLowering) rescue nil
    ret = node.return_type
    return nil unless ret.is_a?(Type) && ret.polymorphic_shared?
    return nil unless ret.resolved.to_s.match?(/\A[A-Z]\z/)
    params = node.params.select do |p|
      pt = p.type || Type.new(:Any)
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
  sig { params(inner_mir: T.any(MIR::ContainerInit, MIR::StructInit), bare_zig_t: String, ft: Type, alloc: Symbol).returns(T.any(MIR::CapWrap, MIR::ContainerInit, MIR::StructInit)) }
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

  sig { params(node: AST::VarDecl).returns(T.untyped) }
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

    safe_name = var_decl_safe_name(node, facts.has_mir_drop)
    stamp_var_decl_init_target!(init, safe_name, facts.binding_entry)

    let_node = MIR::Let.new(
      safe_name,
      init,
      facts.keyword_mutable,
      facts.annotation,
      var_decl_suppression(safe_name, node, facts)
    )

    nodes = build_var_decl_nodes(node, facts, safe_name, init, let_node)

    owner_marks = field_owner_move_marks(node)
    return nodes if owner_marks.empty?
    return nodes + owner_marks if nodes.is_a?(Array)

    [nodes, *owner_marks]
  end

  sig { params(node: AST::VarDecl).returns(VarDeclFacts) }
  def var_decl_facts(node)
    T.bind(self, MIRLowering) rescue nil
    @current_bindings = T.let(@current_bindings, T.untyped)
    is_mutable = node.respond_to?(:mutable) && node.mutable
    ft = Type.new(node.full_type)
    is_mutable ||= ft.dynamic_stream? || ft.bounded_stream? || ft.shared_promise? || ft.open_stream? || ft.inf_stream?
    is_mutable ||= ft.collection?
    is_mutable ||= ft.any_sync?
    is_mutable ||= ft.resource? || node.resource_close_zig
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
    binding_entry = node_entry || @current_bindings[decl_name] || CleanupEntry::NONE
    has_mir_drop = binding_entry.needs_cleanup? && !binding_entry.match_as?

    actually_mutated = is_mutable && node.respond_to?(:var_mutated) && node.var_mutated == true
    actually_mutated = actually_mutated == true
    is_heap = !!node.symbol&.heap_storage?
    has_mutable_cleanup = has_mir_drop || ft.collection? || ft.dynamic_stream? || ft.bounded_stream? || ft.shared_promise? ||
                          ft.open_stream? || ft.inf_stream? || (ft.array? && ft.dynamic?) ||
                          is_heap || ft.resource? || node.resource_close_zig
    forced_var = is_mutable && has_mutable_cleanup
    forced_var = forced_var == true
    # Borrowed-by-reference bindings force Zig `var` even when local mutation
    # analysis only sees field mutation through the callee.
    by_ref_borrow = node.symbol&.mutable_ref_target == true || node.symbol&.poly_borrow_target == true
    keyword_mutable = if !is_mutable
      false
    elsif actually_mutated || forced_var || by_ref_borrow
      true
    else
      false
    end

    zig_type = transpile_type(node.full_type)
    needs_annotation = ZigTypeMapper::ZIG_PRIMITIVES.include?(zig_type) || ft.fn_type? ||
                       (node.value.is_a?(AST::Literal) && node.value.type == :NIL) ||
                       (ft.string? && is_heap)  # ""/literal infers *const [0:0]u8 without annotation
    annotation = needs_annotation ? zig_type : nil

    # Resolve init value - special handling for collection types.
    # Per-declaration storage (set by escape analysis) takes precedence over the
    # name-keyed cleanup plan (which may be stale for same-name vars in different scopes).
    # Escape analysis stamping (:heap) takes precedence. For :frame, trust the
    # cleanup_bindings alloc (which correctly handles sharded/pool/always-heap types).
    @current_fn_heap_carry_return_vars = T.let(@current_fn_heap_carry_return_vars, T.untyped)
    heap_return_var = @current_fn_heap_carry_return_vars&.include?(node.name.to_s)
    heap_return_binding_allocates = heap_return_var && escaping_value_alloc(ft) == :heap
    decl_alloc = if node.symbol&.heap_storage? || heap_return_binding_allocates
      :heap
    elsif heap_return_var
      :frame
    else
      (binding_entry.present? && binding_entry.alloc) || alloc_for_node(node)
    end
    # Group 2 (data shape) is constructed against the BARE type — no
    # sync/ownership wrappers. Group 1 wrapping is applied via
    # compose_capability_wrap once the inner is built. This separation is
    # what makes "@<shape>:<sync>:<ownership>" combinations compose without
    # per-shape × per-cap glue.
    has_caps = (ft.any_sync? || ft.ownership != :affine) == true
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
      has_caps: has_caps,
      bare_zig: bare_zig
    )
  end

  sig { params(node: AST::VarDecl, has_mir_drop: T::Boolean).returns(String) }
  def var_decl_safe_name(node, has_mir_drop)
    T.bind(self, MIRLowering) rescue nil
    @decl_zig_name_map = T.let(@decl_zig_name_map, T.untyped)
    @fn_alloc_marked_names = T.let(@fn_alloc_marked_names, T.untyped)
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    @tmp_counter = T.let(@tmp_counter, T.untyped)
    # `_` is not a valid Zig binding identifier; a discarded value that
    # still needs cleanup must bind to a unique temp. binding_entry
    # stays keyed by `_` so its cleanup recipe is preserved.
    if node.name.to_s == "_"
      @tmp_counter += 1
      safe_name = "__discard_#{@tmp_counter}"
    else
      safe_name = zig_safe_name(node.name)
    end

    # Disambiguate when two variables in the same function would share a Zig
    # name AND both emit AllocMarks (has_mir_drop).  The MIR checker's flat
    # name-keyed allocs dict conflates them; appending the source line makes
    # the names unique so the checker sees independent containers.
    original_safe = safe_name
    if has_mir_drop && @fn_alloc_marked_names&.key?(safe_name)
      safe_name = "#{safe_name}_L#{node.line}"
    end
    if has_mir_drop && @fn_alloc_marked_names
      @fn_alloc_marked_names[safe_name] = true
      @decl_zig_name_map[node.object_id] = safe_name
      # Name-keyed view used by AST markers lowered later (see
      # @fn_name_rename_map init comment). Overwrites when the same name
      # is re-declared in a sibling branch — lowering order matches the
      # lexical order in which AST markers reference each decl, so the
      # latest entry is the one in scope for the next marker.
      @fn_name_rename_map[original_safe] = safe_name if @fn_name_rename_map
    end

    T.must(safe_name)
  end

  sig { params(safe_name: String, node: AST::VarDecl, facts: VarDeclFacts).returns(T.nilable(String)) }
  def var_decl_suppression(safe_name, node, facts)
    if facts.keyword_mutable
      if facts.actually_mutated && node.var_used && !facts.forced_var
        nil
      else
        "_ = &#{safe_name};"
      end
    else
      (node.var_used || facts.has_mir_drop) ? nil : "_ = #{safe_name};"
    end
  end

  sig { params(init: T.untyped, safe_name: String, binding_entry: CleanupEntry).void }
  def stamp_var_decl_init_target!(init, safe_name, binding_entry)
    T.bind(self, MIRLowering) rescue nil
    if mir_allocates?(init)
      stamp_allocating_result_target!(init, safe_name, alloc: binding_entry[:alloc])
    elsif init.is_a?(MIR::InlineZig) && init.allocs && !init.allocs.empty?
      emits = init.stdlib_def&.emit
      if !init.target_var || (emits&.allocates && !emits&.mutates_receiver)
        init.target_var = safe_name
      end
      binding_alloc = binding_entry[:alloc]
      if init.target_var == safe_name && binding_alloc
        init.allocs = init.allocs.transform_values { |_alloc| binding_alloc }
      end
    end
  end

  sig { params(node: AST::VarDecl, facts: VarDeclFacts, safe_name: String, init: T.untyped, let_node: MIR::Let).returns(T.untyped) }
  def build_var_decl_nodes(node, facts, safe_name, init, let_node)
    T.bind(self, MIRLowering) rescue nil
    ft = facts.ft
    binding_entry = facts.binding_entry
    has_mir_drop = facts.has_mir_drop
    heap_return_var = facts.heap_return_var
    decl_alloc = facts.decl_alloc
    actually_mutated = facts.actually_mutated
    # Emit AllocMark + Let + Cleanup triple when the binding needs cleanup.
    # Replaces the OLD MIR::Alloc/Drop sibling nodes inserted by MIRPass.
    if has_mir_drop
      # has_mir_drop implies binding_entry.needs_cleanup?, so the entry is
      # always present (NONE.needs_cleanup? is false). The cleanup recipe is
      # inherited from the classifier, never synthesized here (INV-14).
      drop_entry = binding_entry.dup
      build_drop_entry!(drop_entry, node.full_type, node)
      drop_entry[:has_moved_guard] = true if ft.bounded_stream?
      # One allocator per binding: AllocMark, Cleanup, and the init
      # expression all read the classifier's definitive placement.
      node_alloc = drop_entry.alloc || decl_alloc
      (@guarded_cleanup_names ||= {})[safe_name] = true if drop_entry.has_moved_guard?
      mir_alloc = resolve_decl_stdlib_alloc(node) || node_alloc
      cleanup = MIR::Cleanup.new(safe_name, drop_entry)
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = drop_entry.scope
      [alloc_mark, let_node, cleanup]
    elsif owned_return_call_init?(init) && !(ft.generic_instance? && ft.generic_base == :Id)
      mir_alloc = binding_entry[:alloc] || :heap
      cleanup_entry = hoist_cleanup_entry(init, node) || CleanupEntry.build(:uniform, alloc: mir_alloc, has_moved_guard: true)
      build_drop_entry!(cleanup_entry, node.full_type, node)
      cleanup_entry[:has_moved_guard] = true
      (@guarded_cleanup_names ||= {})[safe_name] = true
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = mir_alloc == :heap ? :heap : (binding_entry.present? ? binding_entry.scope : :iteration)
      [alloc_mark, let_node, MIR::Cleanup.new(safe_name, cleanup_entry)]
    elsif !heap_return_var && owned_return_transfer_binding?(binding_entry, init) && !(ft.generic_instance? && ft.generic_base == :Id)
      mir_alloc = resolve_decl_stdlib_alloc(node) || binding_entry.alloc || :heap
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = mir_alloc == :heap ? :heap : (binding_entry.present? ? binding_entry.scope : :iteration)
      [alloc_mark, let_node]
    elsif init.is_a?(MIR::InlineZig) && init.allocs && !init.allocs.empty? && init.target_var == safe_name &&
          !(ft.generic_instance? && ft.generic_base == :Id)
      alloc_values = init.allocs.values
      mir_alloc = resolve_decl_stdlib_alloc(node) || (alloc_values.include?(:heap) ? :heap : :frame)
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = mir_alloc == :heap ? :heap : (binding_entry.present? ? binding_entry.scope : :iteration)
      [alloc_mark, let_node]
    elsif binding_entry.present? && !binding_entry.needs_cleanup? && actually_mutated && ownership_bearing_type?(ft) &&
          (!ft.string? || mir_allocates?(init) || owned_return_call_init?(init))
      mir_alloc = mir_owned_alloc(init) || resolve_decl_stdlib_alloc(node) || binding_entry.alloc || decl_alloc
      cleanup_entry = CleanupEntry.build(ft.string? ? :heap_string : :uniform, alloc: mir_alloc, has_moved_guard: true)
      build_drop_entry!(cleanup_entry, node.full_type, node)
      (@guarded_cleanup_names ||= {})[safe_name] = true
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = mir_alloc == :heap ? :heap : (binding_entry.scope || :iteration)
      [alloc_mark, let_node, MIR::Cleanup.new(safe_name, cleanup_entry)]
    elsif binding_entry.present? && !binding_entry.needs_cleanup?
      mir_alloc = resolve_decl_stdlib_alloc(node) || (heap_return_var ? decl_alloc : binding_entry.alloc) || decl_alloc
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = mir_alloc == :heap ? :heap : (binding_entry.scope || :iteration)
      [alloc_mark, let_node]
    elsif mir_allocates?(init) && !(ft.generic_instance? && ft.generic_base == :Id)
      mir_alloc = resolve_decl_stdlib_alloc(node) || decl_alloc
      alloc_mark = MIR::AllocMark.new(safe_name, mir_alloc, node.full_type)
      alloc_mark.scope = mir_alloc == :heap ? :heap : (binding_entry.present? ? binding_entry.scope : :iteration)
      if binding_entry.present? && !binding_entry.needs_cleanup?
        next_nodes = T.let([alloc_mark, let_node], T::Array[T.untyped])
        next_nodes
      else
      cleanup_required = !ft.primitive? && !ft.void? && !ft.any? &&
                         !(ft.generic_instance? && ft.generic_base == :Id) &&
                         (ft.needs_explicit_cleanup?(mir_alloc, @schema_lookup) ||
                          (mir_alloc == :heap && (ft.string? || ft.heap_ptr? || ft.collection_value? ||
                            ft.any_sync? || ft.indirect? || ft.recursive_cleanup_shape?(@schema_lookup))))
      unless cleanup_required
        next_nodes = T.let([alloc_mark, let_node], T::Array[T.untyped])
        next_nodes
      else
        cleanup_entry = T.must(hoist_cleanup_entry(init, node))
        build_drop_entry!(cleanup_entry, node.full_type, node)
        (@guarded_cleanup_names ||= {})[safe_name] = true if cleanup_entry.has_moved_guard?
        [alloc_mark, let_node, MIR::Cleanup.new(safe_name, cleanup_entry)]
      end
      end
    else
      let_node
    end
  end

  sig do
    params(
      node: AST::VarDecl,
      ft: Type,
      bare_zig: String,
      has_caps: T::Boolean,
      decl_alloc: Symbol
    ).returns(T.untyped)
  end
  def lower_var_decl_init(node, ft, bare_zig, has_caps, decl_alloc)
    T.bind(self, MIRLowering) rescue nil
    if node.value.is_a?(AST::NextExpr)
      return lower_next_expr(node.value, decl_alloc)
    end

    rhs = node.value
    rhs_unwrapped = (rhs.is_a?(AST::BinaryOp) && rhs.op == :OR_RESCUE) ? rhs.left : rhs
    if ft.pool?
      return lower(node.value) if rhs_unwrapped.is_a?(AST::MoveNode) || AST.call?(rhs_unwrapped) || !rhs_unwrapped.is_a?(AST::ListLit)
      inner = MIR::ContainerInit.new(bare_zig, :pool, decl_alloc, ft.capacity)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    if ft.set_collection?
      return lower(node.value) if rhs.is_a?(AST::BinaryOp) && rhs.op == :SMOOTH
      return lower(node.value) if rhs_unwrapped.is_a?(AST::MoveNode) || AST.call?(rhs_unwrapped) || !rhs_unwrapped.is_a?(AST::ListLit)
      inner = MIR::ContainerInit.new(bare_zig, :set_empty, nil, nil)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    if ft.list_collection?
      return lower(node.value) if rhs_unwrapped.is_a?(AST::MoveNode)
      return lower_next_expr(rhs_unwrapped, decl_alloc) if rhs_unwrapped.is_a?(AST::NextExpr)
      return lower(node.value) if AST.call?(rhs_unwrapped)
      if list_collection_copy?(rhs_unwrapped)
        return MIR::DeepCopy.new(lower(rhs_unwrapped.value), nil, nil, :full_value, decl_alloc)
      end
      return lower(node.value) unless rhs_unwrapped.is_a?(AST::ListLit)
      init_kind = ft.capacity.is_a?(Integer) && ft.capacity > 0 ? :list_capacity : :list_empty
      init_capacity = init_kind == :list_capacity ? ft.capacity : nil
      inner = MIR::ContainerInit.new(bare_zig, init_kind, decl_alloc, init_capacity)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    if ft.fixed_soa?
      inner = MIR::ContainerInit.new(bare_zig, :list_capacity, decl_alloc, ft.capacity)
      return has_caps ? compose_capability_wrap(inner, bare_zig, ft, decl_alloc) : inner
    end

    retain_source = node.value.is_a?(AST::MoveNode) ? node.value.value : node.value
    return make_rc_retain(retain_source) if node.value.was_moved != true && rc_retain_needed?(retain_source)

    placed = lower(node.value)
    place_value_for_destination(placed, node.value, decl_alloc, ft)
  end

  sig { params(rhs: T.untyped).returns(T::Boolean) }
  def list_collection_copy?(rhs)
    (rhs.is_a?(AST::CopyNode) || rhs.is_a?(AST::CloneNode)) &&
      rhs.value.respond_to?(:full_type) &&
      rhs.value.full_type.list_collection?
  end

  sig { params(node: AST::VarDecl).returns(T::Array[MIR::Stmt]) }
  def field_owner_move_marks(node)
    T.bind(self, MIRLowering) rescue nil

    value = node.value
    return [] unless value.is_a?(AST::GetField)
    return [] unless ownership_bearing_type?(Type.from_node(node.full_type))

    root = AST.root_identifier(value)
    return [] unless root

    source_name = root.name.to_s
    safe = zig_safe_name(source_name)
    rename_map = @fn_name_rename_map
    safe = rename_map[safe].to_s if rename_map&.key?(safe)
    entry = @current_bindings[source_name] || CleanupEntry::NONE
    guarded_names = @guarded_cleanup_names
    guarded = entry.has_moved_guard? || guarded_names&.[](safe) == true
    return [] unless guarded

    [MIR::TransferMark.new(safe, :owned_sink), MIR::MoveMark.new(safe)]
  end

  sig { params(binding_entry: CleanupEntry, init: T.untyped).returns(T::Boolean) }
  def owned_return_transfer_binding?(binding_entry, init)
    T.bind(self, MIRLowering) rescue nil
    return false if binding_entry.needs_cleanup?
    return false unless binding_entry.present?
    return false unless binding_entry.alloc == :heap || binding_entry.alloc == :cleanup

    return false if init.is_a?(MIR::Call)

    if init.is_a?(MIR::InlineZig) || init.is_a?(MIR::RawZig)
      return false unless init.stdlib_def&.emit&.allocates
      return true if init.stdlib_def.emit&.return_alloc == :heap
      return false unless init.is_a?(MIR::InlineZig)

      allocs = init.allocs
      return !!(allocs.is_a?(Hash) && allocs.values.any? { |v| v == :heap })
    end

    false
  end

  sig { params(init: T.untyped).returns(T::Boolean) }
  def owned_return_call_init?(init)
    return owned_return_call_init?(init.expr) if init.is_a?(MIR::Cast)
    return owned_return_call_init?(init.expr) if init.is_a?(MIR::TryExpr)
    !!(init.is_a?(MIR::Call) && init.owned_return?)
  end

  sig { params(node: AST::BindExpr).returns(T.untyped) }
  def lower_bind_expr(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @decl_zig_name_map = T.let(@decl_zig_name_map, T.untyped)
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    if node.mode == :decl
      # Proxy to VarDecl logic. Copy mir_binding_entry so lower_var_decl
      # uses node-identity lookup rather than the name-keyed dict.
      proxy = AST::VarDecl.new(node.token, node.name, node.type, node.value, false)
      proxy.full_type = node.full_type
      proxy.storage = node.storage
      proxy.slot_size = node.slot_size
      proxy.resource_close_zig = node.resource_close_zig
      proxy.var_used = node.var_used
      proxy.symbol = node.symbol if node.respond_to?(:symbol) && proxy.respond_to?(:symbol=)
      result = lower_var_decl(proxy)
      # Line-suffix disambiguation in lower_var_decl stores the renamed Zig
      # name under `proxy.object_id`. Annotator-resolved references point to
      # the original BindExpr (`node`), not the proxy, so without this the
      # reference lowering misses the map and emits the unsuffixed name,
      # producing `var x_L8 = ...; ... x.len` which is undeclared Zig.
      if @decl_zig_name_map && @decl_zig_name_map.key?(proxy.object_id)
        @decl_zig_name_map[node.object_id] = @decl_zig_name_map[proxy.object_id]
      end
      result
    else
      # Atomic compound assignments must emit cell methods; the desugared
      # load+store form would race.
      if node.auto_atomic_op
        return lower_atomic_assignment(node)
      end

      safe = zig_safe_name(node.name)
      # Resolve through the line-suffix rename map so reassignments (e.g.
      # kResult = resolveTco(...)) and their cleanup guards reference the
      # same Zig variable that the earlier decl created.
      safe = @fn_name_rename_map[safe] if @fn_name_rename_map&.key?(safe)
      # Consult @do_capture_map so a reassignment to a captured /
      # promoted local rewrites the LHS to the appropriate ctx-field
      # reference.
      mapped = @do_capture_map && @do_capture_map[node.name]
      rp = node.reassign_cleanup
      # The new value's allocating expression inherits the reassigned
      # binding's allocator (one allocator per binding).
      binding_entry = @current_bindings[node.name.to_s] || CleanupEntry::NONE
      @current_fn_heap_carry_return_vars = T.let(@current_fn_heap_carry_return_vars, T.untyped)
      heap_return_var = @current_fn_heap_carry_return_vars&.include?(node.name.to_s)
      assign_alloc = if heap_return_var
        :heap
      else
        rp ? alloc_from_sym(rp.alloc!) : (binding_entry.present? ? binding_entry.alloc : nil)
      end
      value = with_decl_alloc(assign_alloc) do
        lowered = lower(node.value)
        place_value_for_destination(lowered, node.value, assign_alloc, node.full_type)
      end
      value = copy_container_borrow_if_needed(value, node.value)
      value = hoist_alloc(value, node.value, err_cleanup: true) if value && mir_allocates?(value)
      result = if rp
        MIR::ReassignWithCleanup.new(mapped || safe, value, rp.zig_type!, alloc_from_sym(rp.alloc!))
      elsif heap_return_var && (target_type = Type.from_node(node.name))&.needs_explicit_cleanup?(:heap, @schema_lookup)
        MIR::ReassignWithCleanup.new(mapped || safe, value, transpile_type(target_type), :heap)
      else
        MIR::Set.new(MIR::Ident.new(mapped || safe), value)
      end
      result
    end
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
    # mir-lowering strict ivars
    @current_fn_mutable_scalar_params = T.let(@current_fn_mutable_scalar_params, T.untyped)
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    op_name = node.auto_atomic_op.to_s
    target_name = node.name.is_a?(String) ? node.name : node.name.name
    safe = zig_safe_name(target_name)
    safe = @fn_name_rename_map[safe] if @fn_name_rename_map&.key?(safe)
    # A bare write to a mutable scalar atomic param may not create the usual
    # shadow variable, so resolve through param mangling explicitly.
    if @current_fn_mutable_scalar_params&.include?(target_name)
      safe = "_m_#{target_name}"
    end
    mapped = @do_capture_map && @do_capture_map[target_name]
    target_ident = MIR::Ident.new(mapped || safe)
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

  sig { params(node: AST::Assignment).returns(T.untyped) }
  def lower_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    @schema_lookup = T.let(@schema_lookup, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    # Indexed assignment: map[k]=v, list[i]=v
    if node.name.is_a?(AST::GetIndex)
      return lower_indexed_assignment(node)
    end

    # Auto-lock field assignment (handles its own pre-cleanup)
    if node.name.is_a?(AST::GetField) && node.auto_lock
      return lower_auto_lock_assignment(node)
    end

    # Field assignment with pre-cleanup (non-locked structs)
    if node.name.is_a?(AST::GetField) && node.field_pre_cleanup
      return lower_field_assignment_with_cleanup(node)
    end

    target = if node.name.is_a?(String)
      # Consult @do_capture_map so an assignment to a captured /
      # promoted local rewrites the LHS to the appropriate
      # ctx-field reference.
      mapped = @do_capture_map && @do_capture_map[node.name]
      MIR::Ident.new(mapped || zig_safe_name(node.name))
    else
      lower(node.name)
    end
    value = lower(node.value)
    value = copy_container_borrow_if_needed(value, node.value)
    result = MIR::Set.new(target, value)

    # Detect field assignments where old value needs cleanup but no pre-cleanup exists.
    if node.name.is_a?(AST::GetField) && !node.field_pre_cleanup
      field_ti = node.name.full_type
      sl = @schema_lookup
      if field_ti.needs_cleanup?(sl)
        result.needs_field_cleanup = true
      elsif field_ti.string?
        # String fields on heap-allocated structs need cleanup
        root = T.let(node.name.target, T.untyped)
        root = root.target while root.is_a?(AST::GetField)
        if root.is_a?(AST::Identifier)
          result.needs_field_cleanup = true if root.symbol&.heap_storage?
        end
      end
    end

    result
  end

  sig { params(value: T.untyped).returns(T::Array[MIR::Stmt]) }
  def ownership_marks_for_transferred_temp(value)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_bindings = T.let(@current_bindings, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    return [] unless value.is_a?(MIR::Ident)
    name = value.name.to_s
    entry = @current_bindings[name] || CleanupEntry::NONE
    guarded = !!(@guarded_cleanup_names && @guarded_cleanup_names[name])
    return [] unless guarded || entry.present?
    marks = T.let([MIR::TransferMark.new(name, :owned_sink)], T::Array[MIR::Stmt])
    marks << MIR::MoveMark.new(name) if guarded
    marks
  end

  sig { params(node: AST::Assignment).returns(T.untyped) }
  def lower_indexed_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @target = T.let(@target, T.untyped)
    target_node = node.name.target
    ti = target_node.full_type

    # Raw slice index (synthetic nodes from SOA rewrite have no type info:
    # full_type defaults to the :Untyped sentinel, never nil)
    return lower_direct_indexed_set(node, cast_index: false) if ti.untyped?

    # VM path: the bc_emitter has native MAP_PUT / NATIVE_CALL list-set!
    # dispatch on MIR::Set(IndexGet, val); avoid the Zig-templated InlineZig
    # that the Zig backend needs.
    return lower_direct_indexed_set(node, cast_index: false) if @target == :bc

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
    op = kind && INDEX_OPS.dig(kind, :set)

    target = lower(target_node)
    idx = lower(node.name.index)

    # Fallback for unknown container types or missing registry entries
    unless op
      val = lower(node.value)
      return MIR::ExprStmt.new(emit_builtin(:setAt, [target, idx, val]), false)
    end

    # HashMap (string/numeric, possibly sharded/striped/Arc-wrapped):
    # emit the structural MIR::ShardedMapPut. Both backends consume it
    # directly, so the checker has visibility into key dupe / value
    # transforms / shard-direct vs routed dispatch from the node fields.
    if kind == :string_map || kind == :numeric_map
      return lower_map_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
    end

    # Non-HashMap kinds (array, list, pool, set_collection) keep their
    # InlineZig template path below.
    target_var_for_bc = target_node.is_a?(AST::Identifier) ? target_node.name : nil
    if @target == :bc && op[:bc_op] &&
       !(@shard_context && target_var_for_bc == @shard_context[:map])
      val = lower(node.value)
      return MIR::ExprStmt.new(
        MIR::InlineBc.new(op[:bc_op], [target, idx, val], op), false)
    end

    lower_template_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
  end

  sig { params(node: AST::Assignment, cast_index: T::Boolean).returns(MIR::Set) }
  def lower_direct_indexed_set(node, cast_index:)
    T.bind(self, MIRLowering) rescue nil
    target = lower(node.name.target)
    idx = lower(node.name.index)
    idx = MIR::Cast.new(idx, "usize", :intCast) if cast_index
    val = lower(node.value)
    MIR::Set.new(MIR::IndexGet.new(target, idx), val)
  end

  sig do
    params(
      node: AST::Assignment,
      target_node: T.untyped,
      receiver_type: Type,
      target: T.untyped,
      idx: T.untyped,
      kind: Symbol,
      op: T.untyped
    ).returns(MIR::ShardedMapPut)
  end
  def lower_map_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
    T.bind(self, MIRLowering) rescue nil
    @shard_context = T.let(@shard_context, T.untyped)
    @target = T.let(@target, T.untyped)
    dispatch = indexed_assignment_dispatch(kind, receiver_type, target_node, node, op, include_val_alloc: false)
    val = with_decl_alloc(dispatch.sink_alloc) { lower(node.value) }

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
    val = materialize_owned_sink_value(val, node.value, dispatch.sink_alloc) unless dispatch.shard_direct
    val = hoist_alloc(val, node.value, err_cleanup: true)

    if @target != :bc && receiver_type.map? && (receiver_type.shared? || receiver_type.multiowned?)
      # Auto-deref Arc/Rc-wrapped containers (Zig-only -- BC has no
      # .ctrl.data wrapping and a single MapRef cell holds the data).
      target = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(target, "ctrl"), "data"))
    end
    if dispatch.shard_direct
      return MIR::ShardedMapPut.new(target, idx, val,
        MIR::Ident.new(@shard_context[:idx]),
        MIR::Ident.new(@shard_context[:key]),
        kind, op, dispatch.key_zig, dispatch.val_zig, dispatch.resolved_allocs, dispatch.template_kind)
    end
    MIR::ShardedMapPut.new(target, idx, val, nil, nil, kind, op, dispatch.key_zig, dispatch.val_zig, dispatch.resolved_allocs, dispatch.template_kind)
  end

  sig do
    params(
      node: AST::Assignment,
      target_node: T.untyped,
      receiver_type: Type,
      target: T.untyped,
      idx: T.untyped,
      kind: Symbol,
      op: T.untyped
    ).returns(T.untyped)
  end
  def lower_template_indexed_assignment(node, target_node, receiver_type, target, idx, kind, op)
    T.bind(self, MIRLowering) rescue nil
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    @shard_context = T.let(@shard_context, T.untyped)
    dispatch = indexed_assignment_dispatch(kind, receiver_type, target_node, node, op, include_val_alloc: true)

    val_node = node.value
    val = with_decl_alloc(dispatch.sink_alloc) { lower(node.value) }
    consumed_names = T.let([], T::Array[String])
    value_type_for_transfer = Type.from_node(val_node) rescue nil
    owns_transferred_value = ownership_tracked_transfer_type?(value_type_for_transfer || receiver_type.element_type)
    if op[:takes_value] && owns_transferred_value && !dispatch.shard_direct
      val = materialize_owned_sink_value(val, val_node, dispatch.sink_alloc)
      val = hoist_alloc(val, val_node, err_cleanup: true)
      if val.is_a?(MIR::Ident)
        consumed_names << val.name
        move_mark_field!(val_node)
      end
    end

    # Substitute non-allocator placeholders into the pattern
    target_zig = T.must(emit_expr(target))
    idx_zig = T.must(emit_expr(idx))
    val_zig = T.must(emit_expr(val))

    pattern = dispatch.template.dup
    pattern = pattern.gsub("{target}", target_zig)
    pattern = pattern.gsub("&{target}", "&#{target_zig}")
    pattern = pattern.gsub("{index}", idx_zig)
    pattern = pattern.gsub("{value}", val_zig)

    # Substitute shard-direct placeholders when inside SHARD body
    if @shard_context && pattern.include?("{shard_idx}")
      pattern = pattern.gsub("{shard_idx}", @shard_context[:idx])
      pattern = pattern.gsub("{shard_key}", @shard_context[:key])
    end

    # Resolve type placeholders from receiver (not allocators -- safe to inline)
    if pattern.include?("{key_zig}") || pattern.include?("{val_zig}")
      pattern = pattern.gsub("{key_zig}", receiver_type.key_type&.zig_type || "i64")
      pattern = pattern.gsub("{val_zig}", receiver_type.value_type&.zig_type || "f64")
    end

    iz = MIR::InlineZig.new(pattern, "index_set")
    iz.stdlib_def = op
    iz.allocs = dispatch.resolved_allocs unless dispatch.resolved_allocs.empty?
    iz.ownership_contract = MIR::OwnershipContract.consumes(consumed_names) if op[:takes_value]
    # Store target variable name for checker cross-reference with AllocMark.
    iz.target_var = extract_root_var_name(target_node)
    setAt_stmt = MIR::ExprStmt.new(iz, false)
    post_transfer_marks = consumed_names.flat_map do |name|
      marks = T.let([MIR::TransferMark.new(name, :owned_sink)], T::Array[MIR::Stmt])
      marks << MIR::MoveMark.new(name) if @guarded_cleanup_names&.[](name)
      marks
    end

    # Emit pre-cleanup for non-Copy element types in list collections so the
    # overwritten element is freed before the new value is written in place.
    if kind == :array || kind == :list
      elem_ti = receiver_type.element_type
      if elem_ti
        if ownership_tracked_transfer_type?(elem_ti)
          elem_zig = elem_ti.zig_type
          alloc_str = alloc_zig_str(dispatch.sink_alloc)
          cleanup_call = emit_builtin(:cleanupAt, [
            MIR::Ident.new(elem_zig),
            MIR::Ident.new(target_zig),
            MIR::Ident.new(alloc_str),
            MIR::Ident.new(idx_zig),
          ])
          return MIR::ScopeBlock.new([MIR::ExprStmt.new(cleanup_call, false), setAt_stmt, *post_transfer_marks])
        end
      end
    end

    return MIR::ScopeBlock.new([setAt_stmt, *post_transfer_marks]) if post_transfer_marks.any?

    setAt_stmt
  end

  sig do
    params(
      kind: Symbol,
      receiver_type: Type,
      target_node: T.untyped,
      assignment: AST::Assignment,
      op: T.untyped,
      include_val_alloc: T::Boolean
    ).returns(IndexedAssignmentDispatch)
  end
  def indexed_assignment_dispatch(kind, receiver_type, target_node, assignment, op, include_val_alloc:)
    target_var = indexed_assignment_target_var(target_node)
    shard_direct = !!(@shard_context && target_var == @shard_context[:map] && op[:shard_direct_zig])
    template_kind = if shard_direct
      :shard_direct_zig
    elsif (receiver_type.sharded? || receiver_type.striped?) && op[:sharded_zig]
      :sharded_zig
    else
      :zig
    end
    template = op[template_kind].to_s
    resolved_allocs = indexed_assignment_allocs(template, op, target_node, assignment, include_val_alloc: include_val_alloc)
    IndexedAssignmentDispatch.new(
      target_var: target_var,
      shard_direct: shard_direct,
      template_kind: template_kind,
      template: template,
      key_zig: (kind == :numeric_map ? receiver_type.key_type&.zig_type : nil),
      val_zig: (kind == :numeric_map ? receiver_type.value_type&.zig_type : nil),
      resolved_allocs: resolved_allocs,
      sink_alloc: resolved_allocs[:val_alloc] || resolved_allocs[:alloc] || resolved_allocs[:shard_alloc] || :heap
    )
  end

  sig { params(target_node: T.untyped).returns(T.nilable(String)) }
  def indexed_assignment_target_var(target_node)
    target_node.is_a?(AST::Identifier) ? target_node.name.to_s : nil
  end

  sig do
    params(
      template: String,
      op: T.untyped,
      target_node: T.untyped,
      assignment: AST::Assignment,
      include_val_alloc: T::Boolean
    ).returns(T::Hash[Symbol, Symbol])
  end
  def indexed_assignment_allocs(template, op, target_node, assignment, include_val_alloc:)
    T.bind(self, MIRLowering) rescue nil
    resolved_allocs = T.let({}, T::Hash[Symbol, Symbol])
    [:alloc, :key_alloc, :val_alloc, :shard_alloc].each do |alloc_key|
      placeholder = "{#{alloc_key}}"
      next unless template.include?(placeholder) || (include_val_alloc && alloc_key == :val_alloc)
      alloc_sym = op[alloc_key] || :heap
      next if alloc_key == :val_alloc && op[alloc_key].nil? && include_val_alloc
      resolved_allocs[alloc_key] = resolve_alloc_sym(alloc_sym, target_node, assignment)
    end
    resolved_allocs
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
      place_value_for_destination(lowered, node.value, alloc_sym, node.name.full_type)
    end
    value = materialize_owned_sink_value(value, node.value, alloc_sym)
    alloc = MIR::Ident.new(alloc_zig_str(alloc_sym))
    field_get = MIR::FieldGet.new(target, field)
    # Build a comptime @TypeOf(target.field) expression. The field name
    # is known statically; comptime resolves the type from the binding's
    # actual shape.
    type_expr = MIR::Ident.new("@TypeOf(#{MIREmitter.new.emit(field_get)})")
    cleanup_call = MIR::Call.new("CheatLib.cleanup", [
      type_expr, alloc, MIR::AddressOf.new(field_get)
    ], false, false, MIR::CallableContract.no_ownership(3))
    assign = MIR::Set.new(field_get, value)
    MIR::ScopeBlock.new(append_ownership_transfers_for_mir_body([MIR::ExprStmt.new(cleanup_call, false), assign]))
  end

  sig { params(node: AST::Assignment).returns(T.untyped) }
  def lower_auto_lock_assignment(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    @locked_unwrap_map = T.let(@locked_unwrap_map, T.untyped)
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
          MIR::Set.new(get_field, value),
        ], T::Array[T.untyped])
        stmts << len_guard.call("__old", facts.cleanup_alloc)
        return MIR::ScopeBlock.new(append_ownership_transfers_for_mir_body(stmts))
      else
        set = MIR::Set.new(get_field, value)
        return set
      end
    end

    acquire_method = SymbolEntry.write_locked_sync?(facts.sync) ? "write" : "acquire"
    prev_locked = @locked_unwrap_map
    @locked_unwrap_map = (prev_locked || {}).merge({ facts.alias_var => true, facts.var_name => facts.alias_var })
    value = auto_lock_assignment_value(node, facts.alloc_sym)
    value_pending = flush_pending
    @locked_unwrap_map = prev_locked
    alias_field = MIR::FieldGet.new(MIR::Ident.new(facts.alias_var), facts.field)
    stmts = T.let([
      MIR::Let.new(facts.guard_var, MIR::MethodCall.new(MIR::Ident.new(facts.zig_var), acquire_method, [], false,
        MIR::CallableContract.no_ownership(0)), true, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new(facts.guard_var), "release", [], false,
        MIR::CallableContract.no_ownership(0))),
      MIR::Let.new(facts.alias_var, MIR::MethodCall.new(MIR::Ident.new(facts.guard_var), "get", [], false,
        MIR::CallableContract.no_ownership(0)), false, nil, nil),
      *value_pending,
    ], T::Array[T.untyped])
    if facts.cleanup_alloc
      stmts << MIR::Let.new("__old", alias_field, false, nil, nil)
      stmts << MIR::Set.new(alias_field, value)
      stmts << len_guard.call("__old", facts.cleanup_alloc)
    else
      stmts << MIR::Set.new(alias_field, value)
    end
    MIR::ScopeBlock.new(append_ownership_transfers_for_mir_body(stmts))
  end

  sig { params(node: AST::Assignment).returns(AutoLockAssignmentFacts) }
  def auto_lock_assignment_facts(node)
    T.bind(self, MIRLowering) rescue nil
    var_name = node.auto_lock[:var].to_s
    cleanup_alloc = T.let(node.field_pre_cleanup, T.nilable(Symbol))
    AutoLockAssignmentFacts.new(
      var_name: var_name,
      sync: node.auto_lock[:sync],
      guard_var: "__#{var_name}_guard",
      alias_var: "__#{var_name}_inner",
      zig_var: (@do_capture_map&.dig(var_name) || var_name).to_s,
      field: node.name.field.to_s,
      cleanup_alloc: cleanup_alloc,
      alloc_sym: cleanup_alloc || placement_for_node(root_receiver_node(node.name) || node.name)
    )
  end

  sig { params(node: AST::Assignment, alloc_sym: Symbol).returns(T.untyped) }
  def auto_lock_assignment_value(node, alloc_sym)
    T.bind(self, MIRLowering) rescue nil
    value = with_decl_alloc(alloc_sym) do
      lowered = lower(node.value)
      placed = place_value_for_destination(lowered, node.value, alloc_sym, node.name.full_type)
      materialize_owned_sink_value(placed, node.value, alloc_sym, node.name.full_type)
    end
    value && mir_allocates?(value) ? hoist_alloc(value, node.value, err_cleanup: true) : value
  end

  # ================================================================
  # Control flow
  # ================================================================


end
