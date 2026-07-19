# typed: strict
require "sorbet-runtime"

module MIRLoweringLiterals
  extend T::Sig
  extend T::Helpers

  requires_ancestor { MIRLowering }

  class ListLiteralPlan < T::Struct
    extend T::Sig

    const :type_info, Type
    const :alloc, Symbol
    const :element_type, T.nilable(Type)
    const :element_zig, String
    const :element_needs_owned_storage, T::Boolean

    sig { returns(T::Boolean) }
    def bounded_stream?
      type_info.bounded_stream?
    end

    sig { params(node: AST::ListLit).returns(T::Boolean) }
    def fixed_stack_or_frame?(node)
      (type_info.fixed? && node.stack_or_frame_storage?) == true
    end

    sig { returns(T::Boolean) }
    def list_collection?
      type_info.list_collection?
    end
  end

  class HashLiteralPlan < T::Struct
    extend T::Sig

    const :type_info, Type
    const :alloc, Symbol
    const :zig_type, String
    const :arc_wrapped, T::Boolean
    const :rc_wrapped, T::Boolean

    sig { returns(T::Boolean) }
    def capability_wrapped?
      arc_wrapped || rc_wrapped
    end

    sig { returns(String) }
    def allocator_method
      MIR::Placement.explicit_heap?(alloc) ? "heapAlloc" : "frameAlloc"
    end
  end

  class HashLiteralCapabilityPlan < T::Struct
    extend T::Sig

    const :zig_type, String
    const :init_value, T.nilable(MIR::StructInit)
    const :empty_result, T.nilable(MIR::Emittable)
    const :result_wrap, T.nilable(Symbol)
    const :result_wrap_fn, T.nilable(String)

    sig { returns(T::Boolean) }
    def wraps_result?
      !result_wrap.nil?
    end

    sig { returns(T::Boolean) }
    def striped_result?
      result_wrap == :striped
    end

    sig { returns(T::Boolean) }
    def composed_result?
      result_wrap == :composed
    end
  end

  sig { params(node: AST::ListLit).returns(MIR::Node) }
  def lower_list_lit(node)
    T.bind(self, MIRLowering) rescue nil
    function_state.current_expected_type = T.let(function_state.current_expected_type, T.nilable(Type))
    function_state.current_decl_alloc = T.let(function_state.current_decl_alloc, T.nilable(Symbol))

    tuple_type = Type.new(node.coerced_type_info || node.full_type!)
    if tuple_type.tuple?
      return lower_tuple_items(node.items, tuple_type)
    end

    plan = list_literal_plan(node)
    ti = plan.type_info

    # Bounded stream: ~T[N] - emit BoundedStream struct with Promise items
    if plan.bounded_stream?
      # BC backend: there's no Promise/BoundedStream runtime; with the
      # synchronous BG_SPAWN the items are already concrete values, so
      # treat the literal as a plain list. NEXT on the bound slot pops
      # the head via LIST_POP_FRONT (same as BG STREAM materialization).
      # The "__bc_stream__" sentinel elem_type lets the emitter mark
      # the binding's slot as a stream so NEXT routes via LIST_POP_FRONT.
      if bc_target?
        items_mir_bc = node.items.map { |i| lower(i) }
        return MIR::MakeList.new("__bc_stream__", items_mir_bc, :frame)
      end

      s_id = next_stream_literal_id

      elem_zig = T.must(ti.stream_element_type).zig_type
      n = ti.stream_capacity
      promise_zig = "CheatLib.Promise(#{elem_zig})"
      stream_zig = ti.zig_type

      label = "__stream#{s_id}"
      body = T.let([], T::Array[T.untyped])
      item_idents = node.items.each_with_index.map do |item, i|
        item_mir, pending = lower_head { lower(item) }
        body.concat(pending)
        item_name = "__stream#{s_id}_item#{i}"
        body << MIR::Let.new(item_name, item_mir, false, nil, nil)
        MIR::Ident.new(item_name)
      end
      stream_value = MIR::StructInit.new(stream_zig, [
        { name: "items", value: MIR::ArrayInit.new(promise_zig, n.to_s, item_idents) }
      ])
      stream_value = with_ownership_consumption(
        stream_value,
        item_idents.flat_map { |item| mir_ident_names(item) },
        "MIR::BoundedStream",
        target_alloc: :heap,
        require_visible: false,
      )
      body << MIR::BreakStmt.new(label, stream_value)
      block = MIR::BlockExpr.new(label, body)
      block.result_type = Type.new(ti)
      return block
    end

    list_alloc = plan.alloc
    elem_type = plan.element_type
    elem_zig = plan.element_zig
    items_mir = node.items.map do |i|
      with_decl_alloc(list_alloc) do
        if plan.fixed_stack_or_frame?(node) && i.is_a?(AST::Literal) && [:STRING, :SYMBOL].include?(i.type)
          next lower(i)
        end
        lowered_item = elem_type ? with_expected_type(elem_type) { lower(i) } : lower(i)
        placed_item = elem_type ? place_value_for_destination(lowered_item, i, list_alloc, elem_type) : lowered_item
        item_value = materialize_owned_sink_value(placed_item, i, list_alloc, elem_type)
        item_alloc = mir_owned_alloc(item_value) ||
          (ast_expr_produces_heap?(i) ? :heap : placement_for_node(i))
        needs_allocator_transport = plan.element_needs_owned_storage && item_alloc && item_alloc != list_alloc
        # A matching child is transferred into the aggregate, so it needs only
        # error cleanup before that transfer. A mismatched child is merely read
        # by DeepCopy and must retain ordinary local cleanup for its source.
        item = hoist_alloc(item_value, i, err_cleanup: !needs_allocator_transport)
        if needs_allocator_transport
          hoist_alloc(MIR::DeepCopy.new(item, elem_zig, nil, :full_value, list_alloc), i, err_cleanup: true)
        else
          item
        end
      end
    end

    if plan.fixed_stack_or_frame?(node)
      # Raw fixed-size array (`T[N] = [...]`). Always lowers to a Zig
      # `[N]T{...}` literal regardless of CLEAR's storage classification:
      # the size > 128 slot threshold in finalize_storage promotes large
      # fixed-array literals to :frame, but for raw fixed-size arrays
      # there is no separate frame allocation -- the array data lives in
      # the function's own stack/frame either way, and Zig handles multi-
      # KB fixed arrays fine. Falling through to MakeList here would
      # produce an ArrayList whose Zig type doesn't match the variable's
      # declared `[N]T`, so the assignment fails to compile.
      return T.cast(
        with_ownership_consumption(
          MIR::ArrayInit.new(elem_zig, node.items.length.to_s, items_mir),
          items_mir.flat_map { |item| mir_ident_names(item) },
          "MIR::ArrayInit",
          target_alloc: list_alloc,
        ),
        MIR::ArrayInit,
      )
    end

    if node.items.empty?
      # Empty list: MIR expression depends on collection type
      if plan.list_collection?
        inner_ti = list_literal_capability_wrap_needed?(ti) ? ti.bare_data_type : ti
        inner = MIR::ContainerInit.new(transpile_type(inner_ti), :array_list_empty, list_alloc, nil)
        return wrap_list_literal_capability(inner, ti, list_alloc)
      end
      # Dynamic empty list: use makeList with empty items
      return wrap_list_literal_capability(MIR::MakeList.new(elem_zig, [], list_alloc), ti, list_alloc)
    end

    # Non-empty list literal -> makeList
    inner = T.cast(
      with_ownership_consumption(
        MIR::MakeList.new(elem_zig, items_mir, list_alloc, ti.allocation_hint),
        items_mir.flat_map { |item| mir_ident_names(item) },
        "MIR::MakeList",
        target_alloc: list_alloc,
      ),
      MIR::MakeList,
    )
    wrap_list_literal_capability(inner, ti, list_alloc)
  end

  sig { params(node: AST::TupleLit).returns(MIR::TupleLiteral) }
  def lower_tuple_lit(node)
    T.bind(self, MIRLowering) rescue nil
    # Contextual tuple typing may refine untyped constructors such as List[]
    # in an individual field.  Use that destination tuple, not the literal's
    # pre-coercion Tuple<Any[],...> inference, when lowering child elements.
    tuple_type = Type.new(node.coerced_type_info || node.full_type!(context: "tuple literal lowering"))
    lower_tuple_items(node.items, tuple_type)
  end

  sig { params(items: T::Array[AST::Node], tuple_type: Type).returns(MIR::TupleLiteral) }
  def lower_tuple_items(items, tuple_type)
    T.bind(self, MIRLowering) rescue nil
    alloc = function_state.current_decl_or_frame_alloc
    lowered = items.each_with_index.map do |item, index|
      expected_item = T.must(tuple_type.generic_args[index])
      with_decl_alloc(alloc) do
        value = with_expected_type(expected_item) { lower(item) }
        placed = place_value_for_destination(value, item, alloc, expected_item)
        owned = materialize_owned_sink_value(placed, item, alloc, expected_item)
        hoist_alloc(owned, item, err_cleanup: true)
      end
    end
    tuple = MIR::TupleLiteral.new(lowered)
    T.cast(
      with_ownership_consumption(
        tuple,
        lowered.flat_map { |item| mir_ident_names(item) },
        "MIR::TupleLiteral",
        target_alloc: alloc,
      ),
      MIR::TupleLiteral,
    )
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def list_literal_capability_wrap_needed?(ti)
    return false if ti.striped?
    ti.any_sync? || ti.shared? || ti.multiowned?
  end

  sig { params(inner: MIR::Emittable, ti: Type, alloc: Symbol).returns(MIR::Emittable) }
  def wrap_list_literal_capability(inner, ti, alloc)
    T.bind(self, MIRLowering)
    return inner unless list_literal_capability_wrap_needed?(ti)
    compose_capability_wrap(inner, ti.bare_data_type.zig_type, ti, alloc)
  end

  sig { params(node: AST::DefaultArrayLit).returns(MIR::ArrayDefaultInit) }
  def lower_default_array_lit(node)
    T.bind(self, MIRLowering) rescue nil
    type_info = node.full_type!(context: "default fixed-array literal")
    elem_type = T.must(type_info.element_type)
    elem_zig = transpile_type(elem_type)
    count = type_info.capacity
    unless count.is_a?(Integer)
      Kernel.raise "default fixed-array literal requires an integer capacity"
    end
    # A raw `[N]T` value is inline storage in Zig even when escape analysis
    # places the surrounding function frame on the heap. It never performs a
    # separate heap allocation and must not acquire heap AllocMark semantics.
    MIR::ArrayDefaultInit.new(elem_zig, count.to_s, default_array_value(elem_type), :frame, type_info)
  end

  sig { params(elem_type: Type).returns(MIR::Lit) }
  def default_array_value(elem_type)
    case elem_type.resolved
    when :Int64, :Int32, :Int16, :Int8 then MIR::Lit.new("0")
    when :Float64, :Float32 then MIR::Lit.new("0.0")
    when :String then MIR::Lit.new("\"\"")
    when :Bool, :Boolean then MIR::Lit.new("false")
    else
      Kernel.raise "unsupported fixed-array default element type #{elem_type.resolved.inspect}"
    end
  end

  sig { params(node: AST::HashLit).returns(MIR::Emittable) }
  def lower_hash_lit(node)
    T.bind(self, MIRLowering) rescue nil

    plan = hash_literal_plan(node)
    capability = hash_literal_capability_plan(plan)

    if node.pairs.empty?
      return T.must(capability.empty_result) if capability.empty_result

      return empty_hash_literal(plan, capability.zig_type)
    end

    non_empty_hash_literal(node, plan, capability)
  end

  sig { params(plan: HashLiteralPlan).returns(HashLiteralCapabilityPlan) }
  def hash_literal_capability_plan(plan)
    T.bind(self, MIRLowering) rescue nil
    return unwrapped_hash_literal_capability_plan(plan) unless plan.capability_wrapped?

    if plan.type_info.striped?
      striped_hash_literal_capability_plan(plan)
    else
      composed_hash_literal_capability_plan(plan)
    end
  end

  sig { params(plan: HashLiteralPlan).returns(HashLiteralCapabilityPlan) }
  def unwrapped_hash_literal_capability_plan(plan)
    HashLiteralCapabilityPlan.new(
      zig_type: plan.zig_type,
      init_value: nil,
      empty_result: nil,
      result_wrap: nil,
      result_wrap_fn: nil,
    )
  end

  sig { params(plan: HashLiteralPlan).returns(HashLiteralCapabilityPlan) }
  def striped_hash_literal_capability_plan(plan)
    T.bind(self, MIRLowering) rescue nil
    bare_type = Type.new(plan.type_info.resolved.to_s)
    bare_type.copy_striped_map_topology_from!(plan.type_info)
    zig_type = bare_type.zig_type
    init_value = hash_literal_init_struct(zig_type, plan.alloc, bare_type.map_init_needs_alloc?)
    wrap_fn = plan.arc_wrapped ? "arcCreate" : "rcCreate"
    empty_result = T.cast(
      with_ownership_consumption(
        MIR::CapWrap.new(init_value, zig_type, :own_only, nil, nil, wrap_fn, :heap),
        mir_ident_names(init_value),
        "MIR::CapWrap",
        target_alloc: :heap,
      ),
      MIR::CapWrap,
    )
    HashLiteralCapabilityPlan.new(
      zig_type: zig_type,
      init_value: hash_literal_init_struct(zig_type, plan.alloc, bare_type.map_init_needs_alloc?),
      empty_result: empty_result,
      result_wrap: :striped,
      result_wrap_fn: wrap_fn,
    )
  end

  sig { params(plan: HashLiteralPlan).returns(HashLiteralCapabilityPlan) }
  def composed_hash_literal_capability_plan(plan)
    T.bind(self, MIRLowering) rescue nil
    bare_type = plan.type_info.bare_data_type
    zig_type = bare_type.zig_type
    init_value = hash_literal_init_struct(zig_type, plan.alloc, bare_type.map_init_needs_alloc?)
    HashLiteralCapabilityPlan.new(
      zig_type: zig_type,
      init_value: init_value,
      empty_result: compose_capability_wrap(init_value, zig_type, plan.type_info, :heap),
      result_wrap: :composed,
      result_wrap_fn: nil,
    )
  end

  sig { params(zig_type: String, alloc: Symbol, needs_alloc: T::Boolean).returns(MIR::StructInit) }
  def hash_literal_init_struct(zig_type, alloc, needs_alloc)
    fields = needs_alloc ? [MIR.named_field("alloc", MIR::AllocatorRef.new(alloc))] : []
    MIR::StructInit.new(zig_type, fields)
  end

  sig { params(plan: HashLiteralPlan, zig_type: String).returns(MIR::ContainerInit) }
  def empty_hash_literal(plan, zig_type)
    # PartitionedStringMap, PartitionedNumericMap, and NumericMapType do not
    # expose an allocator field.
    strategy = hash_literal_empty_needs_alloc?(zig_type) ? :map_bare : :map_empty
    MIR::ContainerInit.new(zig_type, strategy, plan.alloc, nil)
  end

  sig { params(zig_type: String).returns(T::Boolean) }
  def hash_literal_empty_needs_alloc?(zig_type)
    !zig_type.include?("PartitionedStringMap") &&
      !zig_type.include?("PartitionedNumericMap") &&
      !zig_type.include?("NumericMapType")
  end

  sig { params(node: AST::HashLit, plan: HashLiteralPlan, capability: HashLiteralCapabilityPlan).returns(MIR::BlockExpr) }
  def non_empty_hash_literal(node, plan, capability)
    T.bind(self, MIRLowering) rescue nil
    items = T.let([], T::Array[MIR::Stmt])
    alloc_expr = hash_literal_allocator_expr(plan)
    items << MIR::Let.new("__hm", capability.init_value || hash_literal_init_struct(capability.zig_type, plan.alloc, true), true, nil, nil)
    node.pairs.each do |key_node, val_node|
      items << hash_literal_put_stmt(key_node, val_node, plan, alloc_expr)
    end
    result = hash_literal_result(MIR::Ident.new("__hm"), plan, capability)
    if capability.wraps_result?
      items << MIR::Let.new("__hm_wrapped", result, false, Type.new(plan.type_info), nil)
      result = MIR::Ident.new("__hm_wrapped")
    end
    items << MIR::BreakStmt.new("__hm_blk", result)
    block = MIR::BlockExpr.new("__hm_blk", items)
    block.result_type = Type.new(plan.type_info)
    block
  end

  sig { params(plan: HashLiteralPlan).returns(MIR::MethodCall) }
  def hash_literal_allocator_expr(plan)
    T.bind(self, MIRLowering) rescue nil
    MIR::MethodCall.new(
      MIR::Ident.new(runtime_binding_name),
      plan.allocator_method,
      [],
      false,
      MIR::CallableContract.no_ownership(0),
    )
  end

  sig { params(key_node: AST::Node, val_node: AST::Node, plan: HashLiteralPlan, alloc_expr: MIR::MethodCall).returns(MIR::ExprStmt) }
  def hash_literal_put_stmt(key_node, val_node, plan, alloc_expr)
    T.bind(self, MIRLowering) rescue nil
    key_mir = lower(key_node)
    raw_value = with_decl_alloc(plan.alloc) do
      materialize_owned_sink_value(lower(val_node), val_node, plan.alloc)
    end
    value_mir = hoist_alloc(raw_value, val_node, err_cleanup: true)
    operands = ownership_operands_for_value(key_mir, key_node, "hash literal key", plan.alloc) +
      ownership_operands_for_value(value_mir, val_node, "hash literal value", plan.alloc)
    base_contract = MIR::CallableContract.no_ownership(4)
    put_contract = MIR::CallableContract.new(
      base_contract.signature,
      MIR::OwnershipContract.consume_operands(operands),
      4,
    )
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("__hm"), "put", [alloc_expr, alloc_expr, key_mir, value_mir], true, put_contract),
      false,
    )
  end

  sig { params(result: MIR::Emittable, plan: HashLiteralPlan, capability: HashLiteralCapabilityPlan).returns(MIR::Emittable) }
  def hash_literal_result(result, plan, capability)
    T.bind(self, MIRLowering) rescue nil
    return MIR::CapWrap.new(result, capability.zig_type, :own_only, nil, nil, T.must(capability.result_wrap_fn), :heap) if capability.striped_result?
    return compose_capability_wrap(result, capability.zig_type, plan.type_info, :heap) if capability.composed_result?

    result
  end

  sig { params(node: AST::ListLit).returns(ListLiteralPlan) }
  def list_literal_plan(node)
    T.bind(self, MIRLowering) rescue nil
    expected_ti = Type.from_node(function_state.current_expected_type)
    expected_owned_list = expected_ti&.collection? ||
      (expected_ti&.direct_indexable_collection? && expected_ti.dynamic? && !expected_ti.string?)
    ti = if expected_owned_list
      expected_ti
    else
      node.coerced_type_info || node.full_type!
    end
    type_info = Type.new(ti)
    elem_type = type_info.element_type
    elem_ti = elem_type ? Type.new(elem_type) : nil
    requested_alloc = function_state.current_decl_alloc || alloc_for_node(node)
    ListLiteralPlan.new(
      type_info: type_info,
      # The aggregate follows its destination. Individual owned children are
      # transported to this allocator while lowering the item list; promoting
      # the whole aggregate to match one child is later undone by declaration
      # hoisting and leaves an incoherent heap child inside a frame aggregate.
      alloc: requested_alloc,
      element_type: elem_ti,
      element_zig: elem_ti ? transpile_type(elem_ti) : "u8",
      element_needs_owned_storage: elem_ti ? elem_ti.recursive_cleanup_shape?(T.unsafe(mir_schema_lookup)) : false,
    )
  end

  sig { params(node: AST::HashLit).returns(HashLiteralPlan) }
  def hash_literal_plan(node)
    T.bind(self, MIRLowering) rescue nil
    expected_ti = Type.from_node(function_state.current_expected_type)
    ti = if expected_ti&.map?
      expected_ti
    else
      Type.new(node.coerced_type_info || node.full_type!)
    end
    map_alloc = function_state.current_decl_alloc || alloc_for_node(node)
    HashLiteralPlan.new(
      type_info: ti,
      alloc: map_alloc,
      zig_type: transpile_type(ti),
      arc_wrapped: ti.shared?,
      rc_wrapped: ti.multiowned?,
    )
  end
  private :composed_hash_literal_capability_plan
  private :default_array_value
  private :empty_hash_literal
  private :hash_literal_allocator_expr
  private :hash_literal_capability_plan
  private :hash_literal_empty_needs_alloc?
  private :hash_literal_plan
  private :hash_literal_put_stmt
  private :hash_literal_result
  private :list_literal_capability_wrap_needed?
  private :list_literal_plan
  private :non_empty_hash_literal
  private :striped_hash_literal_capability_plan
  private :unwrapped_hash_literal_capability_plan
  private :wrap_list_literal_capability

end
