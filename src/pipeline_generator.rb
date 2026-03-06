module PipelineGenerator
  # Consolidates boilerplate for collection operators (SELECT, WHERE, etc.)
  # Handles source list extraction, allocator selection, and Zig block wrapping.
  def transpile_pipeline_macro(list_node, storage_node, init: nil, res_type: nil)
    list_code = visit(list_node)
    alloc = storage_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
    
    # Optional result initialization (e.g. creating the output ArrayList)
    res_init = if init
      init.gsub("{alloc}", alloc)
    elsif res_type
      "var res_list = try CheatLib.makeList(#{transpile_type(res_type)}, #{alloc}, &.{});"
    else
      ""
    end

    body_code = yield(alloc)

    <<~ZIG
      blk: {
          const pipe_src_list = #{list_code};
          // Handle both ArrayList and Slice
          const pipe_items = if (@hasField(@TypeOf(pipe_src_list), \"items\")) pipe_src_list.items else pipe_src_list;
          #{res_init}

          #{body_code}
      }
    ZIG

  end

  def transpile_select_projection(list_node, expression_node)
    @placeholder_name = "it"
    expr_code = visit(expression_node)
    @placeholder_name = nil

    transpile_pipeline_macro(list_node, expression_node, res_type: expression_node.full_type) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const val = #{expr_code};
            try res_list.append(#{alloc}, val);
        }
        break :blk res_list;
      ZIG
    end
  end

  def transpile_where_filter(list_node, expression_node)
    # Extract the element type (e.g. "Number[]" -> "Number")
    element_type_str = list_node.full_type.to_s.gsub(/[\[\]]/, '')

    @placeholder_name = "it"
    expr_code = visit(expression_node)
    @placeholder_name = nil

    transpile_pipeline_macro(list_node, expression_node, res_type: element_type_str) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const matches = #{expr_code};
            if (matches) {
                try res_list.append(#{alloc}, it);
            }
        }
        break :blk res_list;
      ZIG
    end
  end

  def transpile_index_grouping(list_node, expression_node, smooth_node)
    element_zig_type = transpile_type(list_node.full_type.to_s.gsub(/[\[\]]/, ''))

    @placeholder_name = "it"
    expr_code = visit(expression_node)
    @placeholder_name = nil

    init = "var idx_result: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(#{element_zig_type})) = .{};"

    transpile_pipeline_macro(list_node, smooth_node, init: init) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const idx_key = #{expr_code};
            const gop = idx_result.getOrPut(#{alloc}, idx_key) catch @panic("INDEX allocation failed");
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayListUnmanaged(#{element_zig_type}){};
            }
            gop.value_ptr.append(#{alloc}, it) catch @panic("INDEX append failed");
        }
        break :blk idx_result;
      ZIG
    end
  end

  def transpile_reduce(list_node, reduce_node)
    acc_type = transpile_type(reduce_node.full_type)
    initial_code = visit(reduce_node.initial_value)

    @placeholder_name = "it"
    @acc_placeholder = "acc"
    expr_code = visit(reduce_node.expression)
    @placeholder_name = nil
    @acc_placeholder = nil

    init = "var acc: #{acc_type} = #{initial_code};"

    transpile_pipeline_macro(list_node, reduce_node, init: init) do
      <<~ZIG
        for (pipe_items) |it| {
            acc = #{expr_code};
        }
        break :blk acc;
      ZIG
    end
  end

  def transpile_order_by(list_node, order_node, smooth_node)
    element_zig_type = transpile_type(list_node.full_type.to_s.gsub(/[\[\]]/, ''))

    @placeholder_name = "a"
    key_expr_a = visit(order_node.expression)
    @placeholder_name = "b"
    key_expr_b = visit(order_node.expression)
    @placeholder_name = nil

    init = <<~ZIG
      var ord_result = try CheatLib.makeList(#{element_zig_type}, {alloc}, pipe_items);
      _ = &ord_result;
    ZIG

    transpile_pipeline_macro(list_node, smooth_node, init: init) do
      <<~ZIG
        // Sort using custom comparator
        std.mem.sort(#{element_zig_type}, ord_result.items, {}, struct {
            pub fn lessThan(_: void, a: #{element_zig_type}, b: #{element_zig_type}) bool {
                return #{key_expr_a} < #{key_expr_b};
            }
        }.lessThan);

        break :blk ord_result;
      ZIG
    end
  end

  def transpile_limit(list_node, limit_node, smooth_node)
    element_zig_type = transpile_type(list_node.full_type.to_s.gsub(/[\[\]]/, ''))
    count_code = visit(limit_node.count)

    transpile_pipeline_macro(list_node, smooth_node) do |alloc|
      <<~ZIG
        // Calculate actual count (min of requested and available)
        const lim_requested: usize = @intCast(#{count_code});
        const lim_actual = @min(lim_requested, pipe_items.len);

        // Create new list with limited items
        break :blk try CheatLib.makeList(#{element_zig_type}, #{alloc}, pipe_items[0..lim_actual]);
      ZIG
    end
  end

  def transpile_unnest(list_node, unnest_node, smooth_node)
    inner_element_type = unnest_node.full_type.to_s.gsub(/[\[\]]/, '')
    inner_zig_type = transpile_type(inner_element_type)

    @placeholder_name = "it"
    expr_code = visit(unnest_node.expression)
    @placeholder_name = nil

    transpile_pipeline_macro(list_node, smooth_node, res_type: inner_element_type) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            // Get the inner array from each element
            const unn_inner = #{expr_code};
            const unn_inner_items = if (@hasField(@TypeOf(unn_inner), "items")) unn_inner.items else unn_inner;

            // Append all inner items to result
            for (unn_inner_items) |inner_it| {
                try res_list.append(#{alloc}, inner_it);
            }
        }
        break :blk res_list;
      ZIG
    end
  end

  def transpile_distinct(list_node, distinct_node, smooth_node)
    element_zig_type = transpile_type(list_node.full_type.to_s.gsub(/[\[\]]/, ''))

    @placeholder_name = "it"
    expr_code = visit(distinct_node.expression)
    @placeholder_name = "it2"
    expr_code_inner = visit(distinct_node.expression)
    @placeholder_name = nil

    transpile_pipeline_macro(list_node, smooth_node, res_type: list_node.full_type.to_s.gsub(/[\[\]]/, '')) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const dist_key = #{expr_code};

            // Check if this key already exists in result (linear scan)
            var dist_found = false;
            for (res_list.items) |it2| {
                const dist_existing_key = #{expr_code_inner};
                if (CheatLib.eql(dist_key, dist_existing_key)) {
                    dist_found = true;
                    break;
                }
            }

            if (!dist_found) {
                try res_list.append(#{alloc}, it);
            }
        }
        break :blk res_list;
      ZIG
    end
  end

  def visit_Placeholder(node)
    # Return the name of the loop variable
    @placeholder_name || (raise "Use of '_' outside of SELECT context")
  end
end
