module PipelineGenerator
  # Consolidates boilerplate for collection operators (SELECT, WHERE, etc.)
  # Handles source list extraction, allocator selection, and Zig block wrapping.
  #
  # For @pool and @pool:sharded(N): materializes live slot values into a frame
  # buffer before iteration so all pipeline ops work correctly.
  # For @list:sharded(N): flattens all shard slices into a frame buffer.
  def transpile_pipeline_macro(list_node, storage_node, init: nil, res_type: nil, force_aos: false)
    list_code = visit(list_node)
    alloc = storage_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
    lhs_type = list_node.type_info
    is_soa = !force_aos && (lhs_type&.pool? || lhs_type&.list_collection?) && lhs_type&.soa?

    # Optional result initialization (e.g. creating the output ArrayList)
    res_init = if init
      init.gsub("{alloc}", alloc)
    elsif res_type
      "var res_list = try CheatLib.makeList(#{transpile_type(res_type)}, #{alloc}, &.{});"
    else
      ""
    end

    body_code = yield(alloc)

    if is_soa
      # SOA path: field-slice declarations + SOA loop (no materialization).
      # @soa_needed_fields was populated during expression visit (GetField rewrite).
      field_slices = @soa_needed_fields.map { |f|
        "const __soa_#{f} = __soa_src.data.items(.#{f});"
      }.join("\n          ")

      # Rewrite the loop: for (pipe_items) |it| { → SOA index loop with alive check.
      body_code = body_code.gsub(
        /for \(pipe_items\) \|it\| \{/,
        "for (0..@intCast(__soa_src.data.len)) |__soa_i| {"
      )

      # Replace pipe_items.len references (used by MIN/MAX/AVERAGE).
      body_code = body_code.gsub("pipe_items.len", "@as(usize, @intCast(__soa_src.data.len))")

      # Insert alive check (pools only) + whole-struct reassembly (WHERE/FIND).
      inner_checks = ""
      if lhs_type&.pool?
        inner_checks = "if (!__soa_src.alive.items[__soa_i]) continue;"
      end
      if body_code.match?(/\bit\b/)
        # Body uses `it` as a whole struct — reassemble (only for matching elements).
        inner_checks += "\n                const it = __soa_src.data.get(__soa_i);"
      end
      if inner_checks.length > 0
        body_code = body_code.sub("__soa_i| {", "__soa_i| {\n                #{inner_checks}")
      end

      @soa_needed_fields.clear

      <<~ZIG
        blk: {
            const __soa_src = &#{list_code};
            #{field_slices}
            #{res_init}

            #{body_code}
        }
      ZIG
    else
      # Standard AOS path: materialize pipe_items then iterate.
      items_block = build_pipe_items_block(lhs_type, alloc)
      <<~ZIG
        blk: {
            const pipe_src_list = #{list_code};
            #{items_block}
            #{res_init}

            #{body_code}
        }
      ZIG
    end
  end

  # Emits Zig lines that produce `pipe_items` (a slice) from `pipe_src_list`.
  # Handles regular arrays, @pool, @pool:sharded(N), @list, and @list:sharded(N).
  #
  # Pools and sharded lists materialise live items into a temporary buffer.
  # We always use rt.heapAlloc() for that buffer because the fiber frame is
  # small (4 KB) and running many pipeline ops in one function would overflow it.
  def build_pipe_items_block(lhs_type, _alloc)
    if lhs_type&.pool? && lhs_type&.sharded?
      n = lhs_type.shard_count
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..#{n}) |__psi| {
            for (pipe_src_list.shards[__psi].slots.items) |*__pslot| {
                if (__pslot.alive) try pipe_mat.append(rt.heapAlloc(), __pslot.value);
            }
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.pool? && lhs_type&.soa?
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..@intCast(pipe_src_list.data.len)) |__psi| {
            if (pipe_src_list.alive.items[__psi]) try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.list_collection? && lhs_type&.soa?
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..@intCast(pipe_src_list.data.len)) |__psi| {
            try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.pool?
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};
        defer pipe_mat.deinit(rt.heapAlloc());
        for (pipe_src_list.slots.items) |*__pslot| {
            if (__pslot.alive) try pipe_mat.append(rt.heapAlloc(), __pslot.value);
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.list_collection? && lhs_type&.sharded?
      n = lhs_type.shard_count
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}){};
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..#{n}) |__psi| {
            try pipe_mat.appendSlice(rt.heapAlloc(), pipe_src_list.shards[__psi].items);
        }
        const pipe_items = pipe_mat.items;
      ZIG
    else
      # Standard array or @list: use .items if available, otherwise treat as slice
      "const pipe_items = if (@hasField(@TypeOf(pipe_src_list), \"items\")) pipe_src_list.items else pipe_src_list;"
    end
  end

  # Visit a pipeline expression with placeholder + SOA rewrite enabled.
  # When the collection is @pool:soa, _.field accesses in the expression
  # are rewritten to __soa_field[__soa_i] (field-slice access).
  def visit_pipeline_expr(list_node, expr_node, placeholder = "it")
    @placeholder_name = placeholder
    lhs_t = list_node.type_info
    is_soa = (lhs_t&.pool? || lhs_t&.list_collection?) && lhs_t&.soa?
    @soa_rewrite_active = is_soa
    @soa_needed_fields = Set.new if is_soa
    code = visit(expr_node)
    @placeholder_name = nil
    @soa_rewrite_active = false
    code
  end

  def transpile_select_projection(list_node, expression_node)
    expr_code = visit_pipeline_expr(list_node, expression_node)

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
    element_type_str = list_node.full_type.to_s.gsub(/[\[\]]/, '')
    expr_code = visit_pipeline_expr(list_node, expression_node)

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

    transpile_pipeline_macro(list_node, smooth_node, init: init, force_aos: true) do |alloc|
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

    transpile_pipeline_macro(list_node, reduce_node, init: init, force_aos: true) do
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

    transpile_pipeline_macro(list_node, smooth_node, init: init, force_aos: true) do
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

    transpile_pipeline_macro(list_node, smooth_node, force_aos: true) do |alloc|
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

    transpile_pipeline_macro(list_node, smooth_node, res_type: inner_element_type, force_aos: true) do |alloc|
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

    transpile_pipeline_macro(list_node, smooth_node, res_type: list_node.full_type.to_s.gsub(/[\[\]]/, ''), force_aos: true) do |alloc|
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

  # Transpile `collection s> EACH _.expr` — side-effect iteration.
  # Dispatches to the appropriate implementation based on the source type:
  #   - Regular array/list → sequential for loop
  #   - Plain pool         → sequential live-slot scan
  #   - Sharded pool       → N parallel fibers (one per shard, DO-block pattern)
  def transpile_each(smooth_node)
    lhs      = smooth_node.left
    each_op  = smooth_node.right
    lhs_type = lhs.type_info

    @placeholder_name = "__each_item"
    body_code = each_op.body.map { |stmt|
      code = visit(stmt)
      code.strip.end_with?(";") ? code : "#{code};"
    }.join("\n        ")
    @placeholder_name = nil

    if lhs_type&.pool?
      if lhs_type.sharded?
        transpile_each_sharded_pool(lhs, body_code, lhs_type)
      elsif lhs_type.soa?
        transpile_each_soa_pool(lhs, body_code)
      else
        transpile_each_pool(lhs, body_code)
      end
    elsif lhs_type&.list_collection? && lhs_type&.soa?
      transpile_each_soa_list(lhs, body_code)
    elsif lhs_type&.list_collection? && lhs_type&.sharded?
      transpile_each_sharded_list(lhs, body_code, lhs_type)
    else
      transpile_each_array(lhs, body_code)
    end
  end

  def transpile_each_array(list_node, body_code)
    list_code = visit(list_node)
    <<~ZIG.chomp
      {
          const __each_src = #{list_code};
          const __each_items = if (@hasField(@TypeOf(__each_src), "items")) __each_src.items else __each_src;
          for (__each_items) |*__each_item| {
              #{body_code}
          }
      }
    ZIG
  end

  def transpile_each_pool(pool_node, body_code)
    pool_code = visit(pool_node)
    <<~ZIG.chomp
      {
          const __each_src = &#{pool_code};
          for (__each_src.slots.items) |*__each_slot| {
              if (!__each_slot.alive) continue;
              const __each_item = &__each_slot.value;
              #{body_code}
          }
      }
    ZIG
  end

  def transpile_each_soa_list(list_node, body_code)
    list_code = visit(list_node)
    <<~ZIG.chomp
      {
          const __each_src = &#{list_code};
          for (0..@intCast(__each_src.data.len)) |__each_i| {
              var __each_item = __each_src.data.get(__each_i);
              _ = &__each_item;
              #{body_code}
              __each_src.data.set(__each_i, __each_item);
          }
      }
    ZIG
  end

  def transpile_each_soa_pool(pool_node, body_code)
    pool_code = visit(pool_node)
    # For SOA pools, use data.get(i) to reassemble the struct for the body.
    # This is correct but not cache-optimal for single-field access.
    # Full field-slice optimization for EACH requires tracking which fields
    # the body writes vs reads, which is future work (EACH bodies are mutable).
    <<~ZIG.chomp
      {
          const __each_src = &#{pool_code};
          for (0..@intCast(__each_src.data.len)) |__each_i| {
              if (!__each_src.alive.items[__each_i]) continue;
              var __each_item = __each_src.data.get(__each_i);
              _ = &__each_item;
              #{body_code}
              __each_src.data.set(__each_i, __each_item);
          }
      }
    ZIG
  end

  def transpile_each_sharded_pool(pool_node, body_code, pool_type)
    n          = pool_type.shard_count
    pool_code  = visit(pool_node)
    elem_zig   = pool_type.element_type.zig_type
    rt_name    = @do_rt_name || "rt"

    @each_counter ||= 0
    id = @each_counter
    @each_counter += 1

    wg_var = "__each#{id}_wg"

    shard_parts = (0...n).map do |i|
      ctx_type = "__EachShardCtx#{id}_#{i}"
      ctx_var  = "__each#{id}_ctx#{i}"
      # Body is re-emitted per shard inside the fiber; body_code already has _ resolved
      # We capture the whole pool src and use shards[i] inside the fiber
      shard_body = with_fiber_capture_map({}) do
        "for (ctx.shard.slots.items) |*__each_slot| {\n            if (!__each_slot.alive) continue;\n            const __each_item = &__each_slot.value;\n            #{body_code}\n        }"
      end

      <<~ZIG.chomp
        const #{ctx_type} = struct {
            wg: *CheatHeader.WaitGroup,
            shard: *CheatLib.Pool(#{elem_zig}),
            fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                _ = &__rt;
                const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                defer ctx.wg.done();
                #{shard_body}
            }
        };
        var #{ctx_var} = #{ctx_type}{ .wg = &#{wg_var}, .shard = &__each#{id}_src.shards[#{i}] };
        try #{wg_var}.sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
            &#{ctx_var},
            .{}
        );
      ZIG
    end

    <<~ZIG.chomp
      {
          const __each#{id}_src = &#{pool_code};
          var #{wg_var} = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          #{wg_var}.add(#{n});
          #{shard_parts.join("\n    ")}
          #{wg_var}.wait();
      }
    ZIG
  end

  # Parallel EACH over @list:sharded(N) — dispatches N fibers, one per shard.
  def transpile_each_sharded_list(list_node, body_code, list_type)
    n         = list_type.shard_count
    list_code = visit(list_node)
    elem_zig  = list_type.element_type.zig_type
    rt_name   = @do_rt_name || "rt"

    @each_counter ||= 0
    id = @each_counter
    @each_counter += 1

    wg_var = "__each#{id}_wg"

    shard_parts = (0...n).map do |i|
      ctx_type = "__EachListShardCtx#{id}_#{i}"
      ctx_var  = "__each#{id}_ctx#{i}"

      shard_body = with_fiber_capture_map({}) do
        "for (ctx.shard.items) |*__each_item| {\n            #{body_code}\n        }"
      end

      <<~ZIG.chomp
        const #{ctx_type} = struct {
            wg: *CheatHeader.WaitGroup,
            shard: *std.ArrayListUnmanaged(#{elem_zig}),
            fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                _ = &__rt;
                const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                defer ctx.wg.done();
                #{shard_body}
            }
        };
        var #{ctx_var} = #{ctx_type}{ .wg = &#{wg_var}, .shard = &__each#{id}_src.shards[#{i}] };
        try #{wg_var}.sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
            &#{ctx_var},
            .{}
        );
      ZIG
    end

    <<~ZIG.chomp
      {
          const __each#{id}_src = &#{list_code};
          var #{wg_var} = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          #{wg_var}.add(#{n});
          #{shard_parts.join("\n    ")}
          #{wg_var}.wait();
      }
    ZIG
  end

  # =========================================================
  # Phase 3: Predicate Query Operators
  # =========================================================

  def transpile_find(list_node, find_node, smooth_node)
    elem_zig_type = transpile_type(list_node.full_type.to_s.gsub(/[\[\]]/, ''))
    expr_code = visit_pipeline_expr(list_node, find_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var find_result: #{elem_zig_type} = undefined;
        var find_found = false;
        for (pipe_items) |it| {
            const find_matches = #{expr_code};
            if (find_matches) {
                find_result = it;
                find_found = true;
                break;
            }
        }
        break :blk if (find_found) @as(?#{elem_zig_type}, find_result) else null;
      ZIG
    end
  end

  def transpile_any(list_node, any_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, any_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var any_result = false;
        for (pipe_items) |it| {
            if (#{expr_code}) {
                any_result = true;
                break;
            }
        }
        break :blk any_result;
      ZIG
    end
  end

  def transpile_all(list_node, all_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, all_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var all_result = true;
        for (pipe_items) |it| {
            if (!(#{expr_code})) {
                all_result = false;
                break;
            }
        }
        break :blk all_result;
      ZIG
    end
  end

  def transpile_count(list_node, count_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, count_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var count_result: i64 = 0;
        for (pipe_items) |it| {
            if (#{expr_code}) {
                count_result += 1;
            }
        }
        break :blk count_result;
      ZIG
    end
  end

  # =========================================================
  # Phase 4: Numeric Aggregation Operators
  # =========================================================

  def transpile_sum(list_node, sum_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, sum_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var sum_result: f64 = 0;
        for (pipe_items) |it| {
            sum_result += #{expr_code};
        }
        break :blk sum_result;
      ZIG
    end
  end

  def transpile_average(list_node, avg_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, avg_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var avg_sum: f64 = 0;
        const avg_count = pipe_items.len;
        for (pipe_items) |it| {
            avg_sum += #{expr_code};
        }
        break :blk if (avg_count == 0) @as(f64, 0) else avg_sum / @as(f64, @floatFromInt(avg_count));
      ZIG
    end
  end

  def transpile_min(list_node, min_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, min_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        if (pipe_items.len == 0) @panic("MIN applied to empty list");
        var min_result: f64 = std.math.floatMax(f64);
        for (pipe_items) |it| {
            const min_val = #{expr_code};
            if (min_val < min_result) min_result = min_val;
        }
        break :blk min_result;
      ZIG
    end
  end

  def transpile_max(list_node, max_node, smooth_node)
    expr_code = visit_pipeline_expr(list_node, max_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        if (pipe_items.len == 0) @panic("MAX applied to empty list");
        var max_result: f64 = -std.math.floatMax(f64);
        for (pipe_items) |it| {
            const max_val = #{expr_code};
            if (max_val > max_result) max_result = max_val;
        }
        break :blk max_result;
      ZIG
    end
  end

  # =========================================================
  # CONCURRENT modifier: parallel SELECT, WHERE, EACH
  # =========================================================

  def transpile_concurrent(smooth_node)
    lhs     = smooth_node.left
    conc    = smooth_node.right   # ConcurrentOp
    inner   = conc.op
    options = conc.options

    @conc_counter ||= 0
    id = @conc_counter
    @conc_counter += 1

    workers_code = options["workers"] ? visit(options["workers"]) : "8"
    rt_name = @do_rt_name || "rt"

    case inner
    when AST::SelectOp
      transpile_concurrent_select(lhs, inner, id, workers_code, rt_name, options)
    when AST::WhereOp
      transpile_concurrent_where(lhs, inner, id, workers_code, rt_name, options)
    when AST::EachOp
      if conc.shard_context
        transpile_shard_concurrent_each(lhs, inner, id, rt_name, conc.shard_context)
      else
        transpile_concurrent_each(lhs, inner, id, workers_code, rt_name, options)
      end
    end
  end

  # Returns the Zig spawn call for CONCURRENT workers.
  # CONCURRENT: submitSpawn — workers stay on the local scheduler (cache-local, SPSC-safe).
  # @parallel: spawnBest — distributes across schedulers (true multi-core parallelism).
  def concurrent_spawn_call(options, wg_var, ctx_type, ctx_var)
    parallel  = options["parallel"]
    size_node = options["size"]
    size_sym  = size_node ? size_node.name.downcase.to_sym : nil
    task_cfg  = task_config_zig(size_sym)
    if parallel
      # @parallel: distribute workers across all schedulers (multi-core).
      "try CheatHeader.spawnBest(\n    @intFromPtr(&Runtime.entryWrapper),\n    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),\n    &#{ctx_var},\n    #{task_cfg},\n);"
    else
      # CONCURRENT (default): workers on local scheduler (deterministic, cache-local).
      "try #{wg_var}.sched.submitSpawn(\n    @intFromPtr(&Runtime.entryWrapper),\n    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),\n    &#{ctx_var},\n    #{task_cfg},\n);"
    end
  end

  # Inspect the expression for OR PRUNE / OR RAISE error policy
  # Returns [:prune, inner_expr], [:raise, inner_expr], or [:default, expr]
  def extract_concurrent_error_policy(expr)
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      if expr.right.is_a?(AST::OrPrune)
        return [:prune, expr.left]
      elsif expr.right.is_a?(AST::OrRaise)
        return [:raise, expr.left]
      end
    end
    [:default, expr]
  end

  def transpile_concurrent_select(list_node, select_op, id, workers_code, rt_name, options = {})
    policy, inner_expr = extract_concurrent_error_policy(select_op.expression)

    result_type_sym = select_op.expression.full_type
    result_zig = transpile_type(result_type_sym)
    item_zig   = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    # For the worker body, items accessed via ctx.items (the context struct).
    @placeholder_name = "ctx.items[__idx]"
    inner_code = with_fiber_capture_map({}) { visit(inner_expr) }
    @placeholder_name = nil
    bare_code = inner_code.sub(/^try /, '')

    err_field   = policy == :raise ? "\n              err:    *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err    = &__ccs#{id}_err," : ""
    err_decl    = policy == :raise ? "\n          var __ccs#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check   = policy == :raise ? "\n          const __ccs#{id}_err_code = __ccs#{id}_err.load(.seq_cst);\n          if (__ccs#{id}_err_code != 0) return @errorFromInt(__ccs#{id}_err_code);" : ""

    fiber_result_code = case policy
    when :prune
      "const __cv = #{bare_code} catch continue;\n                      ctx.results[__idx] = __cv;"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                          _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                          continue;\n                      };\n                      ctx.results[__idx] = __cv;"
    else
      "ctx.results[__idx] = #{inner_code};"
    end

    # Persistent worker pool: spawn N workers that each pull items
    # from a shared atomic index.  Zero per-item heap allocation.
    spawn_call = concurrent_spawn_call(options, "__ccs#{id}_wg", "__CcsWorker#{id}", "__ccs#{id}_workers[__w]")

    <<~ZIG.chomp
      blk: {
          const pipe_src_list = #{list_code};
          _ = &pipe_src_list;
          #{items_block}
          const __ccs#{id}_items = pipe_items;
          const __ccs#{id}_len = __ccs#{id}_items.len;
          const __ccs#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{result_zig}, __ccs#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccs#{id}_results);
          for (__ccs#{id}_results) |*__s| __s.* = null;#{err_decl}
          var __ccs#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccs#{id}_n_workers: usize = @intCast(#{workers_code});
          const __CcsWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   []const #{item_zig},
              results: []?#{result_zig},
              next:    *std.atomic.Value(usize),#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= ctx.items.len) break;
                      #{fiber_result_code}
                      __rt.checkYield();
                  }
              }
          };
          var __ccs#{id}_next = std.atomic.Value(usize).init(0);
          var __ccs#{id}_workers: [64]__CcsWorker#{id} = undefined;
          const __ccs#{id}_actual_workers = @min(__ccs#{id}_n_workers, 64);
          __ccs#{id}_wg.add(__ccs#{id}_actual_workers);
          for (0..__ccs#{id}_actual_workers) |__w| {
              __ccs#{id}_workers[__w] = .{
                  .wg      = &__ccs#{id}_wg,
                  .items   = __ccs#{id}_items,
                  .results = __ccs#{id}_results,
                  .next    = &__ccs#{id}_next,#{err_ctx_init}
              };
              #{spawn_call}
          }
          __ccs#{id}_wg.wait();#{err_check}
          var __ccs#{id}_final = std.ArrayListUnmanaged(#{result_zig}){};
          for (__ccs#{id}_results) |__ccs#{id}_slot| {
              if (__ccs#{id}_slot) |__v| try __ccs#{id}_final.append(#{rt_name}.heapAlloc(), __v);
          }
          break :blk __ccs#{id}_final;
      }
    ZIG
  end

  def transpile_concurrent_where(list_node, where_op, id, workers_code, rt_name, options = {})
    policy, inner_expr = extract_concurrent_error_policy(where_op.expression)

    item_type_str = list_node.full_type.to_s.gsub(/[\[\]]/, '')
    item_zig      = transpile_type(item_type_str)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    @placeholder_name = "ctx.items[__idx]"
    inner_code = with_fiber_capture_map({}) { visit(inner_expr) }
    @placeholder_name = nil
    bare_code = inner_code.sub(/^try /, '')

    err_field    = policy == :raise ? "\n              err:    *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err    = &__ccw#{id}_err," : ""
    err_decl     = policy == :raise ? "\n          var __ccw#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check    = policy == :raise ? "\n          const __ccw#{id}_err_code = __ccw#{id}_err.load(.seq_cst);\n          if (__ccw#{id}_err_code != 0) return @errorFromInt(__ccw#{id}_err_code);" : ""

    pred_body = case policy
    when :prune
      "const __cv = #{bare_code} catch continue;\n                      if (__cv) ctx.results[__idx] = ctx.items[__idx];"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                          _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                          continue;\n                      };\n                      if (__cv) ctx.results[__idx] = ctx.items[__idx];"
    else
      "if (#{inner_code}) ctx.results[__idx] = ctx.items[__idx];"
    end

    spawn_call = concurrent_spawn_call(options, "__ccw#{id}_wg", "__CcwWorker#{id}", "__ccw#{id}_workers[__w]")

    <<~ZIG.chomp
      blk: {
          const pipe_src_list = #{list_code};
          _ = &pipe_src_list;
          #{items_block}
          const __ccw#{id}_items = pipe_items;
          const __ccw#{id}_len = __ccw#{id}_items.len;
          const __ccw#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{item_zig}, __ccw#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccw#{id}_results);
          for (__ccw#{id}_results) |*__s| __s.* = null;#{err_decl}
          var __ccw#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccw#{id}_n_workers: usize = @intCast(#{workers_code});
          const __CcwWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   []const #{item_zig},
              results: []?#{item_zig},
              next:    *std.atomic.Value(usize),#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= ctx.items.len) break;
                      #{pred_body}
                      __rt.checkYield();
                  }
              }
          };
          var __ccw#{id}_next = std.atomic.Value(usize).init(0);
          var __ccw#{id}_workers: [64]__CcwWorker#{id} = undefined;
          const __ccw#{id}_actual_workers = @min(__ccw#{id}_n_workers, 64);
          __ccw#{id}_wg.add(__ccw#{id}_actual_workers);
          for (0..__ccw#{id}_actual_workers) |__w| {
              __ccw#{id}_workers[__w] = .{
                  .wg      = &__ccw#{id}_wg,
                  .items   = __ccw#{id}_items,
                  .results = __ccw#{id}_results,
                  .next    = &__ccw#{id}_next,#{err_ctx_init}
              };
              #{spawn_call}
          }
          __ccw#{id}_wg.wait();#{err_check}
          var __ccw#{id}_final = std.ArrayListUnmanaged(#{item_zig}){};
          for (__ccw#{id}_results) |__ccw#{id}_slot| {
              if (__ccw#{id}_slot) |__v| try __ccw#{id}_final.append(#{rt_name}.heapAlloc(), __v);
          }
          break :blk __ccw#{id}_final;
      }
    ZIG
  end

  def transpile_concurrent_each(list_node, each_op, id, workers_code, rt_name, options = {})
    item_zig = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    # For EACH workers, the placeholder references the shared items array by index.
    @placeholder_name = "&ctx.items[__idx]"
    body_code = with_fiber_capture_map({}) do
      each_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n                      ")
    end
    @placeholder_name = nil

    spawn_call = concurrent_spawn_call(options, "__cce#{id}_wg", "__CceWorker#{id}", "__cce#{id}_workers[__w]")

    <<~ZIG.chomp
      {
          var pipe_src_list = #{list_code};
          _ = &pipe_src_list;
          #{items_block}
          const __cce#{id}_items = pipe_items;
          const __cce#{id}_len = __cce#{id}_items.len;
          if (__cce#{id}_len == 0) {} else {
          var __cce#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __cce#{id}_n_workers: usize = @intCast(#{workers_code});
          const __CceWorker#{id} = struct {
              wg:    *CheatHeader.WaitGroup,
              items: []#{item_zig},
              next:  *std.atomic.Value(usize),
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= ctx.items.len) break;
                      const __each_item = &ctx.items[__idx];
                      _ = __each_item;
                      #{body_code}
                      __rt.checkYield();
                  }
              }
          };
          var __cce#{id}_next = std.atomic.Value(usize).init(0);
          var __cce#{id}_workers: [64]__CceWorker#{id} = undefined;
          const __cce#{id}_actual_workers = @min(__cce#{id}_n_workers, 64);
          __cce#{id}_wg.add(__cce#{id}_actual_workers);
          for (0..__cce#{id}_actual_workers) |__w| {
              __cce#{id}_workers[__w] = .{
                  .wg    = &__cce#{id}_wg,
                  .items = @constCast(__cce#{id}_items),
                  .next  = &__cce#{id}_next,
              };
              #{spawn_call}
          }
          __cce#{id}_wg.wait();
          }
      }
    ZIG
  end

  # =========================================================
  # SHARD + CONCURRENT EACH: true shared-nothing pipeline
  # =========================================================
  #
  # Emits:
  #   1. Route phase: iterate input, hash keys, fill per-shard queues
  #   2. Execute phase: spawn one fiber per shard on owning scheduler
  #   3. Join: WaitGroup.wait()
  #
  def transpile_shard_concurrent_each(lhs_node, each_op, id, rt_name, shard_ctx)
    auto_detected = shard_ctx[:auto_detected]
    shard_count = shard_ctx[:shard_count]
    map_node    = shard_ctx[:map_var]
    key_expr_node = shard_ctx[:key_expr]

    map_code = visit(map_node)
    map_var_name = map_node.is_a?(AST::Identifier) ? map_node.name : nil

    # Determine range node
    if auto_detected
      # LHS is the raw range (no ShardOp wrapper)
      range_node = lhs_node
    else
      # LHS is BinaryOp(SMOOTH, range, ShardOp)
      range_node = lhs_node.left
    end

    range_start = visit(range_node.start)
    range_end   = visit(range_node.finish)
    exclusive   = !range_node.inclusive

    # Build the key expression with `_` bound to the routing loop variable.
    @placeholder_name = "__sh#{id}_i"
    key_code = visit(key_expr_node)
    @placeholder_name = nil

    # Build the EACH body. Map accesses use putDirect/getDirect (no double hash).
    # The map is redirected to ctx.map_ptr. For auto-detected, we also set a flag
    # so the transpiler emits Direct methods and passes shard_idx.
    captures = map_var_name ? { map_var_name => "ctx.map_ptr" } : {}
    @placeholder_name = "__sh#{id}_keys[__sh#{id}_ki]"
    @shard_direct_map = map_var_name  # flag: emit putDirect/getDirect for this map
    @shard_direct_idx = "ctx.shard_idx"
    @shard_direct_key = "__sh#{id}_keys[__sh#{id}_ki]"  # pre-routed key from queue
    body_code = with_fiber_capture_map(captures) do
      each_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n                          ")
    end
    @shard_direct_map = nil
    @shard_direct_idx = nil
    @shard_direct_key = nil
    @placeholder_name = nil

    range_op = exclusive ? "<" : "<="

    <<~ZIG.chomp
      {
          // ── SHARD + CONCURRENT EACH (shared-nothing) ──
          const __sh#{id}_map = &#{map_code};
          __sh#{id}_map.ensureOwnership();
          const __sh#{id}_N = #{shard_count};

          // Routing arena: all keys are allocated from a single arena that
          // is freed in one shot after workers complete. Zero per-key free.
          var __sh#{id}_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
          defer __sh#{id}_arena.deinit();
          const __sh#{id}_alloc = __sh#{id}_arena.allocator();

          // Per-shard key queues (queue metadata uses c_allocator, keys use arena)
          var __sh#{id}_queues: [__sh#{id}_N]std.ArrayListUnmanaged([]const u8) = undefined;
          for (&__sh#{id}_queues) |*q| q.* = .{};
          defer for (&__sh#{id}_queues) |*q| q.deinit(std.heap.c_allocator);

          // Route phase: hash each key, append to owning shard's queue.
          {
              var __sh#{id}_i: i64 = #{range_start};
              const __sh#{id}_end: i64 = #{range_end};
              while (__sh#{id}_i #{range_op} __sh#{id}_end) : (__sh#{id}_i += 1) {
                  const __sh#{id}_tmp_key = #{key_code};
                  const __sh#{id}_key = try __sh#{id}_alloc.dupe(u8, __sh#{id}_tmp_key);
                  const __sh#{id}_sidx = @TypeOf(__sh#{id}_map.*).shardIndex(__sh#{id}_key);
                  try __sh#{id}_queues[__sh#{id}_sidx].append(std.heap.c_allocator, __sh#{id}_key);
              }
          }

          // Execute phase: one fiber per shard, pinned to owning scheduler
          const __ShardWorker#{id} = struct {
              wg: *CheatHeader.WaitGroup,
              map_ptr: *@TypeOf(__sh#{id}_map.*),
              keys: []const []const u8,
              shard_idx: usize,
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  const __sh#{id}_keys = ctx.keys;
                  var __sh#{id}_ki: usize = 0;
                  while (__sh#{id}_ki < __sh#{id}_keys.len) : (__sh#{id}_ki += 1) {
                      #{body_code}
                      __rt.checkYield();
                  }
              }
          };

          var __sh#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          // Count non-empty shards
          var __sh#{id}_active: usize = 0;
          for (__sh#{id}_queues) |q| { if (q.items.len > 0) __sh#{id}_active += 1; }
          if (__sh#{id}_active > 0) {
              __sh#{id}_wg.add(__sh#{id}_active);
              var __sh#{id}_ctxs: [__sh#{id}_N]__ShardWorker#{id} = undefined;
              for (0..__sh#{id}_N) |__sh#{id}_si| {
                  if (__sh#{id}_queues[__sh#{id}_si].items.len == 0) continue;
                  __sh#{id}_ctxs[__sh#{id}_si] = .{
                      .wg = &__sh#{id}_wg,
                      .map_ptr = __sh#{id}_map,
                      .keys = __sh#{id}_queues[__sh#{id}_si].items,
                      .shard_idx = __sh#{id}_si,
                  };
                  // Submit to the scheduler that OWNS this shard
                  try __sh#{id}_map.owners[__sh#{id}_si].?.submitSpawn(
                      @intFromPtr(&Runtime.entryWrapper),
                      @as(CheatHeader.TaskFn, @ptrCast(&__ShardWorker#{id}.run)),
                      &__sh#{id}_ctxs[__sh#{id}_si],
                      .{ .pinned = true },
                  );
              }
              __sh#{id}_wg.wait();
          }
      }
    ZIG
  end

  def visit_Placeholder(node)
    # Return the name of the loop variable
    @placeholder_name || (raise "Use of '_' outside of SELECT context")
  end
end
