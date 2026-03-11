module PipelineGenerator
  # Consolidates boilerplate for collection operators (SELECT, WHERE, etc.)
  # Handles source list extraction, allocator selection, and Zig block wrapping.
  #
  # For @pool and @pool:sharded(N): materializes live slot values into a frame
  # buffer before iteration so all pipeline ops work correctly.
  # For @list:sharded(N): flattens all shard slices into a frame buffer.
  def transpile_pipeline_macro(list_node, storage_node, init: nil, res_type: nil)
    list_code = visit(list_node)
    alloc = storage_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
    lhs_type = list_node.type_info

    # Build items extraction / materialization block
    items_block = build_pipe_items_block(lhs_type, alloc)

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
          #{items_block}
          #{res_init}

          #{body_code}
      }
    ZIG
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
      else
        transpile_each_pool(lhs, body_code)
      end
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

    @placeholder_name = "it"
    expr_code = visit(find_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(any_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(all_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(count_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(sum_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(avg_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(min_node.expression)
    @placeholder_name = nil

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
    @placeholder_name = "it"
    expr_code = visit(max_node.expression)
    @placeholder_name = nil

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

    pool_size_code = options["pool_size"] ? visit(options["pool_size"]) : "8"
    rt_name = @do_rt_name || "rt"

    case inner
    when AST::SelectOp
      transpile_concurrent_select(lhs, inner, id, pool_size_code, rt_name, options)
    when AST::WhereOp
      transpile_concurrent_where(lhs, inner, id, pool_size_code, rt_name, options)
    when AST::EachOp
      transpile_concurrent_each(lhs, inner, id, pool_size_code, rt_name, options)
    end
  end

  # Returns the Zig spawn call: spawnBest (pin: true) or submitSpawn (default).
  # Respects the `size` option to set TaskConfig.stack_size on each spawned fiber.
  def concurrent_spawn_call(options, wg_var, ctx_type, ctx_var)
    pinned    = options["pin"]
    size_node = options["size"]
    size_sym  = size_node ? size_node.name.downcase.to_sym : nil
    task_cfg  = task_config_zig(size_sym)
    if pinned
      "try CheatHeader.spawnBest(\n    @intFromPtr(&Runtime.entryWrapper),\n    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),\n    &#{ctx_var},\n    #{task_cfg},\n);"
    else
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

  def transpile_concurrent_select(list_node, select_op, id, pool_size_code, rt_name, options = {})
    policy, inner_expr = extract_concurrent_error_policy(select_op.expression)

    result_type_sym = select_op.expression.full_type
    result_zig = transpile_type(result_type_sym)
    item_zig   = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    @placeholder_name = "ctx.item"
    inner_code = with_fiber_capture_map({}) { visit(inner_expr) }
    @placeholder_name = nil
    bare_code = inner_code.sub(/^try /, '')

    err_field   = policy == :raise ? "\n              err:    *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err    = &__ccs#{id}_err," : ""
    err_decl    = policy == :raise ? "\n          var __ccs#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check   = policy == :raise ? "\n          const __ccs#{id}_err_code = __ccs#{id}_err.load(.seq_cst);\n          if (__ccs#{id}_err_code != 0) return @errorFromInt(__ccs#{id}_err_code);" : ""

    fiber_result_code = case policy
    when :prune
      "const __cv = #{bare_code} catch return;\n                  ctx.result.* = __cv;"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                      _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                      return;\n                  };\n                  ctx.result.* = __cv;"
    else
      "ctx.result.* = #{inner_code};"
    end

    spawn_call = concurrent_spawn_call(options, "__ccs#{id}_wg", "__ConcSelCtx#{id}", "__ccs#{id}_ctxs[__ccs#{id}_i]")

    <<~ZIG.chomp
      blk: {
          const pipe_src_list = #{list_code};
          _ = &pipe_src_list;
          #{items_block}
          const __ConcSelCtx#{id} = struct {
              wg:     *CheatHeader.WaitGroup,
              sem:    *CheatHeader.Semaphore,
              item:   #{item_zig},
              result: *?#{result_zig},#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  defer ctx.sem.release();
                  #{fiber_result_code}
              }
          };
          const __ccs#{id}_len = pipe_items.len;
          var __ccs#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{result_zig}, __ccs#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccs#{id}_results);
          for (__ccs#{id}_results) |*__s| __s.* = null;
          var __ccs#{id}_ctxs = try #{rt_name}.heapAlloc().alloc(__ConcSelCtx#{id}, __ccs#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccs#{id}_ctxs);#{err_decl}
          var __ccs#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          var __ccs#{id}_sem = CheatHeader.Semaphore.init(@as(usize, @intCast(#{pool_size_code})), #{rt_name}.getSched());
          __ccs#{id}_wg.add(__ccs#{id}_len);
          for (pipe_items, 0..) |__ccs#{id}_it, __ccs#{id}_i| {
              __ccs#{id}_sem.acquire();
              __ccs#{id}_ctxs[__ccs#{id}_i] = .{
                  .wg     = &__ccs#{id}_wg,
                  .sem    = &__ccs#{id}_sem,
                  .item   = __ccs#{id}_it,
                  .result = &__ccs#{id}_results[__ccs#{id}_i],#{err_ctx_init}
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

  def transpile_concurrent_where(list_node, where_op, id, pool_size_code, rt_name, options = {})
    policy, inner_expr = extract_concurrent_error_policy(where_op.expression)

    item_type_str = list_node.full_type.to_s.gsub(/[\[\]]/, '')
    item_zig      = transpile_type(item_type_str)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    @placeholder_name = "ctx.item"
    inner_code = with_fiber_capture_map({}) { visit(inner_expr) }
    @placeholder_name = nil
    bare_code = inner_code.sub(/^try /, '')

    err_field    = policy == :raise ? "\n              err:    *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err    = &__ccw#{id}_err," : ""
    err_decl     = policy == :raise ? "\n          var __ccw#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check    = policy == :raise ? "\n          const __ccw#{id}_err_code = __ccw#{id}_err.load(.seq_cst);\n          if (__ccw#{id}_err_code != 0) return @errorFromInt(__ccw#{id}_err_code);" : ""

    pred_body = case policy
    when :prune
      "const __cv = #{bare_code} catch return;\n                  if (__cv) ctx.result.* = ctx.item;"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                      _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                      return;\n                  };\n                  if (__cv) ctx.result.* = ctx.item;"
    else
      "if (#{inner_code}) ctx.result.* = ctx.item;"
    end

    spawn_call = concurrent_spawn_call(options, "__ccw#{id}_wg", "__ConcWhrCtx#{id}", "__ccw#{id}_ctxs[__ccw#{id}_i]")

    <<~ZIG.chomp
      blk: {
          const pipe_src_list = #{list_code};
          _ = &pipe_src_list;
          #{items_block}
          const __ConcWhrCtx#{id} = struct {
              wg:     *CheatHeader.WaitGroup,
              sem:    *CheatHeader.Semaphore,
              item:   #{item_zig},
              result: *?#{item_zig},#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  defer ctx.sem.release();
                  #{pred_body}
              }
          };
          const __ccw#{id}_len = pipe_items.len;
          var __ccw#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{item_zig}, __ccw#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccw#{id}_results);
          for (__ccw#{id}_results) |*__s| __s.* = null;
          var __ccw#{id}_ctxs = try #{rt_name}.heapAlloc().alloc(__ConcWhrCtx#{id}, __ccw#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccw#{id}_ctxs);#{err_decl}
          var __ccw#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          var __ccw#{id}_sem = CheatHeader.Semaphore.init(@as(usize, @intCast(#{pool_size_code})), #{rt_name}.getSched());
          __ccw#{id}_wg.add(__ccw#{id}_len);
          for (pipe_items, 0..) |__ccw#{id}_it, __ccw#{id}_i| {
              __ccw#{id}_sem.acquire();
              __ccw#{id}_ctxs[__ccw#{id}_i] = .{
                  .wg     = &__ccw#{id}_wg,
                  .sem    = &__ccw#{id}_sem,
                  .item   = __ccw#{id}_it,
                  .result = &__ccw#{id}_results[__ccw#{id}_i],#{err_ctx_init}
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

  def transpile_concurrent_each(list_node, each_op, id, pool_size_code, rt_name, options = {})
    item_zig = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    @placeholder_name = "__each_item"
    body_code = with_fiber_capture_map({}) do
      each_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n                ")
    end
    @placeholder_name = nil

    spawn_call = concurrent_spawn_call(options, "__cce#{id}_wg", "__ConcEachCtx#{id}", "__cce#{id}_ctxs[__cce#{id}_i]")

    <<~ZIG.chomp
      {
          const pipe_src_list = #{list_code};
          _ = &pipe_src_list;
          #{items_block}
          const __cce#{id}_len = pipe_items.len;
          if (__cce#{id}_len == 0) {} else {
          const __ConcEachCtx#{id} = struct {
              wg:       *CheatHeader.WaitGroup,
              sem:      *CheatHeader.Semaphore,
              item_ptr: *#{item_zig},
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  defer ctx.sem.release();
                  const __each_item = ctx.item_ptr;
                  #{body_code}
              }
          };
          var __cce#{id}_ctxs = try #{rt_name}.heapAlloc().alloc(__ConcEachCtx#{id}, __cce#{id}_len);
          defer #{rt_name}.heapAlloc().free(__cce#{id}_ctxs);
          var __cce#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          var __cce#{id}_sem = CheatHeader.Semaphore.init(@as(usize, @intCast(#{pool_size_code})), #{rt_name}.getSched());
          __cce#{id}_wg.add(__cce#{id}_len);
          for (pipe_items, 0..) |*__cce#{id}_it, __cce#{id}_i| {
              __cce#{id}_sem.acquire();
              __cce#{id}_ctxs[__cce#{id}_i] = .{
                  .wg       = &__cce#{id}_wg,
                  .sem      = &__cce#{id}_sem,
                  .item_ptr = __cce#{id}_it,
              };
              #{spawn_call}
          }
          __cce#{id}_wg.wait();
          }
      }
    ZIG
  end

  def visit_Placeholder(node)
    # Return the name of the loop variable
    @placeholder_name || (raise "Use of '_' outside of SELECT context")
  end
end
