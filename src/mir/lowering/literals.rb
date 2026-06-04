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
      type_info.fixed? && node.stack_or_frame_storage?
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
    const :alloc_zig, String
    const :zig_type, String
    const :arc_wrapped, T::Boolean
    const :rc_wrapped, T::Boolean

    sig { returns(T::Boolean) }
    def capability_wrapped?
      arc_wrapped || rc_wrapped
    end
  end

  sig { params(node: AST::ListLit).returns(T.untyped) }
  def lower_list_lit(node)
    T.bind(self, MIRLowering) rescue nil
    @current_expected_type = T.let(@current_expected_type, T.nilable(Type))
    @current_decl_alloc = T.let(@current_decl_alloc, T.nilable(Symbol))

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
      if lowering_target == :bc
        items_mir_bc = node.items.map { |i| lower(i) }
        return MIR::MakeList.new("__bc_stream__", items_mir_bc, :frame)
      end

      s_id = next_stream_literal_id

      elem_zig = ti.stream_element_type.zig_type
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
        lowered_item = elem_type ? with_expected_type(elem_type) { lower(i) } : lower(i)
        placed_item = elem_type ? place_value_for_destination(lowered_item, i, list_alloc, elem_type) : lowered_item
        item_value = materialize_owned_sink_value(placed_item, i, list_alloc, elem_type)
        item_alloc = mir_owned_alloc(item_value)
        item = hoist_alloc(item_value, i, err_cleanup: true)
        if plan.element_needs_owned_storage && !ast_expr_produces_heap?(i) && item_alloc != list_alloc
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
        zig_t = transpile_type(ti)
        return MIR::ContainerInit.new(zig_t, :list_empty, list_alloc, nil)
      end
      # Dynamic empty list: use makeList with empty items
      return MIR::MakeList.new(elem_zig, [], list_alloc)
    end

    # Non-empty list literal -> makeList
    T.cast(
      with_ownership_consumption(
        MIR::MakeList.new(elem_zig, items_mir, list_alloc),
        items_mir.flat_map { |item| mir_ident_names(item) },
        "MIR::MakeList",
        target_alloc: list_alloc,
      ),
      MIR::MakeList,
    )
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
    MIR::ArrayDefaultInit.new(elem_zig, count.to_s, default_array_value(elem_type), @current_decl_alloc || alloc_for_node(node), type_info)
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

  sig { params(node: AST::HashLit).returns(T.untyped) }
  def lower_hash_lit(node)
    T.bind(self, MIRLowering) rescue nil
    @current_decl_alloc = T.let(@current_decl_alloc, T.nilable(Symbol))

    plan = hash_literal_plan(node)
    ti = plan.type_info
    rt_name = runtime_binding_name
    map_alloc = plan.alloc
    alloc_str = plan.alloc_zig
    init_value = T.let(nil, T.untyped)
    result_wrap = T.let(nil, T.nilable(Symbol))
    result_wrap_fn = T.let(nil, T.nilable(String))

    # For Arc/Rc-wrapped maps, build bare inner type for init, then wrap
    if plan.capability_wrapped?
      # Sharded maps have their sync mode built into the Zig type
      # (e.g. MutexShardedStringMap), so they need the legacy direct-
      # composition path that preserves shard_count + sync on bare_ft.
      # Plain (non-sharded) maps go through compose_capability_wrap for
      # the unified Group 1 / Group 2 separation.
      if ti.striped?
        bare_ft = Type.new(ti.resolved.to_s)
        bare_ft.copy_striped_map_topology_from!(ti)
        zig_t = bare_ft.zig_type

        needs_alloc = bare_ft.map_init_needs_alloc?
        inner = MIR::StructInit.new(zig_t, needs_alloc ? [{ name: "alloc", value: MIR::Ident.new(alloc_str) }] : [])

        wrap_fn = plan.arc_wrapped ? "arcCreate" : "rcCreate"
        inner = T.cast(
          with_ownership_consumption(
            MIR::CapWrap.new(inner, zig_t, :own_only, nil, nil, wrap_fn, :heap),
            mir_ident_names(inner),
            "MIR::CapWrap",
            target_alloc: :heap,
          ),
          MIR::CapWrap,
        )
        return inner if node.pairs.empty?
        init_value = MIR::StructInit.new(zig_t, needs_alloc ? [{ name: "alloc", value: MIR::Ident.new(alloc_str) }] : [])
        result_wrap = :striped
        result_wrap_fn = wrap_fn
      else
        bare_ft = ti.bare_data_type
        zig_t = bare_ft.zig_type

        needs_alloc = bare_ft.map_init_needs_alloc?
        inner = if needs_alloc
          MIR::StructInit.new(zig_t, [{ name: "alloc", value: MIR::Ident.new(alloc_str) }])
        else
          MIR::StructInit.new(zig_t, [])
        end

        wrapped = compose_capability_wrap(inner, zig_t, ti, :heap)
        return wrapped if node.pairs.empty?
        init_value = inner
        result_wrap = :composed
      end
    end

    zig_t = plan.zig_type
    zig_t = init_value.zig_type if init_value.is_a?(MIR::StructInit)

    if node.pairs.empty?
      # PartitionedStringMap, PartitionedNumericMap, and NumericMapType don't have an .alloc field
      needs_alloc = !zig_t.include?("PartitionedStringMap") && !zig_t.include?("PartitionedNumericMap") && !zig_t.include?("NumericMapType")
      strategy = needs_alloc ? :map_bare : :map_empty
      return MIR::ContainerInit.new(zig_t, strategy, map_alloc, nil)
    end

    # Non-empty hash: init + puts
    items = []
    alloc_expr = MIR::MethodCall.new(MIR::Ident.new(rt_name), map_alloc == :heap ? "heapAlloc" : "frameAlloc", [], false, MIR::CallableContract.no_ownership(0))
    items << MIR::Let.new("__hm", init_value || MIR::StructInit.new(zig_t, [{ name: "alloc", value: alloc_expr }]), true, nil, nil)
    node.pairs.each do |key_node, val_node|
      k = lower(key_node)
      raw_v = with_decl_alloc(map_alloc) { materialize_owned_sink_value(lower(val_node), val_node, map_alloc) }
      v = hoist_alloc(raw_v, val_node, err_cleanup: true)
      operands = ownership_operands_for_value(k, key_node, "hash literal key", map_alloc) +
        ownership_operands_for_value(v, val_node, "hash literal value", map_alloc)
      base_contract = MIR::CallableContract.no_ownership(4)
      put_contract = MIR::CallableContract.new(
        base_contract.signature,
        MIR::OwnershipContract.consume_operands(operands),
        4,
      )
      put_call = MIR::MethodCall.new(MIR::Ident.new("__hm"), "put", [alloc_expr, alloc_expr, k, v], true, put_contract)
      items << MIR::ExprStmt.new(put_call, false)
    end
    result = T.let(MIR::Ident.new("__hm"), T.untyped)
    if result_wrap == :striped
      result = MIR::CapWrap.new(result, zig_t, :own_only, nil, nil, T.must(result_wrap_fn), :heap)
    elsif result_wrap == :composed
      result = compose_capability_wrap(result, zig_t, ti, :heap)
    end
    if result_wrap
      items << MIR::Let.new("__hm_wrapped", result, false, Type.new(ti), nil)
      result = MIR::Ident.new("__hm_wrapped")
    end
    items << MIR::BreakStmt.new("__hm_blk", result)
    block = MIR::BlockExpr.new("__hm_blk", items)
    block.result_type = Type.new(ti)
    block
  end

  sig { params(node: AST::ListLit).returns(ListLiteralPlan) }
  def list_literal_plan(node)
    T.bind(self, MIRLowering) rescue nil
    expected_ti = Type.from_node(@current_expected_type)
    ti = if expected_ti&.collection?
      expected_ti
    else
      node.coerced_type_info || node.full_type!
    end
    type_info = Type.new(ti)
    elem_type = type_info.element_type
    elem_ti = elem_type ? Type.new(elem_type) : nil
    ListLiteralPlan.new(
      type_info: type_info,
      alloc: @current_decl_alloc || alloc_for_node(node),
      element_type: elem_ti,
      element_zig: elem_ti ? transpile_type(elem_ti) : "u8",
      element_needs_owned_storage: elem_ti ? elem_ti.recursive_cleanup_shape?(mir_schema_lookup) : false,
    )
  end

  sig { params(node: AST::HashLit).returns(HashLiteralPlan) }
  def hash_literal_plan(node)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.new(node.coerced_type_info || node.full_type!)
    map_alloc = @current_decl_alloc || alloc_for_node(node)
    rt_name = runtime_binding_name
    HashLiteralPlan.new(
      type_info: ti,
      alloc: map_alloc,
      alloc_zig: "#{rt_name}.#{map_alloc == :heap ? "heapAlloc" : "frameAlloc"}()",
      zig_type: transpile_type(ti),
      arc_wrapped: ti.shared?,
      rc_wrapped: ti.multiowned?,
    )
  end
end
