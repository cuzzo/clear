# typed: strict
require "sorbet-runtime"

module MIRLoweringLiterals
  extend T::Sig
  extend T::Helpers

  requires_ancestor { MIRLowering }

  sig { params(node: AST::ListLit).returns(T.untyped) }
  def lower_list_lit(node)
    T.bind(self, MIRLowering) rescue nil
    @current_expected_type = T.let(@current_expected_type, T.untyped)
    @current_decl_alloc = T.let(@current_decl_alloc, T.nilable(Symbol))

    expected_ti = Type.from_node(@current_expected_type)
    ti = if expected_ti&.collection?
      expected_ti
    else
      node.coerced_type_info || node.full_type!
    end

    # Bounded stream: ~T[N] - emit BoundedStream struct with Promise items
    if ti.respond_to?(:bounded_stream?) && ti.bounded_stream?
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
      body << MIR::BreakStmt.new(label, stream_value)
      return MIR::BlockExpr.new(label, body)
    end

    list_alloc = @current_decl_alloc || alloc_for_node(node)
    elem_type = ti.element_type if ti.respond_to?(:element_type)
    elem_zig = elem_type ? transpile_type(elem_type) : "u8"
    elem_needs_owned_storage =
      if elem_type
        et = elem_type.is_a?(Type) ? elem_type : Type.new(elem_type)
        et.recursive_cleanup_shape?(mir_schema_lookup)
      else
        false
      end
    items_mir = node.items.map do |i|
      with_decl_alloc(list_alloc) do
        item_value = materialize_owned_sink_value(lower(i), i, list_alloc)
        item_alloc = mir_owned_alloc(item_value)
        item = hoist_alloc(item_value, i, err_cleanup: true)
        if elem_needs_owned_storage && !ast_expr_produces_heap?(i) && item_alloc != list_alloc
          hoist_alloc(MIR::DeepCopy.new(item, elem_zig, nil, :full_value, list_alloc), i, err_cleanup: true)
        else
          item
        end
      end
    end

    if ti.respond_to?(:fixed?) && ti.fixed? &&
       node.stack_or_frame_storage?
      # Raw fixed-size array (`T[N] = [...]`). Always lowers to a Zig
      # `[N]T{...}` literal regardless of CLEAR's storage classification:
      # the size > 128 slot threshold in finalize_storage promotes large
      # fixed-array literals to :frame, but for raw fixed-size arrays
      # there is no separate frame allocation -- the array data lives in
      # the function's own stack/frame either way, and Zig handles multi-
      # KB fixed arrays fine. Falling through to MakeList here would
      # produce an ArrayList whose Zig type doesn't match the variable's
      # declared `[N]T`, so the assignment fails to compile.
      return MIR::ArrayInit.new(elem_zig, node.items.length.to_s, items_mir)
    end

    if node.items.empty?
      # Empty list: MIR expression depends on collection type
      if ti.respond_to?(:list_collection?) && ti.list_collection?
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

  sig { params(node: AST::HashLit).returns(T.untyped) }
  def lower_hash_lit(node)
    T.bind(self, MIRLowering) rescue nil
    @current_decl_alloc = T.let(@current_decl_alloc, T.nilable(Symbol))

    ti = node.coerced_type_info || node.full_type!
    rt_name = runtime_binding_name
    map_alloc = @current_decl_alloc || alloc_for_node(node)
    alloc_str = "#{rt_name}.#{map_alloc == :heap ? "heapAlloc" : "frameAlloc"}()"

    # For Arc/Rc-wrapped maps, build bare inner type for init, then wrap
    is_arc = ti.shared?
    is_rc = ti.multiowned?
    if is_arc || is_rc
      # Sharded maps have their sync mode built into the Zig type
      # (e.g. MutexShardedStringMap), so they need the legacy direct-
      # composition path that preserves shard_count + sync on bare_ft.
      # Plain (non-sharded) maps go through compose_capability_wrap for
      # the unified Group 1 / Group 2 separation.
      if ti.striped?
        bare_ft = Type.new(ti.resolved.to_s)
        bare_ft.shard_count = ti.shard_count if ti.shard_count
        bare_ft.sync = ti.sync if ti.shard_count && ti.sync
        zig_t = bare_ft.zig_type

        needs_alloc = bare_ft.map_init_needs_alloc?
        inner = if needs_alloc
          MIR::StructInit.new(zig_t, [{ name: "alloc", value: MIR::Ident.new(alloc_str) }])
        else
          MIR::StructInit.new(zig_t, [])
        end

        wrap_fn = is_arc ? "arcCreate" : "rcCreate"
        inner = T.cast(
          with_ownership_consumption(
            MIR::CapWrap.new(inner, zig_t, :own_only, nil, nil, wrap_fn, :heap),
            mir_ident_names(inner),
            "MIR::CapWrap",
          ),
          MIR::CapWrap,
        )
        return inner if node.pairs.empty?
      else
        bare_ft = ti.bare_data_type
        zig_t = bare_ft.zig_type

        needs_alloc = bare_ft.respond_to?(:map_init_needs_alloc?) ? bare_ft.map_init_needs_alloc? :
                      (!zig_t.include?("PartitionedStringMap") && !zig_t.include?("PartitionedNumericMap") && !zig_t.include?("NumericMapType"))
        inner = if needs_alloc
          MIR::StructInit.new(zig_t, [{ name: "alloc", value: MIR::Ident.new(alloc_str) }])
        else
          MIR::StructInit.new(zig_t, [])
        end

        wrapped = compose_capability_wrap(inner, zig_t, ti, :heap)
        return wrapped if node.pairs.empty?
        inner = wrapped
      end
    end

    zig_t = transpile_type(ti)

    if node.pairs.empty?
      # PartitionedStringMap, PartitionedNumericMap, and NumericMapType don't have an .alloc field
      needs_alloc = !zig_t.include?("PartitionedStringMap") && !zig_t.include?("PartitionedNumericMap") && !zig_t.include?("NumericMapType")
      strategy = needs_alloc ? :map_bare : :map_empty
      return MIR::ContainerInit.new(zig_t, strategy, map_alloc, nil)
    end

    # Non-empty hash: init + puts
    items = []
    alloc_expr = MIR::MethodCall.new(MIR::Ident.new(rt_name), map_alloc == :heap ? "heapAlloc" : "frameAlloc", [], false, MIR::CallableContract.no_ownership(0))
    items << MIR::Let.new("__hm", MIR::StructInit.new(zig_t, [{ name: "alloc", value: alloc_expr }]), true, nil, nil)
    node.pairs.each do |key_node, val_node|
      k = lower(key_node)
      raw_v = with_decl_alloc(map_alloc) { materialize_owned_sink_value(lower(val_node), val_node, map_alloc) }
      v = hoist_alloc(raw_v, val_node, err_cleanup: true)
      consumed = (mir_ident_names(k) + mir_ident_names(v)).uniq
      base_contract = MIR::CallableContract.no_ownership(4)
      put_contract = MIR::CallableContract.new(
        base_contract.signature,
        MIR::OwnershipContract.consumes(consumed),
        4,
      )
      put_call = MIR::MethodCall.new(MIR::Ident.new("__hm"), "put", [alloc_expr, alloc_expr, k, v], true, put_contract)
      items << MIR::ExprStmt.new(put_call, false)
    end
    items << MIR::BreakStmt.new("__hm_blk", MIR::Ident.new("__hm"))
    MIR::BlockExpr.new("__hm_blk", append_ownership_transfers_for_mir_body(items))
  end
end
