# typed: true
# Generates Zig code for pipeline operators (|>) that need special
# iteration patterns: pool, sharded, SOA sources, and CONCURRENT.
#
# For plain-array sources, PipelineRewriter converts most operators
# into standard AST nodes (ForEach, BlockExpr, IfStatement) before
# the transpiler runs. This module is still needed for:
#   - Pool/sharded/SOA sources (all operators)
#   - CONCURRENT/SHARD (all source types)
#   - Non-rewritten operators: INDEX, ORDER_BY, LIMIT, SKIP,
#     WINDOW, JOIN (all sources)
require "sorbet-runtime"

module PipelineGenerator
    extend T::Sig

  # Unique label for each pipeline block -- prevents Zig label collisions
  # when pipelines are chained (e.g., a |> SELECT |> WHERE).
  sig { returns(String) }
  def next_pipe_label
    T.bind(self, T.untyped) rescue nil
    @pipe_label_counter = (@pipe_label_counter || 0) + 1
    "__pblk#{@pipe_label_counter}"
  end

  # -------------------------------------------------------------------------
  # Note: Loop fusion for plain-array sources is handled by PipelineRewriter
  # (src/pipeline_rewriter.rb) before MIRLowering runs. For pool/sharded/SOA
  # sources, individual operator methods handle each stage via materialization.
  # -------------------------------------------------------------------------

  # When lower_concurrent detected `list AS $u |> CONCURRENT op`, this wraps
  # the expression visit with $u -> placeholder substitution active.
  sig { params(placeholder: T.untyped, blk: T.untyped).returns(String) }
  def with_concurrent_outer_binding(placeholder, &blk)
    T.bind(self, T.untyped) rescue nil
    return blk.call unless @concurrent_outer_binding
    with_named_binding(@concurrent_outer_binding, placeholder) { blk.call }
  end

  # Save and restore all pipeline state around a block. Ensures that nested
  # pipeline visits (chained pipelines, SHARD bodies, etc.) don't leak state.
  # Any keyword argument overrides the corresponding state for the block's duration.
  def with_pipeline_context(placeholder: nil, acc: nil, soa: :inherit, shard_map: nil, shard_idx: nil, shard_key: nil, shard_hash: nil)
    T.bind(self, T.untyped) rescue nil
    prev_placeholder = @placeholder_name
    prev_acc         = @acc_placeholder
    prev_shard_map   = @shard_direct_map
    prev_shard_idx   = @shard_direct_idx
    prev_shard_key   = @shard_direct_key
    prev_shard_hash  = @shard_direct_hash

    @placeholder_name  = placeholder
    @acc_placeholder   = acc
    @shard_direct_map  = shard_map
    @shard_direct_idx  = shard_idx
    @shard_direct_key  = shard_key
    @shard_direct_hash = shard_hash

    # SOA state: only save/restore when explicitly set (soa: true/false).
    # :inherit means "don't touch SOA" — lets inner visit_pipeline_expr's
    # SOA fields accumulate and be read by the outer macro.
    managing_soa = soa != :inherit
    if managing_soa
      prev_soa_active = @soa_rewrite_active
      prev_soa_fields = @soa_needed_fields
      @soa_rewrite_active = soa
      @soa_needed_fields = Set.new if soa
    end

    result = yield
  ensure
    @placeholder_name   = prev_placeholder
    @acc_placeholder    = prev_acc
    @shard_direct_map   = prev_shard_map
    @shard_direct_idx   = prev_shard_idx
    @shard_direct_key   = prev_shard_key
    @shard_direct_hash  = prev_shard_hash
    if managing_soa
      @soa_rewrite_active = prev_soa_active
      @soa_needed_fields  = prev_soa_fields
    end
    result
  end

  # Consolidates boilerplate for collection operators (SELECT, WHERE, etc.)
  # Handles source list extraction, allocator selection, and Zig block wrapping.
  #
  # For @pool and @pool:sharded(N): materializes live slot values into a frame
  # buffer before iteration so all pipeline ops work correctly.
  # For @list:sharded(N): flattens all shard slices into a frame buffer.
  def transpile_pipeline_macro(list_node, storage_node, init: nil, res_type: nil, force_aos: false)
    T.bind(self, T.untyped) rescue nil
    my_label = next_pipe_label
    list_code = visit(list_node)  # may recurse for chained pipelines
    @current_pipe_label = my_label  # restore after inner pipeline may have changed it
    alloc = storage_node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
    lhs_type = list_node.type_info
    is_soa = !force_aos && lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)

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
      # Use live_count (not data.len) since fixed-capacity pools have data.len == capacity.
      len_expr = lhs_type&.pool? ? "@as(usize, @intCast(__soa_src.live_count))" : "@as(usize, @intCast(__soa_src.data.len))"
      body_code = body_code.gsub("pipe_items.len", len_expr)

      # Insert alive check (pools only) + whole-struct reassembly (WHERE/FIND).
      inner_checks = ""
      if lhs_type&.pool?
        inner_checks = "if (!__soa_src.alive[__soa_i]) continue;"
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
        #{@current_pipe_label}: {
            const __soa_src = &#{list_code};
            #{field_slices}
            #{res_init}

            #{body_code}
        }
      ZIG
    else
      # Standard AOS path: materialize pipe_items then iterate.
      items_block = build_pipe_items_block(lhs_type, alloc)

      # Detect heap-allocated sources that need cleanup after iteration.
      # values()/keys() on a sharded map allocates a new heap list — if used inline
      # as a pipeline source (not as a named variable), it must be freed here.
      src_needs_cleanup = list_node.is_a?(AST::MethodCall) &&
                          %w[values keys].include?(list_node.name.to_s) &&
                          list_node.object.type_info&.sharded?
      cleanup_line = src_needs_cleanup ? "defer pipe_src_list.deinit(rt.heapAlloc());" : ""
      src_decl     = src_needs_cleanup ? "var pipe_src_list"   : "const pipe_src_list"

      <<~ZIG
        #{@current_pipe_label}: {
            #{src_decl} = #{list_code};
            #{cleanup_line}
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
  sig { params(lhs_type: T.untyped, _alloc: T.untyped).returns(String) }
  def build_pipe_items_block(lhs_type, _alloc)
    T.bind(self, T.untyped) rescue nil
    if lhs_type&.pool? && lhs_type&.sharded?
      n = lhs_type.shard_count
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}).empty;
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..#{n}) |__psi| {
            for (pipe_src_list.shards[__psi].slots) |*__pslot| {
                if (__pslot.alive) try pipe_mat.append(rt.heapAlloc(), __pslot.value);
            }
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.pool? && lhs_type&.soa?
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}).empty;
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..@intCast(pipe_src_list.data.len)) |__psi| {
            if (pipe_src_list.alive[__psi]) try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.list_collection? && lhs_type&.soa?
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}).empty;
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..@intCast(pipe_src_list.data.len)) |__psi| {
            try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.pool?
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}).empty;
        defer pipe_mat.deinit(rt.heapAlloc());
        for (pipe_src_list.slots) |*__pslot| {
            if (__pslot.alive) try pipe_mat.append(rt.heapAlloc(), __pslot.value);
        }
        const pipe_items = pipe_mat.items;
      ZIG
    elsif lhs_type&.list_collection? && lhs_type&.sharded?
      n = lhs_type.shard_count
      elem_zig = lhs_type.element_type.zig_type
      <<~ZIG.strip
        var pipe_mat = std.ArrayListUnmanaged(#{elem_zig}).empty;
        defer pipe_mat.deinit(rt.heapAlloc());
        for (0..#{n}) |__psi| {
            try pipe_mat.appendSlice(rt.heapAlloc(), pipe_src_list.shards[__psi].items);
        }
        const pipe_items = pipe_mat.items;
      ZIG
    else
      # Plain array/list: used by CONCURRENT and non-rewritten operators (INDEX, ORDER_BY, etc.)
      "const pipe_items = if (@hasField(@TypeOf(pipe_src_list), \"items\")) pipe_src_list.items else pipe_src_list[0..];"
    end
  end

  # Visit a pipeline expression with placeholder + SOA rewrite enabled.
  # When the collection is @pool:soa, _.field accesses in the expression
  # are rewritten to __soa_field[__soa_i] (field-slice access).
  sig { params(list_node: T.untyped, expr_node: T.untyped, placeholder: T.untyped).returns(String) }
  def visit_pipeline_expr(list_node, expr_node, placeholder = "it")
    T.bind(self, T.untyped) rescue nil
    lhs_t = list_node.type_info
    is_soa = (lhs_t&.pool? || lhs_t&.list_collection?) && lhs_t&.soa?
    prev_soa_active = @soa_rewrite_active
    # SOA state is set directly (not via with_pipeline_context) because
    # @soa_needed_fields must survive beyond the visit -- the caller
    # (transpile_pipeline_macro) reads it after this returns.
    @soa_rewrite_active = is_soa
    @soa_needed_fields = Set.new if is_soa
    result = with_pipeline_context(placeholder: placeholder) do
      visit(expr_node)
    end
    @soa_rewrite_active = prev_soa_active
    result
  end

  def transpile_select_projection(list_node, expression_node)
    T.bind(self, T.untyped) rescue nil
    expr_code = visit_pipeline_expr(list_node, expression_node)

    transpile_pipeline_macro(list_node, expression_node, res_type: expression_node.full_type) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const val = #{expr_code};
            try res_list.append(#{alloc}, val);
        }
        break :#{@current_pipe_label} res_list;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, expression_node: T.untyped).returns(String) }
  def transpile_where_filter(list_node, expression_node)
    T.bind(self, T.untyped) rescue nil
    element_type_str = list_node.full_type.element_type.resolved.to_s
    expr_code = visit_pipeline_expr(list_node, expression_node)

    transpile_pipeline_macro(list_node, expression_node, res_type: element_type_str) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const matches = #{expr_code};
            if (matches) {
                try res_list.append(#{alloc}, it);
            }
        }
        break :#{@current_pipe_label} res_list;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, expression_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_take_while(list_node, expression_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    element_type_str = list_node.full_type.element_type.resolved.to_s
    expr_code = visit_pipeline_expr(list_node, expression_node)

    transpile_pipeline_macro(list_node, smooth_node, res_type: element_type_str) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const matches = #{expr_code};
            if (!matches) break;
            try res_list.append(#{alloc}, it);
        }
        break :#{@current_pipe_label} res_list;
      ZIG
    end
  end

  def transpile_window(list_node, window_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    size_code = visit(window_node.size)
    expr_type_str = (window_node.expression.full_type || window_node.expression.resolved_type).to_s
    element_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)

    expr_code = with_pipeline_context(placeholder: "window_slice") {
      visit(window_node.expression)
    }

    transpile_pipeline_macro(list_node, smooth_node, res_type: expr_type_str) do |alloc|
      <<~ZIG
        {
            const __w_size: usize = @intCast(#{size_code});
            if (pipe_items.len >= __w_size) {
                var __wi: usize = 0;
                while (__wi <= pipe_items.len - __w_size) : (__wi += 1) {
                    const window_slice = pipe_items[__wi .. __wi + __w_size];
                    const val = #{expr_code};
                    try res_list.append(#{alloc}, val);
                }
            }
        }
        break :#{@current_pipe_label} res_list;
      ZIG
    end
  end

  BATCH_WINDOW_TIME_NS = { 'ms' => 1_000_000, 's' => 1_000_000_000, 'min' => 60_000_000_000, 'h' => 3_600_000_000_000 }.freeze

  sig { params(bw_node: T.untyped).returns(String) }
  def batch_window_timeout_ns(bw_node)
    T.bind(self, T.untyped) rescue nil
    return "0" unless bw_node.options["time"]
    str = bw_node.options["time"].value
    m = /\A(\d+(?:\.\d+)?)(ms|s|min|h)\z/.match(str)
    return "0" unless m
    (m[1].to_f * BATCH_WINDOW_TIME_NS[m[2]]).to_i.to_s
  end

  sig { params(lhs: T.untyped, bw_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_batch_window(lhs, bw_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    @bw_counter = (@bw_counter || 0) + 1
    id = @bw_counter

    lhs_type = lhs.type_info
    expr_type_str = (bw_node.expression.full_type || bw_node.expression.resolved_type).to_s

    is_open    = lhs_type&.open_stream? || lhs_type&.dynamic_stream?
    is_inf     = lhs_type&.inf_stream?
    is_bounded = lhs_type&.bounded_stream?
    is_stream  = is_open || is_inf

    elem_type = if is_open
      lhs_type.open_stream_element_type.resolved
    elsif is_inf
      lhs_type.inf_stream_element_type.resolved
    elsif is_bounded
      lhs_type.stream_element_type.resolved
    else
      lhs_type.element_type.resolved
    end

    elem_zig = transpile_type(elem_type.to_s)

    size_code  = bw_node.options["size"] ? "@intCast(#{visit(bw_node.options['size'])})" : "0"
    timeout_ns = batch_window_timeout_ns(bw_node)

    placeholder = "__bw#{id}_batch"
    expr_code = with_pipeline_context(placeholder: placeholder) { visit(bw_node.expression) }

    batch_emit = ->(alloc_str) {
      <<~ZIG.strip
        if (try __bw#{id}.push(__bw#{id}_item)) |__bw#{id}_slice| {
            defer __bw#{id}.freeBatch(__bw#{id}_slice);
            var #{placeholder} = std.ArrayListUnmanaged(#{elem_zig}){ .items = __bw#{id}_slice, .capacity = __bw#{id}_slice.len };
            _ = &#{placeholder};
            const __bwval#{id} = #{expr_code};
            try res_list.append(#{alloc_str}, __bwval#{id});
        }
      ZIG
    }
    flush_emit = ->(alloc_str) {
      <<~ZIG.strip
        if (try __bw#{id}.flush()) |__bw#{id}_slice| {
            defer __bw#{id}.freeBatch(__bw#{id}_slice);
            var #{placeholder} = std.ArrayListUnmanaged(#{elem_zig}){ .items = __bw#{id}_slice, .capacity = __bw#{id}_slice.len };
            _ = &#{placeholder};
            const __bwval#{id} = #{expr_code};
            try res_list.append(#{alloc_str}, __bwval#{id});
        }
      ZIG
    }

    if is_stream
      alloc_str = "rt.heapAlloc()"
      label = next_pipe_label
      @current_pipe_label = label
      pop_method = is_inf ? "nextOrNull" : "next"
      stream_code = visit(lhs)
      source_name, setup =
        if lhs.is_a?(AST::Identifier)
          [stream_code, ""]
        else
          ["__bw#{id}_src", "var __bw#{id}_src = #{stream_code};\n    _ = &__bw#{id}_src;\n    "]
        end

      <<~ZIG
        #{label}: {
            #{setup}var res_list = try CheatLib.makeList(#{transpile_type(expr_type_str)}, #{alloc_str}, &.{});
            {
                var __bw#{id} = CheatLib.BatchWindow(#{elem_zig}).init(#{alloc_str}, #{size_code}, #{timeout_ns});
                defer __bw#{id}.deinit();
                while (try #{source_name}.#{pop_method}()) |__bw#{id}_item| {
                    #{batch_emit.(alloc_str)}
                }
                #{flush_emit.(alloc_str)}
            }
            break :#{label} res_list;
        }
      ZIG
    elsif is_bounded
      alloc_str = "rt.heapAlloc()"
      label = next_pipe_label
      @current_pipe_label = label
      src_code = visit(lhs)

      <<~ZIG
        #{label}: {
            const __bw#{id}_bsrc = #{src_code};
            var res_list = try CheatLib.makeList(#{transpile_type(expr_type_str)}, #{alloc_str}, &.{});
            {
                var __bw#{id} = CheatLib.BatchWindow(#{elem_zig}).init(#{alloc_str}, #{size_code}, #{timeout_ns});
                defer __bw#{id}.deinit();
                for (__bw#{id}_bsrc.items) |__bw#{id}_item| {
                    #{batch_emit.(alloc_str)}
                }
                #{flush_emit.(alloc_str)}
            }
            break :#{label} res_list;
        }
      ZIG
    else
      transpile_pipeline_macro(lhs, smooth_node, res_type: expr_type_str) do |alloc_str|
        <<~ZIG
          {
              var __bw#{id} = CheatLib.BatchWindow(#{elem_zig}).init(#{alloc_str}, #{size_code}, #{timeout_ns});
              defer __bw#{id}.deinit();
              for (pipe_items) |__bw#{id}_item| {
                  #{batch_emit.(alloc_str)}
              }
              #{flush_emit.(alloc_str)}
          }
          break :#{@current_pipe_label} res_list;
        ZIG
      end
    end
  end

  def transpile_join(list_node, join_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    left_zig  = transpile_type(list_node.full_type.element_type.resolved.to_s)
    right_src = visit(join_node.right_source)
    right_type_info = join_node.right_source.type_info
    right_zig = transpile_type(right_type_info.element_type.resolved.to_s)

    key_expr = join_node.key_expr
    is_lambda = key_expr.is_a?(AST::LambdaLit)

    if is_lambda
      # Lambda: %(a, b) -> predicate
      params = key_expr.params
      left_param  = params[0].is_a?(Hash) ? params[0][:name] : params[0].name
      right_param = params[1].is_a?(Hash) ? params[1][:name] : params[1].name
      # Map lambda param names to the Zig loop variables via @join_param_map.
      # The transpiler's Identifier visitor checks this map.
      old_join_map = @join_param_map
      @join_param_map = { left_param => "__jl", right_param => "__jr" }
      pred_code = visit(key_expr.body)
      @join_param_map = old_join_map
    else
      # Shared key: _.field applied to both
      left_key  = with_pipeline_context(placeholder: "__jl") { visit(key_expr) }
      right_key = with_pipeline_context(placeholder: "__jr") { visit(key_expr) }
      pred_code = "CheatLib.eql(#{left_key}, #{right_key})"
    end

    result_zig = "struct { left: #{left_zig}, right: ?#{right_zig} }"
    my_label = next_pipe_label

    left_code = visit(list_node)
    @current_pipe_label = my_label

    right_items = if right_type_info&.list_collection?
      "if (@hasField(@TypeOf(__jr_src), \"items\")) __jr_src.items else __jr_src[0..]"
    else
      "if (@hasField(@TypeOf(__jr_src), \"items\")) __jr_src.items else __jr_src[0..]"
    end

    left_items = "if (@hasField(@TypeOf(__jl_src), \"items\")) __jl_src.items else __jl_src[0..]"

    <<~ZIG
      #{my_label}: {
          const __jl_src = #{left_code};
          const __jr_src = #{right_src};
          const __jl_items = #{left_items};
          const __jr_items = #{right_items};
          var res_list = try CheatLib.makeList(#{result_zig}, rt.frameAlloc(), &.{});
          for (__jl_items) |__jl| {
              var __match: ?#{right_zig} = null;
              for (__jr_items) |__jr| {
                  if (#{pred_code}) {
                      __match = __jr;
                      break;
                  }
              }
              try res_list.append(rt.frameAlloc(), .{ .left = __jl, .right = __match });
          }
          break :#{my_label} res_list;
      }
    ZIG
  end

  def transpile_index_grouping(list_node, expression_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    element_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)

    expr_code = with_pipeline_context(placeholder: "it") { visit(expression_node) }

    init = "var idx_result: CheatLib.StringMap(std.ArrayListUnmanaged(#{element_zig_type})) = .{ .alloc = rt.frameAlloc() };"

    transpile_pipeline_macro(list_node, smooth_node, init: init, force_aos: true) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const idx_key = #{expr_code};
            const idx_key_owned = try #{alloc}.dupe(u8, idx_key);
            const gop = idx_result.inner.getOrPut(#{alloc}, idx_key_owned) catch @panic("INDEX allocation failed");
            if (gop.found_existing) #{alloc}.free(idx_key_owned);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            gop.value_ptr.append(#{alloc}, it) catch @panic("INDEX append failed");
        }
        break :#{@current_pipe_label} idx_result;
      ZIG
    end
  end

  def transpile_reduce(list_node, reduce_node)
    T.bind(self, T.untyped) rescue nil
    acc_type = transpile_type(reduce_node.full_type)
    initial_code = visit(reduce_node.initial_value)

    expr_code = with_pipeline_context(placeholder: "it", acc: "acc") { visit(reduce_node.expression) }

    init = "var acc: #{acc_type} = #{initial_code};"

    transpile_pipeline_macro(list_node, reduce_node, init: init, force_aos: true) do
      <<~ZIG
        for (pipe_items) |it| {
            acc = #{expr_code};
        }
        break :#{@current_pipe_label} acc;
      ZIG
    end
  end

  def transpile_order_by(list_node, order_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    element_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)

    key_expr_a = with_pipeline_context(placeholder: "a") { visit(order_node.expression) }
    key_expr_b = with_pipeline_context(placeholder: "b") { visit(order_node.expression) }

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

        break :#{@current_pipe_label} ord_result;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, limit_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_limit(list_node, limit_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    element_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)
    count_code = visit(limit_node.count)

    transpile_pipeline_macro(list_node, smooth_node, force_aos: true) do |alloc|
      <<~ZIG
        // Calculate actual count (min of requested and available)
        const lim_requested: usize = @intCast(#{count_code});
        const lim_actual = @min(lim_requested, pipe_items.len);

        // Create new list with limited items
        break :#{@current_pipe_label} try CheatLib.makeList(#{element_zig_type}, #{alloc}, pipe_items[0..lim_actual]);
      ZIG
    end
  end

  sig { params(list_node: T.untyped, skip_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_skip(list_node, skip_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    count_code = visit(skip_node.count)
    my_label = next_pipe_label
    list_code = visit(list_node)
    @current_pipe_label = my_label

    <<~ZIG
      #{my_label}: {
          const __skip_src = #{list_code};
          const __skip_items = if (@hasField(@TypeOf(__skip_src), "items")) __skip_src.items else __skip_src[0..];
          const skip_requested: usize = @intCast(#{count_code});
          const skip_actual = @min(skip_requested, __skip_items.len);
          break :#{my_label} __skip_items[skip_actual..];
      }
    ZIG
  end

  # TAP: side-effect observer — iterates collection, runs body, returns original.
  # Unlike EACH (which returns void), TAP passes the collection through.
  def transpile_tap(smooth_node)
    T.bind(self, T.untyped) rescue nil
    lhs     = smooth_node.left
    tap_op  = smooth_node.right
    my_label = next_pipe_label

    body_code = with_pipeline_context(placeholder: "__tap_item") do
      tap_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n        ")
    end

    list_code = visit(lhs)
    <<~ZIG.chomp
      #{my_label}: {
          const __tap_src = #{list_code};
          const __tap_items = if (@hasField(@TypeOf(__tap_src), "items")) __tap_src.items else __tap_src[0..];
          for (__tap_items) |__tap_item| {
              #{body_code}
          }
          break :#{my_label} __tap_src;
      }
    ZIG
  end

  def transpile_unnest(list_node, unnest_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    inner_element_type = unnest_node.full_type.element_type.resolved.to_s
    inner_zig_type = transpile_type(inner_element_type)

    expr_code = with_pipeline_context(placeholder: "it") { visit(unnest_node.expression) }

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
        break :#{@current_pipe_label} res_list;
      ZIG
    end
  end

  def transpile_distinct(list_node, distinct_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    element_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)

    expr_code = with_pipeline_context(placeholder: "it") { visit(distinct_node.expression) }
    expr_code_inner = with_pipeline_context(placeholder: "it2") { visit(distinct_node.expression) }

    transpile_pipeline_macro(list_node, smooth_node, res_type: list_node.full_type.element_type.resolved.to_s, force_aos: true) do |alloc|
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
        break :#{@current_pipe_label} res_list;
      ZIG
    end
  end

  # Transpile `collection |> EACH _.expr` — side-effect iteration.
  # Dispatches to the appropriate implementation based on the source type:
  #   - Regular array/list → sequential for loop
  #   - Plain pool         → sequential live-slot scan
  #   - Sharded pool       → N parallel fibers (one per shard, DO-block pattern)
  sig { params(smooth_node: T.untyped).returns(String) }
  def transpile_each(smooth_node)
    T.bind(self, T.untyped) rescue nil
    lhs      = smooth_node.left
    each_op  = smooth_node.right
    lhs_type = lhs.type_info
    is_soa   = lhs_type&.soa? && (lhs_type&.pool? || lhs_type&.list_collection? || lhs_type&.fixed_soa?)

    if is_soa
      # SOA EACH: enable field-slice rewrite so _.field reads/writes become
      # __soa_field[__soa_i] instead of materializing the full struct.
      prev_soa_active = @soa_rewrite_active
      prev_soa_fields = @soa_needed_fields
      @soa_rewrite_active = true
      @soa_needed_fields = Set.new
    end

    placeholder = is_soa ? "_" : "__each_item"
    body_code = with_pipeline_context(placeholder: placeholder) do
      each_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n        ")
    end

    if lhs_type&.dynamic_stream? || lhs_type&.open_stream?
      stream_code = visit(lhs)
      source_name, setup =
        if lhs.is_a?(AST::Identifier)
          [stream_code, ""]
        else
          ["__each_src", "var __each_src = #{stream_code};\n      _ = &__each_src;\n"]
        end

      if is_soa
        @soa_rewrite_active = prev_soa_active
        @soa_needed_fields  = prev_soa_fields
      end

      return <<~ZIG.chomp
        {
            #{setup}while (try #{source_name}.next()) |__each_item| {
                #{body_code}
            }
        }
      ZIG
    end

    result = if lhs_type&.pool?
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
    elsif lhs_type&.fixed_soa?
      transpile_each_soa_list(lhs, body_code)
    elsif lhs_type&.set_collection?
      transpile_each_set(lhs, body_code)
    else
      raise "BUG: plain-array EACH should have been rewritten by PipelineRewriter"
    end

    if is_soa
      @soa_rewrite_active = prev_soa_active
      @soa_needed_fields  = prev_soa_fields
    end

    result
  end

  def transpile_each_pool(pool_node, body_code)
    T.bind(self, T.untyped) rescue nil
    pool_code = visit(pool_node)
    <<~ZIG.chomp
      {
          const __each_src = &#{pool_code};
          for (__each_src.slots) |*__each_slot| {
              if (!__each_slot.alive) continue;
              const __each_item = &__each_slot.value;
              #{body_code}
          }
      }
    ZIG
  end

  def transpile_each_set(set_node, body_code)
    T.bind(self, T.untyped) rescue nil
    set_code = visit(set_node)
    <<~ZIG.chomp
      {
          const __each_src = &#{set_code};
          var __each_iter = __each_src.keyIterator();
          while (__each_iter.next()) |__each_kptr| {
              const __each_item = __each_kptr.*;
              #{body_code}
          }
      }
    ZIG
  end

  def transpile_each_soa_list(list_node, body_code)
    T.bind(self, T.untyped) rescue nil
    list_code = visit(list_node)
    field_slices = @soa_needed_fields.map { |f|
      "const __soa_#{f} = __soa_src.data.items(.#{f});"
    }.join("\n          ")
    <<~ZIG.chomp
      {
          const __soa_src = &#{list_code};
          #{field_slices}
          for (0..@intCast(__soa_src.data.len)) |__soa_i| {
              #{body_code}
          }
      }
    ZIG
  end

  def transpile_each_soa_pool(pool_node, body_code)
    T.bind(self, T.untyped) rescue nil
    pool_code = visit(pool_node)
    field_slices = @soa_needed_fields.map { |f|
      "const __soa_#{f} = __soa_src.data.items(.#{f});"
    }.join("\n          ")
    <<~ZIG.chomp
      {
          const __soa_src = &#{pool_code};
          #{field_slices}
          for (0..@intCast(__soa_src.data.len)) |__soa_i| {
              if (!__soa_src.alive[__soa_i]) continue;
              #{body_code}
          }
      }
    ZIG
  end

  sig { params(pool_node: T.untyped, body_code: T.untyped, pool_type: T.untyped).returns(String) }
  def transpile_each_sharded_pool(pool_node, body_code, pool_type)
    T.bind(self, T.untyped) rescue nil
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
        "for (ctx.shard.slots) |*__each_slot| {\n            if (!__each_slot.alive) continue;\n            const __each_item = &__each_slot.value;\n            #{body_code}\n        }"
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
  sig { params(list_node: T.untyped, body_code: T.untyped, list_type: T.untyped).returns(String) }
  def transpile_each_sharded_list(list_node, body_code, list_type)
    T.bind(self, T.untyped) rescue nil
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
    T.bind(self, T.untyped) rescue nil
    raise "transpile_find: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
    elem_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)
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
        break :#{@current_pipe_label} if (find_found) @as(?#{elem_zig_type}, find_result) else null;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, any_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_any(list_node, any_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    raise "transpile_any: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
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
        break :#{@current_pipe_label} any_result;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, all_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_all(list_node, all_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    raise "transpile_all: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
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
        break :#{@current_pipe_label} all_result;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, count_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_count(list_node, count_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    raise "transpile_count: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
    expr_code = visit_pipeline_expr(list_node, count_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var count_result: i64 = 0;
        for (pipe_items) |it| {
            if (#{expr_code}) {
                count_result += 1;
            }
        }
        break :#{@current_pipe_label} count_result;
      ZIG
    end
  end

  # =========================================================
  # Phase 4: Numeric Aggregation Operators
  # =========================================================

  # Returns [min_sentinel, max_sentinel] for a given Zig numeric type.
  # min_sentinel is the initial value for a MIN accumulator (highest possible).
  # max_sentinel is the initial value for a MAX accumulator (lowest possible).
  sig { params(zig_t: T.untyped, resolved_sym: T.untyped).returns(Array) }
  def agg_minmax_sentinels(zig_t, resolved_sym)
    T.bind(self, T.untyped) rescue nil
    if [:Float32, :Float64].include?(resolved_sym)
      ["std.math.floatMax(#{zig_t})", "-std.math.floatMax(#{zig_t})"]
    elsif [:Int8, :Int16, :Int32, :Int64].include?(resolved_sym)
      ["std.math.maxInt(#{zig_t})", "std.math.minInt(#{zig_t})"]
    elsif [:UInt8, :Byte, :UInt16, :UInt32, :UInt64].include?(resolved_sym)
      ["std.math.maxInt(#{zig_t})", "0"]
    else
      ["std.math.floatMax(f64)", "-std.math.floatMax(f64)"]
    end
  end

  sig { params(list_node: T.untyped, sum_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_sum(list_node, sum_node, smooth_node)
    # M8: observable destinations always route through
    # lower_range_fold_observable_default (the producer-fiber-spawn
    # path) before this fallback fires. The previous early return to
    # `transpile_observable_sum` (a synchronous collect-then-fold
    # variant from before producer-spawn landed) is unreachable today
    # and was removed; if a future change re-routes an observable
    # source through `pipe_items`, the assertion below will catch it.
    T.bind(self, T.untyped) rescue nil
    raise "transpile_sum: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest

    expr_code = visit_pipeline_expr(list_node, sum_node.expression)
    acc_type  = transpile_type(smooth_node.full_type.to_s)  # already upsized by pipe_analysis

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var sum_result: #{acc_type} = 0;
        for (pipe_items) |it| {
            sum_result += #{expr_code};
        }
        break :#{@current_pipe_label} sum_result;
      ZIG
    end
  end

  # A13: every pipe-terminal transpile_* should reject observable_dest
  # at this fallback path. Observables route through
  # lower_range_fold_observable_default before the pipe_items materializer
  # below ever runs. A future regression that leaks an observable into
  # the legacy collect-then-fold path would silently miscompile -- no
  # producer fiber, no WaitGroup, no atomic accumulator -- so we want
  # a loud assertion instead. Mirrors the guard added to transpile_sum
  # in M8.
  OBS_DEST_GUARD_MSG = "observable_dest unexpected here -- should route through lower_range_fold_observable_default"

  sig { params(list_node: T.untyped, avg_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_average(list_node, avg_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    raise "transpile_average: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
    expr_code = visit_pipeline_expr(list_node, avg_node.expression)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        var avg_sum: f64 = 0;
        const avg_count = pipe_items.len;
        for (pipe_items) |it| {
            avg_sum += #{expr_code};
        }
        break :#{@current_pipe_label} if (avg_count == 0) @as(f64, 0) else avg_sum / @as(f64, @floatFromInt(avg_count));
      ZIG
    end
  end

  sig { params(list_node: T.untyped, min_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_min(list_node, min_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    raise "transpile_min: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
    expr_code = visit_pipeline_expr(list_node, min_node.expression)
    expr_sym  = smooth_node.full_type.resolved  # exact type set by pipe_analysis
    acc_type  = transpile_type(smooth_node.full_type.to_s)
    min_init, _max_init = agg_minmax_sentinels(acc_type, expr_sym)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        if (pipe_items.len == 0) @panic("MIN applied to empty list");
        var min_result: #{acc_type} = #{min_init};
        for (pipe_items) |it| {
            const min_val = #{expr_code};
            if (min_val < min_result) min_result = min_val;
        }
        break :#{@current_pipe_label} min_result;
      ZIG
    end
  end

  sig { params(list_node: T.untyped, max_node: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_max(list_node, max_node, smooth_node)
    T.bind(self, T.untyped) rescue nil
    raise "transpile_max: #{OBS_DEST_GUARD_MSG}" if smooth_node.observable_dest
    expr_code = visit_pipeline_expr(list_node, max_node.expression)
    expr_sym  = smooth_node.full_type.resolved  # exact type set by pipe_analysis
    acc_type  = transpile_type(smooth_node.full_type.to_s)
    _min_init, max_init = agg_minmax_sentinels(acc_type, expr_sym)

    transpile_pipeline_macro(list_node, smooth_node) do
      <<~ZIG
        if (pipe_items.len == 0) @panic("MAX applied to empty list");
        var max_result: #{acc_type} = #{max_init};
        for (pipe_items) |it| {
            const max_val = #{expr_code};
            if (max_val > max_result) max_result = max_val;
        }
        break :#{@current_pipe_label} max_result;
      ZIG
    end
  end

  # =========================================================
  # CONCURRENT modifier: parallel SELECT, WHERE, EACH
  # =========================================================

  sig { params(smooth_node: T.untyped).returns(T.untyped) }
  def transpile_concurrent(smooth_node)
    T.bind(self, T.untyped) rescue nil
    lhs     = smooth_node.left
    conc    = smooth_node.right   # ConcurrentOp
    inner   = conc.op
    options = conc.options

    @conc_counter ||= 0
    id = @conc_counter
    @conc_counter += 1

    workers_code = options["workers"] ? visit(options["workers"]) : "CheatLib.threadCount()"
    capacity_code = options["capacity"] ? visit(options["capacity"]) : nil
    rt_name = @do_rt_name || "rt"
    lhs_type = lhs.type_info

    if lhs_type&.bounded_stream?
      case inner
      when AST::SelectOp
        return transpile_concurrent_bounded_select(lhs, inner, id, workers_code, rt_name, options)
      when AST::WhereOp
        return transpile_concurrent_bounded_where(lhs, inner, id, workers_code, rt_name, options)
      when AST::EachOp
        return transpile_concurrent_bounded_each(lhs, inner, id, workers_code, rt_name, options)
      end
    end

    if lhs_type&.inf_stream? || lhs_type&.dynamic_stream? || lhs_type&.open_stream? || lhs.is_a?(AST::RangeLit)
      case inner
      when AST::SelectOp
        return transpile_concurrent_stream_select(lhs, inner, id, workers_code, capacity_code, rt_name, options)
      when AST::WhereOp
        return transpile_concurrent_stream_where(lhs, inner, id, workers_code, capacity_code, rt_name, options)
      when AST::EachOp
        return transpile_concurrent_stream_each(lhs, inner, conc, id, workers_code, capacity_code, rt_name, options)
      end
    end

    case inner
    when AST::SelectOp
      transpile_concurrent_select(lhs, inner, id, workers_code, rt_name, options)
    when AST::WhereOp
      transpile_concurrent_where(lhs, inner, id, workers_code, rt_name, options)
    when AST::EachOp
      # SHARD + CONCURRENT EACH lowers structurally via
      # PipelineHost#lower_shard_concurrent_each -- never falls back here.
      transpile_concurrent_each(lhs, inner, id, workers_code, rt_name, options)
    when AST::SumOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :sum, smooth_node)
    when AST::CountOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :count, smooth_node)
    when AST::MinOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :min, smooth_node)
    when AST::MaxOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :max, smooth_node)
    when AST::AverageOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :average, smooth_node)
    end
  end

  def bounded_stream_source_setup(list_node, id)
    T.bind(self, T.untyped) rescue nil
    if list_node.is_a?(AST::Identifier) && list_node.type_info&.bounded_stream?
      source_name = visit(list_node)
      {
        stream_setup: "const __cbs#{id}_items = &#{source_name}.items;",
        items_ref: "__cbs#{id}_items"
      }
    else
      source_code = visit(list_node)
      {
        stream_setup: "var __cbs#{id}_stream = #{source_code};\n      _ = &__cbs#{id}_stream;\n      const __cbs#{id}_items = &__cbs#{id}_stream.items;",
        items_ref: "__cbs#{id}_items"
      }
    end
  end

  def transpile_concurrent_bounded_select(stream_node, select_op, id, workers_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(select_op.expression)

    stream_ti = stream_node.type_info
    n = stream_ti.stream_capacity
    item_zig = transpile_type(stream_ti.stream_element_type.resolved)
    promise_zig = "CheatLib.Promise(#{item_zig})"
    result_zig = transpile_type(select_op.expression.full_type)
    source = bounded_stream_source_setup(stream_node, id)

    inner_code = with_pipeline_context(placeholder: "__stream_item") do
      with_fiber_capture_map({}) { visit(inner_expr) }
    end
    bare_code = inner_code.sub(/^try /, '')

    err_field    = policy == :raise ? "\n              err:    *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err    = &__ccbs#{id}_err," : ""
    err_decl     = policy == :raise ? "\n      var __ccbs#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check    = policy == :raise ? "\n      const __ccbs#{id}_err_code = __ccbs#{id}_err.load(.seq_cst);\n      if (__ccbs#{id}_err_code != 0) return @errorFromInt(__ccbs#{id}_err_code);" : ""

    result_body = case policy
    when :prune
      "const __cv = #{bare_code} catch continue;\n                  ctx.results[__idx] = __cv;"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                      _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                      continue;\n                  };\n                  ctx.results[__idx] = __cv;"
    else
      "ctx.results[__idx] = #{inner_code};"
    end

    spawn_call = concurrent_spawn_call(options, "__ccbs#{id}_wg", "__CcbsWorker#{id}", "__ccbs#{id}_workers[__w]")

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          #{source[:stream_setup]}
          const __ccbs#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{result_zig}, #{n});
          defer #{rt_name}.heapAlloc().free(__ccbs#{id}_results);
          for (__ccbs#{id}_results) |*__s| __s.* = null;#{err_decl}
          var __ccbs#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccbs#{id}_n_workers: usize = @intCast(#{workers_code});
          const __CcbsWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   *[#{n}]#{promise_zig},
              results: []?#{result_zig},
              next:    *std.atomic.Value(usize),#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= #{n}) break;
                      const __stream_item = try ctx.items[__idx].next();
                      #{result_body}
                      __rt.checkYield();
                  }
              }
          };
          var __ccbs#{id}_next = std.atomic.Value(usize).init(0);
          var __ccbs#{id}_workers: [64]__CcbsWorker#{id} = undefined;
          const __ccbs#{id}_actual_workers: usize = @min(__ccbs#{id}_n_workers, 64);
          __ccbs#{id}_wg.add(__ccbs#{id}_actual_workers);
          for (0..__ccbs#{id}_actual_workers) |__w| {
              __ccbs#{id}_workers[__w] = .{
                  .wg      = &__ccbs#{id}_wg,
                  .items   = #{source[:items_ref]},
                  .results = __ccbs#{id}_results,
                  .next    = &__ccbs#{id}_next,#{err_ctx_init}
              };
              #{spawn_call}
          }
          __ccbs#{id}_wg.wait();#{err_check}
          var __ccbs#{id}_final = std.ArrayListUnmanaged(#{result_zig}).empty;
          for (__ccbs#{id}_results) |__ccbs#{id}_slot| {
              if (__ccbs#{id}_slot) |__v| try __ccbs#{id}_final.append(#{rt_name}.heapAlloc(), __v);
          }
          break :#{@current_pipe_label} __ccbs#{id}_final;
      }
    ZIG
  end

  def transpile_concurrent_bounded_where(stream_node, where_op, id, workers_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(where_op.expression)

    stream_ti = stream_node.type_info
    n = stream_ti.stream_capacity
    item_zig = transpile_type(stream_ti.stream_element_type.resolved)
    promise_zig = "CheatLib.Promise(#{item_zig})"
    source = bounded_stream_source_setup(stream_node, id)

    inner_code = with_pipeline_context(placeholder: "__stream_item") do
      with_fiber_capture_map({}) { visit(inner_expr) }
    end
    bare_code = inner_code.sub(/^try /, '')

    err_field    = policy == :raise ? "\n              err:    *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err    = &__ccbw#{id}_err," : ""
    err_decl     = policy == :raise ? "\n      var __ccbw#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check    = policy == :raise ? "\n      const __ccbw#{id}_err_code = __ccbw#{id}_err.load(.seq_cst);\n      if (__ccbw#{id}_err_code != 0) return @errorFromInt(__ccbw#{id}_err_code);" : ""

    pred_body = case policy
    when :prune
      "const __cv = #{bare_code} catch continue;\n                  if (__cv) ctx.results[__idx] = __stream_item;"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                      _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                      continue;\n                  };\n                  if (__cv) ctx.results[__idx] = __stream_item;"
    else
      "if (#{inner_code}) ctx.results[__idx] = __stream_item;"
    end

    spawn_call = concurrent_spawn_call(options, "__ccbw#{id}_wg", "__CcbwWorker#{id}", "__ccbw#{id}_workers[__w]")

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          #{source[:stream_setup]}
          const __ccbw#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{item_zig}, #{n});
          defer #{rt_name}.heapAlloc().free(__ccbw#{id}_results);
          for (__ccbw#{id}_results) |*__s| __s.* = null;#{err_decl}
          var __ccbw#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccbw#{id}_n_workers: usize = @intCast(#{workers_code});
          const __CcbwWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   *[#{n}]#{promise_zig},
              results: []?#{item_zig},
              next:    *std.atomic.Value(usize),#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= #{n}) break;
                      const __stream_item = try ctx.items[__idx].next();
                      #{pred_body}
                      __rt.checkYield();
                  }
              }
          };
          var __ccbw#{id}_next = std.atomic.Value(usize).init(0);
          var __ccbw#{id}_workers: [64]__CcbwWorker#{id} = undefined;
          const __ccbw#{id}_actual_workers: usize = @min(__ccbw#{id}_n_workers, 64);
          __ccbw#{id}_wg.add(__ccbw#{id}_actual_workers);
          for (0..__ccbw#{id}_actual_workers) |__w| {
              __ccbw#{id}_workers[__w] = .{
                  .wg      = &__ccbw#{id}_wg,
                  .items   = #{source[:items_ref]},
                  .results = __ccbw#{id}_results,
                  .next    = &__ccbw#{id}_next,#{err_ctx_init}
              };
              #{spawn_call}
          }
          __ccbw#{id}_wg.wait();#{err_check}
          var __ccbw#{id}_final = std.ArrayListUnmanaged(#{item_zig}).empty;
          for (__ccbw#{id}_results) |__ccbw#{id}_slot| {
              if (__ccbw#{id}_slot) |__v| try __ccbw#{id}_final.append(#{rt_name}.heapAlloc(), __v);
          }
          break :#{@current_pipe_label} __ccbw#{id}_final;
      }
    ZIG
  end

  def transpile_concurrent_bounded_each(stream_node, each_op, id, workers_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    stream_ti = stream_node.type_info
    n = stream_ti.stream_capacity
    item_zig = transpile_type(stream_ti.stream_element_type.resolved)
    promise_zig = "CheatLib.Promise(#{item_zig})"
    source = bounded_stream_source_setup(stream_node, id)

    body_code = with_pipeline_context(placeholder: "__each_item") do
      with_fiber_capture_map({}) do
        each_op.body.map { |stmt|
          code = visit(stmt)
          code.strip.end_with?(";") ? code : "#{code};"
        }.join("\n                  ")
      end
    end

    spawn_call = concurrent_spawn_call(options, "__ccbe#{id}_wg", "__CcbeWorker#{id}", "__ccbe#{id}_workers[__w]")

    <<~ZIG.chomp
      {
          #{source[:stream_setup]}
          var __ccbe#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccbe#{id}_n_workers: usize = @intCast(#{workers_code});
          const __CcbeWorker#{id} = struct {
              wg:    *CheatHeader.WaitGroup,
              items: *[#{n}]#{promise_zig},
              next:  *std.atomic.Value(usize),
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= #{n}) break;
                      var __each_item = try ctx.items[__idx].next();
                      #{body_code}
                      __rt.checkYield();
                  }
              }
          };
          var __ccbe#{id}_next = std.atomic.Value(usize).init(0);
          var __ccbe#{id}_workers: [64]__CcbeWorker#{id} = undefined;
          const __ccbe#{id}_actual_workers: usize = @min(__ccbe#{id}_n_workers, 64);
          __ccbe#{id}_wg.add(__ccbe#{id}_actual_workers);
          for (0..__ccbe#{id}_actual_workers) |__w| {
              __ccbe#{id}_workers[__w] = .{
                  .wg    = &__ccbe#{id}_wg,
                  .items = #{source[:items_ref]},
                  .next  = &__ccbe#{id}_next,
              };
              #{spawn_call}
          }
          __ccbe#{id}_wg.wait();
      }
    ZIG
  end

  # Build source setup for stream concurrent ops (dynamic or InfStream).
  # Returns { setup, src_name } where src_name is the Zig expression to take &src_name.
  # For identifier sources no temp var is needed; for expressions one is created.
  def stream_concurrent_source_setup(stream_node, id)
    T.bind(self, T.untyped) rescue nil
    source_code = visit(stream_node)
    if stream_node.is_a?(AST::Identifier)
      { setup: "", src_name: source_code }
    else
      tmp = "__cis#{id}_src"
      { setup: "var #{tmp} = #{source_code};\n          _ = &#{tmp};", src_name: tmp }
    end
  end

  # CONCURRENT SELECT on ~T[] / ~T[INF]: BoundedChannel feeder + N worker fibers.
  # Workers each maintain a local result list; merged after wg.wait().
  # Result order is non-deterministic (work-stealing).
  def transpile_concurrent_stream_select(stream_node, select_op, id, workers_code, capacity_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(select_op.expression)

    stream_ti = stream_node.type_info
    is_inf  = stream_ti&.inf_stream?
    is_open = stream_ti&.open_stream?
    item_zig = transpile_type(
      if is_inf then stream_ti.inf_stream_element_type.resolved
      elsif is_open then stream_ti.open_stream_element_type.resolved
      else stream_ti.tense_type.element_type.resolved
      end)
    result_zig = transpile_type(select_op.expression.full_type)
    pop_method = is_inf ? "nextOrNull" : "next"
    source     = stream_concurrent_source_setup(stream_node, id)

    inner_code = with_pipeline_context(placeholder: "__stream_item") do
      with_fiber_capture_map({}) { visit(inner_expr) }
    end
    bare_code = inner_code.sub(/^try /, '')

    err_field    = policy == :raise ? "\n              err:   *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err   = &__cis#{id}_err," : ""
    err_decl     = policy == :raise ? "\n          var __cis#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check    = policy == :raise ? "\n          const __cis#{id}_ec = __cis#{id}_err.load(.seq_cst);\n          if (__cis#{id}_ec != 0) return @errorFromInt(__cis#{id}_ec);" : ""

    result_body = case policy
    when :prune
      "const __cv = #{bare_code} catch continue;\n                  try ctx.local.append(ctx.alloc, __cv);"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                      _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                      continue;\n                  };\n                  try ctx.local.append(ctx.alloc, __cv);"
    else
      "try ctx.local.append(ctx.alloc, #{inner_code});"
    end

    feeder_spawn = "try __cis#{id}_wg.sched.submitSpawn(\n              @intFromPtr(&Runtime.entryWrapper),\n              @as(CheatHeader.TaskFn, @ptrCast(&__CisFeeder#{id}.run)),\n              &__cis#{id}_feeder, .{},\n          );"
    worker_spawn = concurrent_spawn_call(options, "__cis#{id}_wg", "__CisWorker#{id}", "__cis#{id}_workers[__w]")
    cap_zig = capacity_code ? "@intCast(#{capacity_code})" : "blk: { var c: usize = 4; while (c < __cis#{id}_n_workers * 4) : (c <<= 1) {} break :blk @min(c, 64); }"

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          #{source[:setup].empty? ? "" : source[:setup] + "\n          "}const __cis#{id}_n_workers: usize = @intCast(#{workers_code});
          const __cis#{id}_cap: usize = #{cap_zig};
          var __cis#{id}_chan = try CheatLib.BoundedChannel(#{item_zig}).init(#{rt_name}.heapAlloc(), __cis#{id}_cap);
          defer __cis#{id}_chan.deinit();
          var __cis#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());#{err_decl}
          const __CisFeeder#{id} = struct {
              wg:   *CheatHeader.WaitGroup,
              src:  *@TypeOf(#{source[:src_name]}),
              chan: *CheatLib.BoundedChannel(#{item_zig}),
              fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  defer ctx.chan.close();
                  while (try ctx.src.#{pop_method}()) |__stream_item| {
                      try ctx.chan.push(__stream_item);
                  }
              }
          };
          const __CisWorker#{id} = struct {
              wg:    *CheatHeader.WaitGroup,
              chan:  *CheatLib.BoundedChannel(#{item_zig}),
              local: std.ArrayListUnmanaged(#{result_zig}),
              alloc: std.mem.Allocator,#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (try ctx.chan.pop()) |__stream_item| {
                      #{result_body}
                      __rt.checkYield();
                  }
              }
          };
          var __cis#{id}_feeder = __CisFeeder#{id}{ .wg = &__cis#{id}_wg, .src = &#{source[:src_name]}, .chan = &__cis#{id}_chan };
          var __cis#{id}_workers: [64]__CisWorker#{id} = undefined;
          const __cis#{id}_actual_workers: usize = @min(__cis#{id}_n_workers, 64);
          __cis#{id}_wg.add(1 + __cis#{id}_actual_workers);
          #{feeder_spawn}
          for (0..__cis#{id}_actual_workers) |__w| {
              __cis#{id}_workers[__w] = .{ .wg = &__cis#{id}_wg, .chan = &__cis#{id}_chan, .local = .empty, .alloc = #{rt_name}.heapAlloc()#{err_ctx_init} };
              #{worker_spawn}
          }
          __cis#{id}_wg.wait();#{err_check}
          var __cis#{id}_final = std.ArrayListUnmanaged(#{result_zig}).empty;
          for (0..__cis#{id}_actual_workers) |__w| {
              try __cis#{id}_final.appendSlice(#{rt_name}.heapAlloc(), __cis#{id}_workers[__w].local.items);
              __cis#{id}_workers[__w].local.deinit(#{rt_name}.heapAlloc());
          }
          break :#{@current_pipe_label} __cis#{id}_final;
      }
    ZIG
  end

  # CONCURRENT WHERE on ~T[] / ~T[INF]: BoundedChannel feeder + N worker fibers.
  def transpile_concurrent_stream_where(stream_node, where_op, id, workers_code, capacity_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(where_op.expression)

    stream_ti = stream_node.type_info
    is_inf  = stream_ti&.inf_stream?
    is_open = stream_ti&.open_stream?
    item_zig = transpile_type(
      if is_inf then stream_ti.inf_stream_element_type.resolved
      elsif is_open then stream_ti.open_stream_element_type.resolved
      else stream_ti.tense_type.element_type.resolved
      end)
    pop_method = is_inf ? "nextOrNull" : "next"
    source     = stream_concurrent_source_setup(stream_node, id)

    inner_code = with_pipeline_context(placeholder: "__stream_item") do
      with_fiber_capture_map({}) { visit(inner_expr) }
    end
    bare_code = inner_code.sub(/^try /, '')

    err_field    = policy == :raise ? "\n              err:   *std.atomic.Value(u16)," : ""
    err_ctx_init = policy == :raise ? "\n                  .err   = &__cisw#{id}_err," : ""
    err_decl     = policy == :raise ? "\n          var __cisw#{id}_err = std.atomic.Value(u16).init(0);" : ""
    err_check    = policy == :raise ? "\n          const __cisw#{id}_ec = __cisw#{id}_err.load(.seq_cst);\n          if (__cisw#{id}_ec != 0) return @errorFromInt(__cisw#{id}_ec);" : ""

    pred_body = case policy
    when :prune
      "const __cv = #{bare_code} catch continue;\n                  if (__cv) try ctx.local.append(ctx.alloc, __stream_item);"
    when :raise
      "const __cv = #{bare_code} catch |e| {\n                      _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);\n                      continue;\n                  };\n                  if (__cv) try ctx.local.append(ctx.alloc, __stream_item);"
    else
      "if (#{inner_code}) try ctx.local.append(ctx.alloc, __stream_item);"
    end

    feeder_spawn = "try __cisw#{id}_wg.sched.submitSpawn(\n              @intFromPtr(&Runtime.entryWrapper),\n              @as(CheatHeader.TaskFn, @ptrCast(&__CiswFeeder#{id}.run)),\n              &__cisw#{id}_feeder, .{},\n          );"
    worker_spawn = concurrent_spawn_call(options, "__cisw#{id}_wg", "__CiswWorker#{id}", "__cisw#{id}_workers[__w]")
    cap_zig = capacity_code ? "@intCast(#{capacity_code})" : "blk: { var c: usize = 4; while (c < __cisw#{id}_n_workers * 4) : (c <<= 1) {} break :blk @min(c, 64); }"

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          #{source[:setup].empty? ? "" : source[:setup] + "\n          "}const __cisw#{id}_n_workers: usize = @intCast(#{workers_code});
          const __cisw#{id}_cap: usize = #{cap_zig};
          var __cisw#{id}_chan = try CheatLib.BoundedChannel(#{item_zig}).init(#{rt_name}.heapAlloc(), __cisw#{id}_cap);
          defer __cisw#{id}_chan.deinit();
          var __cisw#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());#{err_decl}
          const __CiswFeeder#{id} = struct {
              wg:   *CheatHeader.WaitGroup,
              src:  *@TypeOf(#{source[:src_name]}),
              chan: *CheatLib.BoundedChannel(#{item_zig}),
              fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  defer ctx.chan.close();
                  while (try ctx.src.#{pop_method}()) |__stream_item| {
                      try ctx.chan.push(__stream_item);
                  }
              }
          };
          const __CiswWorker#{id} = struct {
              wg:    *CheatHeader.WaitGroup,
              chan:  *CheatLib.BoundedChannel(#{item_zig}),
              local: std.ArrayListUnmanaged(#{item_zig}),
              alloc: std.mem.Allocator,#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (try ctx.chan.pop()) |__stream_item| {
                      #{pred_body}
                      __rt.checkYield();
                  }
              }
          };
          var __cisw#{id}_feeder = __CiswFeeder#{id}{ .wg = &__cisw#{id}_wg, .src = &#{source[:src_name]}, .chan = &__cisw#{id}_chan };
          var __cisw#{id}_workers: [64]__CiswWorker#{id} = undefined;
          const __cisw#{id}_actual_workers: usize = @min(__cisw#{id}_n_workers, 64);
          __cisw#{id}_wg.add(1 + __cisw#{id}_actual_workers);
          #{feeder_spawn}
          for (0..__cisw#{id}_actual_workers) |__w| {
              __cisw#{id}_workers[__w] = .{ .wg = &__cisw#{id}_wg, .chan = &__cisw#{id}_chan, .local = .empty, .alloc = #{rt_name}.heapAlloc()#{err_ctx_init} };
              #{worker_spawn}
          }
          __cisw#{id}_wg.wait();#{err_check}
          var __cisw#{id}_final = std.ArrayListUnmanaged(#{item_zig}).empty;
          for (0..__cisw#{id}_actual_workers) |__w| {
              try __cisw#{id}_final.appendSlice(#{rt_name}.heapAlloc(), __cisw#{id}_workers[__w].local.items);
              __cisw#{id}_workers[__w].local.deinit(#{rt_name}.heapAlloc());
          }
          break :#{@current_pipe_label} __cisw#{id}_final;
      }
    ZIG
  end

  # CONCURRENT EACH on ~T[] / ~T[INF]: BoundedChannel feeder + N worker fibers.
  def transpile_concurrent_stream_each(stream_node, each_op, conc_op, id, workers_code, capacity_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    stream_ti  = stream_node.type_info
    is_inf  = stream_ti&.inf_stream?
    is_open = stream_ti&.open_stream?
    item_zig = transpile_type(
      if is_inf then stream_ti.inf_stream_element_type.resolved
      elsif is_open then stream_ti.open_stream_element_type.resolved
      else stream_ti.tense_type.element_type.resolved
      end)
    pop_method = is_inf ? "nextOrNull" : "next"
    source     = stream_concurrent_source_setup(stream_node, id)

    captures = conc_op.capture_analysis&.captures || {}
    capture_map = captures.keys.to_h { |name| [name, "ctx.#{name}.*"] }
    capture_fields = captures.keys.map { |name| "    #{name}: *const @TypeOf(#{name})," }.join("\n")
    capture_inits  = captures.keys.map { |name| ".#{name} = &#{name}" }.join(", ")
    capture_inits_str = capture_inits.empty? ? "" : ", #{capture_inits}"

    body_code = with_pipeline_context(placeholder: "__each_item") do
      with_fiber_capture_map(capture_map) do
        each_op.body.map { |stmt|
          code = visit(stmt)
          s = code.strip
          (s.end_with?(";") || s.end_with?("}")) ? code : "#{code};"
        }.join("\n                  ")
      end
    end

    feeder_spawn = "try __cise#{id}_wg.sched.submitSpawn(\n              @intFromPtr(&Runtime.entryWrapper),\n              @as(CheatHeader.TaskFn, @ptrCast(&__CiseFeeder#{id}.run)),\n              &__cise#{id}_feeder, .{},\n          );"
    worker_spawn = concurrent_spawn_call(options, "__cise#{id}_wg", "__CiseWorker#{id}", "__cise#{id}_workers[__w]")
    cap_zig = capacity_code ? "@intCast(#{capacity_code})" : "blk: { var c: usize = 4; while (c < __cise#{id}_n_workers * 4) : (c <<= 1) {} break :blk @min(c, 64); }"

    <<~ZIG.chomp
      {
          #{source[:setup].empty? ? "" : source[:setup] + "\n          "}const __cise#{id}_n_workers: usize = @intCast(#{workers_code});
          const __cise#{id}_cap: usize = #{cap_zig};
          var __cise#{id}_chan = try CheatLib.BoundedChannel(#{item_zig}).init(#{rt_name}.heapAlloc(), __cise#{id}_cap);
          defer __cise#{id}_chan.deinit();
          var __cise#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __CiseFeeder#{id} = struct {
              wg:   *CheatHeader.WaitGroup,
              src:  *@TypeOf(#{source[:src_name]}),
              chan: *CheatLib.BoundedChannel(#{item_zig}),
              fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  defer ctx.chan.close();
                  while (try ctx.src.#{pop_method}()) |__stream_item| {
                      try ctx.chan.push(__stream_item);
                  }
              }
          };
          const __CiseWorker#{id} = struct {
              wg:   *CheatHeader.WaitGroup,
              chan: *CheatLib.BoundedChannel(#{item_zig}),
          #{capture_fields.empty? ? "" : capture_fields + "\n    "}    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (try ctx.chan.pop()) |__each_item| {
                      #{body_code}
                      __rt.checkYield();
                  }
              }
          };
          var __cise#{id}_feeder = __CiseFeeder#{id}{ .wg = &__cise#{id}_wg, .src = &#{source[:src_name]}, .chan = &__cise#{id}_chan };
          var __cise#{id}_workers: [64]__CiseWorker#{id} = undefined;
          const __cise#{id}_actual_workers: usize = @min(__cise#{id}_n_workers, 64);
          __cise#{id}_wg.add(1 + __cise#{id}_actual_workers);
          #{feeder_spawn}
          for (0..__cise#{id}_actual_workers) |__w| {
              __cise#{id}_workers[__w] = .{ .wg = &__cise#{id}_wg, .chan = &__cise#{id}_chan#{capture_inits_str} };
              #{worker_spawn}
          }
          __cise#{id}_wg.wait();
      }
    ZIG
  end

  # Returns the Zig spawn call for CONCURRENT workers.
  # CONCURRENT: submitSpawn — workers stay on the local scheduler (cache-local, SPSC-safe).
  # @parallel: spawnBest — distributes across schedulers (true multi-core parallelism).
  sig { params(options: T.untyped, wg_var: T.untyped, ctx_type: T.untyped, ctx_var: T.untyped).returns(String) }
  def concurrent_spawn_call(options, wg_var, ctx_type, ctx_var)
    T.bind(self, T.untyped) rescue nil
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

  sig { params(options: T.untyped).returns(String) }
  def concurrent_batch_code(options)
    T.bind(self, T.untyped) rescue nil
    batch = options["batch"]
    batch ? visit(batch) : "1"
  end

  # Inspect the expression for OR PRUNE / OR RAISE error policy
  # Returns [:prune, inner_expr], [:raise, inner_expr], or [:default, expr]
  sig { params(expr: T.untyped).returns(Array) }
  def extract_concurrent_error_policy(expr)
    T.bind(self, T.untyped) rescue nil
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      if expr.right.is_a?(AST::OrPrune)
        return [:prune, expr.left]
      elsif expr.right.is_a?(AST::OrRaise)
        return [:raise, expr.left]
      end
    end
    [:default, expr]
  end

  sig { params(list_node: T.untyped, select_op: T.untyped, id: T.untyped, workers_code: T.untyped, rt_name: T.untyped, options: T.untyped).returns(String) }
  def transpile_concurrent_select(list_node, select_op, id, workers_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(select_op.expression)

    result_type_sym = select_op.expression.full_type
    result_zig = transpile_type(result_type_sym)
    item_zig   = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    src_needs_cleanup = list_node.is_a?(AST::MethodCall) &&
                        %w[values keys].include?(list_node.name.to_s) &&
                        list_node.object.type_info&.sharded?
    cleanup_line = src_needs_cleanup ? "defer pipe_src_list.deinit(#{rt_name}.heapAlloc());" : ""
    src_decl     = src_needs_cleanup ? "var pipe_src_list" : "const pipe_src_list"

    # For the worker body, items accessed via ctx.items (the context struct).
    # If source was `list AS $u`, $u also resolves to ctx.items[__idx].
    inner_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) do
        with_concurrent_outer_binding("ctx.items[__idx]") { visit(inner_expr) }
      end
    end
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
    batch_code = concurrent_batch_code(options)

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          #{src_decl} = #{list_code};
          #{cleanup_line}
          _ = &pipe_src_list;
          #{items_block}
          const __ccs#{id}_items = pipe_items;
          const __ccs#{id}_len = __ccs#{id}_items.len;
          const __ccs#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{result_zig}, __ccs#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccs#{id}_results);
          for (__ccs#{id}_results) |*__s| __s.* = null;#{err_decl}
          var __ccs#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccs#{id}_n_workers: usize = @intCast(#{workers_code});
          const __ccs#{id}_batch: usize = @max(@as(usize, @intCast(#{batch_code})), 1);
          const __CcsWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   []const #{item_zig},
              results: []?#{result_zig},
              batch:   usize,
              next:    *std.atomic.Value(usize),#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __start = ctx.next.fetchAdd(ctx.batch, .monotonic);
                      if (__start >= ctx.items.len) break;
                      const __end = @min(__start + ctx.batch, ctx.items.len);
                      for (__start..__end) |__idx| {
                          #{fiber_result_code}
                      }
                      __rt.checkYield();
                  }
              }
          };
          var __ccs#{id}_next = std.atomic.Value(usize).init(0);
          var __ccs#{id}_workers: [64]__CcsWorker#{id} = undefined;
          const __ccs#{id}_actual_workers: usize = @min(__ccs#{id}_n_workers, 64);
          __ccs#{id}_wg.add(__ccs#{id}_actual_workers);
          for (0..__ccs#{id}_actual_workers) |__w| {
              __ccs#{id}_workers[__w] = .{
                  .wg      = &__ccs#{id}_wg,
                  .items   = __ccs#{id}_items,
                  .results = __ccs#{id}_results,
                  .batch   = __ccs#{id}_batch,
                  .next    = &__ccs#{id}_next,#{err_ctx_init}
              };
              #{spawn_call}
          }
          __ccs#{id}_wg.wait();#{err_check}
          var __ccs#{id}_final = std.ArrayListUnmanaged(#{result_zig}).empty;
          for (__ccs#{id}_results) |__ccs#{id}_slot| {
              if (__ccs#{id}_slot) |__v| try __ccs#{id}_final.append(#{rt_name}.heapAlloc(), __v);
          }
          break :#{@current_pipe_label} __ccs#{id}_final;
      }
    ZIG
  end

  sig { params(list_node: T.untyped, where_op: T.untyped, id: T.untyped, workers_code: T.untyped, rt_name: T.untyped, options: T.untyped).returns(String) }
  def transpile_concurrent_where(list_node, where_op, id, workers_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(where_op.expression)

    item_type_str = list_node.full_type.element_type.resolved.to_s
    item_zig      = transpile_type(item_type_str)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    src_needs_cleanup = list_node.is_a?(AST::MethodCall) &&
                        %w[values keys].include?(list_node.name.to_s) &&
                        list_node.object.type_info&.sharded?
    cleanup_line = src_needs_cleanup ? "defer pipe_src_list.deinit(#{rt_name}.heapAlloc());" : ""
    src_decl     = src_needs_cleanup ? "var pipe_src_list" : "const pipe_src_list"

    inner_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) do
        with_concurrent_outer_binding("ctx.items[__idx]") { visit(inner_expr) }
      end
    end
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
    batch_code = concurrent_batch_code(options)

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          #{src_decl} = #{list_code};
          #{cleanup_line}
          _ = &pipe_src_list;
          #{items_block}
          const __ccw#{id}_items = pipe_items;
          const __ccw#{id}_len = __ccw#{id}_items.len;
          const __ccw#{id}_results = try #{rt_name}.heapAlloc().alloc(?#{item_zig}, __ccw#{id}_len);
          defer #{rt_name}.heapAlloc().free(__ccw#{id}_results);
          for (__ccw#{id}_results) |*__s| __s.* = null;#{err_decl}
          var __ccw#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccw#{id}_n_workers: usize = @intCast(#{workers_code});
          const __ccw#{id}_batch: usize = @max(@as(usize, @intCast(#{batch_code})), 1);
          const __CcwWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   []const #{item_zig},
              results: []?#{item_zig},
              batch:   usize,
              next:    *std.atomic.Value(usize),#{err_field}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __start = ctx.next.fetchAdd(ctx.batch, .monotonic);
                      if (__start >= ctx.items.len) break;
                      const __end = @min(__start + ctx.batch, ctx.items.len);
                      for (__start..__end) |__idx| {
                          #{pred_body}
                      }
                      __rt.checkYield();
                  }
              }
          };
          var __ccw#{id}_next = std.atomic.Value(usize).init(0);
          var __ccw#{id}_workers: [64]__CcwWorker#{id} = undefined;
          const __ccw#{id}_actual_workers: usize = @min(__ccw#{id}_n_workers, 64);
          __ccw#{id}_wg.add(__ccw#{id}_actual_workers);
          for (0..__ccw#{id}_actual_workers) |__w| {
              __ccw#{id}_workers[__w] = .{
                  .wg      = &__ccw#{id}_wg,
                  .items   = __ccw#{id}_items,
                  .results = __ccw#{id}_results,
                  .batch   = __ccw#{id}_batch,
                  .next    = &__ccw#{id}_next,#{err_ctx_init}
              };
              #{spawn_call}
          }
          __ccw#{id}_wg.wait();#{err_check}
          var __ccw#{id}_final = std.ArrayListUnmanaged(#{item_zig}).empty;
          for (__ccw#{id}_results) |__ccw#{id}_slot| {
              if (__ccw#{id}_slot) |__v| try __ccw#{id}_final.append(#{rt_name}.heapAlloc(), __v);
          }
          break :#{@current_pipe_label} __ccw#{id}_final;
      }
    ZIG
  end

  sig { params(list_node: T.untyped, each_op: T.untyped, id: T.untyped, workers_code: T.untyped, rt_name: T.untyped, options: T.untyped).returns(String) }
  def transpile_concurrent_each(list_node, each_op, id, workers_code, rt_name, options = {})
    T.bind(self, T.untyped) rescue nil
    item_zig = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    src_needs_cleanup = list_node.is_a?(AST::MethodCall) &&
                        %w[values keys].include?(list_node.name.to_s) &&
                        list_node.object.type_info&.sharded?
    cleanup_line = src_needs_cleanup ? "defer pipe_src_list.deinit(#{rt_name}.heapAlloc());" : ""

    # For EACH workers, the placeholder references the shared items array by index.
    body_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) do
        with_concurrent_outer_binding("ctx.items[__idx]") do
          each_op.body.map { |stmt|
            code = visit(stmt)
            code.strip.end_with?(";") ? code : "#{code};"
          }.join("\n                      ")
        end
      end
    end

    spawn_call = concurrent_spawn_call(options, "__cce#{id}_wg", "__CceWorker#{id}", "__cce#{id}_workers[__w]")
    batch_code = concurrent_batch_code(options)

    <<~ZIG.chomp
      {
          var pipe_src_list = #{list_code};
          #{cleanup_line}
          _ = &pipe_src_list;
          #{items_block}
          const __cce#{id}_items = pipe_items;
          const __cce#{id}_len = __cce#{id}_items.len;
          if (__cce#{id}_len == 0) {} else {
          var __cce#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __cce#{id}_n_workers: usize = @intCast(#{workers_code});
          const __cce#{id}_batch: usize = @max(@as(usize, @intCast(#{batch_code})), 1);
          const __CceWorker#{id} = struct {
              wg:    *CheatHeader.WaitGroup,
              items: []#{item_zig},
              batch: usize,
              next:  *std.atomic.Value(usize),
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __start = ctx.next.fetchAdd(ctx.batch, .monotonic);
                      if (__start >= ctx.items.len) break;
                      const __end = @min(__start + ctx.batch, ctx.items.len);
                      for (__start..__end) |__idx| {
                          const __each_item = &ctx.items[__idx];
                          _ = __each_item;
                          #{body_code}
                      }
                      __rt.checkYield();
                  }
              }
          };
          var __cce#{id}_next = std.atomic.Value(usize).init(0);
          var __cce#{id}_workers: [64]__CceWorker#{id} = undefined;
          const __cce#{id}_actual_workers: usize = @min(__cce#{id}_n_workers, 64);
          __cce#{id}_wg.add(__cce#{id}_actual_workers);
          for (0..__cce#{id}_actual_workers) |__w| {
              __cce#{id}_workers[__w] = .{
                  .wg    = &__cce#{id}_wg,
                  .items = @constCast(__cce#{id}_items),
                  .batch = __cce#{id}_batch,
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
  # CONCURRENT SUM/COUNT/MIN/MAX/AVERAGE: partial aggregation
  # =========================================================
  #
  # Each worker has a private accumulator (cache-line padded).
  # Zero contention during the parallel phase. Sequential O(N)
  # combine after WaitGroup.wait().
  #
  sig { params(list_node: T.untyped, op_node: T.untyped, id: T.untyped, workers_code: T.untyped, rt_name: T.untyped, options: T.untyped, kind: T.untyped, smooth_node: T.untyped).returns(String) }
  def transpile_concurrent_reduce(list_node, op_node, id, workers_code, rt_name, options, kind, smooth_node = nil)
    T.bind(self, T.untyped) rescue nil
    @current_pipe_label = next_pipe_label
    item_zig = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    src_needs_cleanup = list_node.is_a?(AST::MethodCall) &&
                        %w[values keys].include?(list_node.name.to_s) &&
                        list_node.object.type_info&.sharded?
    cleanup_line = src_needs_cleanup ? "defer pipe_src_list.deinit(#{rt_name}.heapAlloc());" : ""

    expr_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) do
        with_concurrent_outer_binding("ctx.items[__idx]") { visit(op_node.expression) }
      end
    end

    spawn_call = concurrent_spawn_call(options, "__ccr#{id}_wg", "__CcrWorker#{id}", "__ccr#{id}_workers[__w]")

    # Per-kind configuration (use smooth_node.full_type for result type — reliable even for Placeholder exprs)
    case kind
    when :sum
      partial_type = smooth_node ? transpile_type(smooth_node.full_type.to_s) : "f64"
      partial_init = "0"
      worker_body  = "ctx.partial.* += #{expr_code};"
      result_type  = partial_type
      result_init  = "0"
    when :count
      partial_type = "i64"
      partial_init = "0"
      worker_body  = "if (#{expr_code}) { ctx.partial.* += 1; }"
      result_type  = "i64"
      result_init  = "0"
    when :min
      expr_sym     = smooth_node ? smooth_node.full_type.resolved : :Float64
      partial_type = smooth_node ? transpile_type(smooth_node.full_type.to_s) : "f64"
      partial_init, _ = agg_minmax_sentinels(partial_type, expr_sym)
      worker_body  = "const __v = #{expr_code}; if (__v < ctx.partial.*) ctx.partial.* = __v;"
      result_type  = partial_type
      result_init  = partial_init
    when :max
      expr_sym     = smooth_node ? smooth_node.full_type.resolved : :Float64
      partial_type = smooth_node ? transpile_type(smooth_node.full_type.to_s) : "f64"
      _, partial_init = agg_minmax_sentinels(partial_type, expr_sym)
      worker_body  = "const __v = #{expr_code}; if (__v > ctx.partial.*) ctx.partial.* = __v;"
      result_type  = partial_type
      result_init  = partial_init
    when :average
      partial_type = "f64"
      partial_init = "0"
      worker_body  = "ctx.partial.* += #{expr_code};"
      result_type  = "f64"
      result_init  = "0"
    end

    # AVERAGE needs the total count for the final division
    average_suffix = if kind == :average
      "\n          const __ccr#{id}_len_f: f64 = @floatFromInt(__ccr#{id}_len);\n" \
      "          break :#{@current_pipe_label} if (__ccr#{id}_len == 0) @as(f64, 0) else __ccr#{id}_result / __ccr#{id}_len_f;"
    else
      "\n          break :#{@current_pipe_label} __ccr#{id}_result;"
    end

    <<~ZIG.chomp
      #{@current_pipe_label}: {
          var pipe_src_list = #{list_code};
          #{cleanup_line}
          _ = &pipe_src_list;
          #{items_block}
          const __ccr#{id}_items = pipe_items;
          const __ccr#{id}_len = __ccr#{id}_items.len;
          if (__ccr#{id}_len == 0) {
              break :#{@current_pipe_label} @as(#{result_type}, #{result_init});
          }
          var __ccr#{id}_wg = CheatHeader.WaitGroup.init(#{rt_name}.getSched());
          const __ccr#{id}_n_workers: usize = @intCast(#{workers_code});

          // Per-worker partial accumulators (cache-line padded to avoid false sharing)
          const __CcrPartial#{id} = struct { value: #{partial_type} align(64) = #{partial_init} };
          var __ccr#{id}_partials_store: [64]__CcrPartial#{id} = [_]__CcrPartial#{id}{.{}} ** 64;

          const __CcrWorker#{id} = struct {
              wg:      *CheatHeader.WaitGroup,
              items:   []#{item_zig},
              next:    *std.atomic.Value(usize),
              partial: *#{partial_type},
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  while (true) {
                      const __idx = ctx.next.fetchAdd(1, .monotonic);
                      if (__idx >= ctx.items.len) break;
                      #{worker_body}
                  }
              }
          };

          var __ccr#{id}_next = std.atomic.Value(usize).init(0);
          var __ccr#{id}_workers: [64]__CcrWorker#{id} = undefined;
          const __ccr#{id}_actual = @min(__ccr#{id}_n_workers, 64);
          __ccr#{id}_wg.add(__ccr#{id}_actual);
          for (0..__ccr#{id}_actual) |__w| {
              __ccr#{id}_workers[__w] = .{
                  .wg      = &__ccr#{id}_wg,
                  .items   = @constCast(__ccr#{id}_items),
                  .next    = &__ccr#{id}_next,
                  .partial = &__ccr#{id}_partials_store[__w].value,
              };
              #{spawn_call}
          }
          __ccr#{id}_wg.wait();

          // Combine: merge partial results (sequential, O(workers))
          var __ccr#{id}_result: #{result_type} = #{result_init};
          for (0..__ccr#{id}_actual) |__w| {
              const __ccr#{id}_p = __ccr#{id}_partials_store[__w].value;
              #{combine_body_inline(kind, id)}
          }#{average_suffix}
      }
    ZIG
  end

  sig { params(kind: T.untyped, id: T.untyped).returns(T.untyped) }
  def combine_body_inline(kind, id)
    T.bind(self, T.untyped) rescue nil
    p = "__ccr#{id}_p"
    r = "__ccr#{id}_result"
    case kind
    when :sum, :average then "#{r} += #{p};"
    when :count         then "#{r} += #{p};"
    when :min           then "if (#{p} < #{r}) #{r} = #{p};"
    when :max           then "if (#{p} > #{r}) #{r} = #{p};"
    end
  end

  # SHARD + CONCURRENT EACH was migrated to structural MIR in
  # PipelineHost#lower_shard_concurrent_each. This callee no longer
  # exists; the dispatch in transpile_concurrent now never reaches the
  # shard branch (lower_pipeline always returns non-nil for this case).

  def visit_Placeholder(node)
    # Return the name of the loop variable
    T.bind(self, T.untyped) rescue nil
    @placeholder_name || (raise "Use of '_' outside of SELECT context")
  end
end
