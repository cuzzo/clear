# Generates Zig code for pipeline operators (s>) that need special
# iteration patterns: pool, sharded, SOA sources, and CONCURRENT.
#
# For plain-array sources, PipelineRewriter converts most operators
# into standard AST nodes (ForEach, BlockExpr, IfStatement) before
# the transpiler runs. This module is still needed for:
#   - Pool/sharded/SOA sources (all operators)
#   - CONCURRENT/SHARD (all source types)
#   - Non-rewritten operators: INDEX, ORDER_BY, LIMIT, SKIP,
#     WINDOW, JOIN (all sources)
module PipelineGenerator
  # Unique label for each pipeline block -- prevents Zig label collisions
  # when pipelines are chained (e.g., a s> SELECT s> WHERE).
  def next_pipe_label
    @pipe_label_counter = (@pipe_label_counter || 0) + 1
    "__pblk#{@pipe_label_counter}"
  end

  # -------------------------------------------------------------------------
  # Pipeline Loop Fusion
  # -------------------------------------------------------------------------
  # Detects chains like `source s> WHERE pred s> SELECT expr s> SUM _`
  # and fuses them into a single loop with no intermediate allocations.

  FOLD_TYPES = [AST::SumOp, AST::AverageOp, AST::MinOp, AST::MaxOp,
                AST::CountOp, AST::ReduceOp, AST::AnyOp, AST::AllOp, AST::FindOp].freeze
  FUSIBLE_TYPES = [AST::WhereOp, AST::SelectOp, AST::TapOp, AST::TakeWhileOp].freeze

  # Walk the left-spine of nested s> BinaryOps and collect fusible stages.
  # Returns { source:, stages: [WhereOp/SelectOp, ...], terminal: FoldOp, terminal_node: } or nil.
  def collect_fusible_chain(node)
    return nil unless node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
    return nil unless FOLD_TYPES.any? { |t| node.right.is_a?(t) }

    terminal = node.right
    stages = []
    cursor = node.left

    while cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
      stage = cursor.right
      break unless FUSIBLE_TYPES.any? { |t| stage.is_a?(t) }
      stages.unshift(stage)
      cursor = cursor.left
    end

    return nil if stages.empty?  # single-stage fold: no fusion needed

    { source: cursor, stages: stages, terminal: terminal, smooth_node: node }
  end

  # Build direct iteration setup + loop header for fused pipelines.
  # Avoids materializing into a temporary ArrayList (which would cause
  # use-after-free for FIND/REDUCE that return references into the buffer).
  def build_fused_iteration(lhs_type, source_var)
    if lhs_type&.pool? && lhs_type&.sharded?
      n = lhs_type.shard_count
      { setup: "",
        loop_open: "for (0..#{n}) |__psi| {\n            for (#{source_var}.shards[__psi].slots) |*__pslot| {\n                if (!__pslot.alive) continue;\n                const it = __pslot.value;",
        loop_close: "}\n            }" }
    elsif lhs_type&.pool? && lhs_type&.soa?
      { setup: "",
        loop_open: "for (0..@intCast(#{source_var}.data.len)) |__psi| {\n                if (!#{source_var}.alive[__psi]) continue;\n                const it = #{source_var}.data.get(__psi);",
        loop_close: "}" }
    elsif lhs_type&.pool?
      { setup: "",
        loop_open: "for (#{source_var}.slots) |*__pslot| {\n                if (!__pslot.alive) continue;\n                const it = __pslot.value;",
        loop_close: "}" }
    elsif lhs_type&.list_collection? && lhs_type&.sharded?
      n = lhs_type.shard_count
      { setup: "",
        loop_open: "for (0..#{n}) |__psi| {\n            for (#{source_var}.shards[__psi].items) |it| {",
        loop_close: "}\n            }" }
    elsif lhs_type&.list_collection? && lhs_type&.soa?
      { setup: "",
        loop_open: "for (0..@intCast(#{source_var}.data.len)) |__psi| {\n                const it = #{source_var}.data.get(__psi);",
        loop_close: "}" }
    else
      raise "BUG: plain-array fused pipeline should have been rewritten by PipelineRewriter"
    end
  end

  # Generate a single fused loop for a fusible chain.
  # Processes stages in order (not split into guards/transforms), threading
  # the current variable name through each stage.
  # Uses direct iteration (no temporary ArrayList) to avoid use-after-free
  # when FIND/REDUCE return references from pool/sharded sources.
  def transpile_fused_pipeline(chain)
    source = chain[:source]
    stages = chain[:stages]
    terminal = chain[:terminal]
    smooth_node = chain[:smooth_node]

    my_label = next_pipe_label
    source_code = visit(source)
    @current_pipe_label = my_label

    lhs_type = source.type_info
    iter = build_fused_iteration(lhs_type, "pipe_src_list")

    # Process stages sequentially, tracking the current value binding.
    # WHERE: emits an if-guard (opens a block), current binding unchanged.
    # SELECT: emits a const binding with a new name, updates current binding.
    indent = "    "
    lines = []
    lines << iter[:loop_open]
    current_var = "it"
    where_depth = 0
    select_counter = 0

    stages.each do |stage|
      if stage.is_a?(AST::WhereOp)
        expr = with_pipeline_context(placeholder: current_var) { visit(stage.expression) }
        lines << "#{indent}if (#{expr}) {"
        indent += "    "
        where_depth += 1
      elsif stage.is_a?(AST::SelectOp)
        expr = with_pipeline_context(placeholder: current_var) { visit(stage.expression) }
        new_var = "__fused#{select_counter > 0 ? select_counter : ''}"
        select_counter += 1
        lines << "#{indent}const #{new_var} = #{expr};"
        current_var = new_var
      elsif stage.is_a?(AST::TakeWhileOp)
        expr = with_pipeline_context(placeholder: current_var) { visit(stage.expression) }
        lines << "#{indent}if (!(#{expr})) break;"
      elsif stage.is_a?(AST::TapOp)
        body_code = with_pipeline_context(placeholder: current_var) do
          stage.body.map { |stmt|
            code = visit(stmt)
            code.strip.end_with?(";") ? code : "#{code};"
          }.join("\n#{indent}")
        end
        lines << "#{indent}#{body_code}"
      end
    end

    # Build fold body using current_var as the element reference
    fold_body = build_fold_body(terminal, source, smooth_node, current_var: current_var)

    # Fold accumulation
    fold_body[:accum_lines].each { |l| lines << "#{indent}#{l}" }

    # Close WHERE guards
    where_depth.times { indent = indent[0...-4]; lines << "#{indent}}" }

    lines << iter[:loop_close]
    lines << "break :#{my_label} #{fold_body[:result_expr]};"

    loop_code = lines.join("\n            ")

    <<~ZIG
      #{my_label}: {
          const pipe_src_list = #{source_code};
          #{iter[:setup]}
          #{fold_body[:init]}

          #{loop_code}
      }
    ZIG
  end

  # Build the fold-specific initialization, accumulation, and result expression.
  # current_var is the Zig variable name holding the element at this point in the
  # pipeline (either "it" for no transforms, or "__fused"/"__fused1" after SELECTs).
  def build_fold_body(terminal, source, smooth_node, current_var: "it")
    case terminal
    when AST::SumOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_sum: f64 = 0;",
        accum_lines: ["__fused_sum += #{expr};"],
        result_expr: "__fused_sum" }

    when AST::AverageOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_sum: f64 = 0;\n          var __fused_count: usize = 0;",
        accum_lines: ["__fused_sum += #{expr};", "__fused_count += 1;"],
        result_expr: "if (__fused_count == 0) @as(f64, 0) else __fused_sum / @as(f64, @floatFromInt(__fused_count))" }

    when AST::MinOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_min: f64 = std.math.floatMax(f64);",
        accum_lines: ["const __fv = #{expr};", "if (__fv < __fused_min) __fused_min = __fv;"],
        result_expr: "__fused_min" }

    when AST::MaxOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_max: f64 = -std.math.floatMax(f64);",
        accum_lines: ["const __fv = #{expr};", "if (__fv > __fused_max) __fused_max = __fv;"],
        result_expr: "__fused_max" }

    when AST::CountOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_count: i64 = 0;",
        accum_lines: ["if (#{expr}) __fused_count += 1;"],
        result_expr: "__fused_count" }

    when AST::ReduceOp
      acc_type = transpile_type(terminal.full_type)
      initial_code = visit(terminal.initial_value)
      expr = with_pipeline_context(placeholder: current_var, acc: "acc") { visit(terminal.expression) }
      { init: "var acc: #{acc_type} = #{initial_code};",
        accum_lines: ["acc = #{expr};"],
        result_expr: "acc" }

    when AST::AnyOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_any: bool = false;",
        accum_lines: ["if (#{expr}) { __fused_any = true; break; }"],
        result_expr: "__fused_any" }

    when AST::AllOp
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_all: bool = true;",
        accum_lines: ["if (!(#{expr})) { __fused_all = false; break; }"],
        result_expr: "__fused_all" }

    when AST::FindOp
      # Use current_var's type (post-transform), not source element type
      find_zig = current_var == "it" ? transpile_type(source.type_info.element_type.resolved.to_s) : "@TypeOf(#{current_var})"
      expr = with_pipeline_context(placeholder: current_var) { visit(terminal.expression) }
      { init: "var __fused_find: ?#{find_zig} = null;",
        accum_lines: ["if (#{expr}) { __fused_find = #{current_var}; break; }"],
        result_expr: "__fused_find" }

    else
      raise "Unsupported fold type in fusion: #{terminal.class}"
    end
  end

  # Save and restore all pipeline state around a block. Ensures that nested
  # pipeline visits (chained pipelines, SHARD bodies, etc.) don't leak state.
  # Any keyword argument overrides the corresponding state for the block's duration.
  def with_pipeline_context(placeholder: nil, acc: nil, soa: :inherit, shard_map: nil, shard_idx: nil, shard_key: nil, shard_hash: nil)
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
    my_label = next_pipe_label
    list_code = visit(list_node)  # may recurse for chained pipelines
    @current_pipe_label = my_label  # restore after inner pipeline may have changed it
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
      <<~ZIG
        #{@current_pipe_label}: {
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
            for (pipe_src_list.shards[__psi].slots) |*__pslot| {
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
            if (pipe_src_list.alive[__psi]) try pipe_mat.append(rt.heapAlloc(), pipe_src_list.data.get(__psi));
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
        for (pipe_src_list.slots) |*__pslot| {
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
      # Plain array/list: used by CONCURRENT and non-rewritten operators (INDEX, ORDER_BY, etc.)
      "const pipe_items = if (@hasField(@TypeOf(pipe_src_list), \"items\")) pipe_src_list.items else pipe_src_list[0..];"
    end
  end

  # Visit a pipeline expression with placeholder + SOA rewrite enabled.
  # When the collection is @pool:soa, _.field accesses in the expression
  # are rewritten to __soa_field[__soa_i] (field-slice access).
  def visit_pipeline_expr(list_node, expr_node, placeholder = "it")
    lhs_t = list_node.type_info
    is_soa = (lhs_t&.pool? || lhs_t&.list_collection?) && lhs_t&.soa?
    # SOA state is set directly (not via with_pipeline_context) because
    # @soa_needed_fields must survive beyond the visit — the caller
    # (transpile_pipeline_macro) reads it after this returns.
    @soa_rewrite_active = is_soa
    @soa_needed_fields = Set.new if is_soa
    with_pipeline_context(placeholder: placeholder) do
      visit(expr_node)
    end
  end

  def transpile_select_projection(list_node, expression_node)
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

  def transpile_where_filter(list_node, expression_node)
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

  def transpile_take_while(list_node, expression_node, smooth_node)
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

  def transpile_join(list_node, join_node, smooth_node)
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
    element_zig_type = transpile_type(list_node.full_type.element_type.resolved.to_s)

    expr_code = with_pipeline_context(placeholder: "it") { visit(expression_node) }

    init = "var idx_result: CheatLib.StringMap(std.ArrayListUnmanaged(#{element_zig_type})) = .{ .alloc = rt.frameAlloc() };"

    transpile_pipeline_macro(list_node, smooth_node, init: init, force_aos: true) do |alloc|
      <<~ZIG
        for (pipe_items) |it| {
            const idx_key = #{expr_code};
            const gop = idx_result.inner.getOrPut(#{alloc}, idx_key) catch @panic("INDEX allocation failed");
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayListUnmanaged(#{element_zig_type}){};
            }
            gop.value_ptr.append(#{alloc}, it) catch @panic("INDEX append failed");
        }
        break :#{@current_pipe_label} idx_result;
      ZIG
    end
  end

  def transpile_reduce(list_node, reduce_node)
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

  def transpile_limit(list_node, limit_node, smooth_node)
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

  def transpile_skip(list_node, skip_node, smooth_node)
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

  # Transpile `collection s> EACH _.expr` — side-effect iteration.
  # Dispatches to the appropriate implementation based on the source type:
  #   - Regular array/list → sequential for loop
  #   - Plain pool         → sequential live-slot scan
  #   - Sharded pool       → N parallel fibers (one per shard, DO-block pattern)
  def transpile_each(smooth_node)
    lhs      = smooth_node.left
    each_op  = smooth_node.right
    lhs_type = lhs.type_info
    is_soa   = (lhs_type&.pool? || lhs_type&.list_collection?) && lhs_type&.soa?

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

  def transpile_each_soa_list(list_node, body_code)
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
        break :#{@current_pipe_label} any_result;
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
        break :#{@current_pipe_label} all_result;
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
        break :#{@current_pipe_label} count_result;
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
        break :#{@current_pipe_label} sum_result;
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
        break :#{@current_pipe_label} if (avg_count == 0) @as(f64, 0) else avg_sum / @as(f64, @floatFromInt(avg_count));
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
        break :#{@current_pipe_label} min_result;
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
        break :#{@current_pipe_label} max_result;
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

    workers_code = options["workers"] ? visit(options["workers"]) : "CheatLib.threadCount()"
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
    when AST::SumOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :sum)
    when AST::CountOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :count)
    when AST::MinOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :min)
    when AST::MaxOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :max)
    when AST::AverageOp
      transpile_concurrent_reduce(lhs, inner, id, workers_code, rt_name, options, :average)
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
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(select_op.expression)

    result_type_sym = select_op.expression.full_type
    result_zig = transpile_type(result_type_sym)
    item_zig   = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    # For the worker body, items accessed via ctx.items (the context struct).
    inner_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) { visit(inner_expr) }
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

    <<~ZIG.chomp
      #{@current_pipe_label}: {
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
          break :#{@current_pipe_label} __ccs#{id}_final;
      }
    ZIG
  end

  def transpile_concurrent_where(list_node, where_op, id, workers_code, rt_name, options = {})
    @current_pipe_label = next_pipe_label
    policy, inner_expr = extract_concurrent_error_policy(where_op.expression)

    item_type_str = list_node.full_type.element_type.resolved.to_s
    item_zig      = transpile_type(item_type_str)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    inner_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) { visit(inner_expr) }
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

    <<~ZIG.chomp
      #{@current_pipe_label}: {
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
          break :#{@current_pipe_label} __ccw#{id}_final;
      }
    ZIG
  end

  def transpile_concurrent_each(list_node, each_op, id, workers_code, rt_name, options = {})
    item_zig = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    # For EACH workers, the placeholder references the shared items array by index.
    body_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) do
        each_op.body.map { |stmt|
          code = visit(stmt)
          code.strip.end_with?(";") ? code : "#{code};"
        }.join("\n                      ")
      end
    end

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
  # CONCURRENT SUM/COUNT/MIN/MAX/AVERAGE: partial aggregation
  # =========================================================
  #
  # Each worker has a private accumulator (cache-line padded).
  # Zero contention during the parallel phase. Sequential O(N)
  # combine after WaitGroup.wait().
  #
  def transpile_concurrent_reduce(list_node, op_node, id, workers_code, rt_name, options, kind)
    @current_pipe_label = next_pipe_label
    item_zig = transpile_type(list_node.type_info.element_type.resolved)

    list_code  = visit(list_node)
    lhs_type   = list_node.type_info
    items_block = build_pipe_items_block(lhs_type, "#{rt_name}.heapAlloc()")

    expr_code = with_pipeline_context(placeholder: "ctx.items[__idx]") do
      with_fiber_capture_map({}) { visit(op_node.expression) }
    end

    spawn_call = concurrent_spawn_call(options, "__ccr#{id}_wg", "__CcrWorker#{id}", "__ccr#{id}_workers[__w]")

    # Per-kind configuration
    case kind
    when :sum
      partial_type = "f64"
      partial_init = "0"
      worker_body  = "ctx.partial.* += #{expr_code};"
      result_type  = "f64"
      result_init  = "0"
    when :count
      partial_type = "i64"
      partial_init = "0"
      worker_body  = "if (#{expr_code}) { ctx.partial.* += 1; }"
      result_type  = "i64"
      result_init  = "0"
    when :min
      partial_type = "f64"
      partial_init = "std.math.floatMax(f64)"
      worker_body  = "const __v = #{expr_code}; if (__v < ctx.partial.*) ctx.partial.* = __v;"
      result_type  = "f64"
      result_init  = "std.math.floatMax(f64)"
    when :max
      partial_type = "f64"
      partial_init = "-std.math.floatMax(f64)"
      worker_body  = "const __v = #{expr_code}; if (__v > ctx.partial.*) ctx.partial.* = __v;"
      result_type  = "f64"
      result_init  = "-std.math.floatMax(f64)"
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

  def combine_body_inline(kind, id)
    p = "__ccr#{id}_p"
    r = "__ccr#{id}_result"
    case kind
    when :sum, :average then "#{r} += #{p};"
    when :count         then "#{r} += #{p};"
    when :min           then "if (#{p} < #{r}) #{r} = #{p};"
    when :max           then "if (#{p} > #{r}) #{r} = #{p};"
    end
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
    key_needs_frame_mark  = shard_ctx[:key_allocates_frame]
    body_needs_frame_mark = shard_ctx[:body_allocates_frame]

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
    key_code = with_pipeline_context(placeholder: "__sh#{id}_i") { visit(key_expr_node) }

    # Build the EACH body. Map accesses use putDirect/getDirect (no double hash).
    # Fused streaming: route + process in a single loop. No intermediate queues,
    # no fibers, no ring buffers. Each item is processed and discarded immediately.
    # The placeholder `_` resolves to the current key string.
    body_code = with_pipeline_context(
      placeholder: "__sh#{id}_key",
      shard_map: map_var_name,
      shard_idx: "__sh#{id}_sh.shard",
      shard_key: "__sh#{id}_key",
      shard_hash: "__sh#{id}_sh.hash"
    ) do
      each_op.body.map { |stmt|
        code = visit(stmt)
        code.strip.end_with?(";") ? code : "#{code};"
      }.join("\n              ")
    end

    range_op = exclusive ? "<" : "<="

    <<~ZIG.chomp
      {
          // ── SHARD + CONCURRENT EACH (fused streaming) ──
          // Bounded range: route + process each item in a single loop.
          // Zero intermediate storage, zero fibers, zero atomics.
          // Memory: O(1) per iteration (key lives on frame arena, freed by rewind).
          const __sh#{id}_map = &#{map_code};
          __sh#{id}_map.ensureOwnership();
          {
              var __sh#{id}_i: i64 = #{range_start};
              const __sh#{id}_end: i64 = #{range_end};
              while (__sh#{id}_i #{range_op} __sh#{id}_end) : (__sh#{id}_i += 1) {
                  #{key_needs_frame_mark ? "const __sh#{id}_loop_mark = #{rt_name}.saveLoopMark(); defer #{rt_name}.restoreLoopMark(__sh#{id}_loop_mark);" : ""}
                  const __sh#{id}_key = #{key_code};
                  const __sh#{id}_sh = @TypeOf(__sh#{id}_map.*).shardIndexWithHash(__sh#{id}_key);
                  #{body_code}
              }
          }
      }
    ZIG
  end

  def visit_Placeholder(node)
    # Return the name of the loop variable
    @placeholder_name || (raise "Use of '_' outside of SELECT context")
  end
end
