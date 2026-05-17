# typed: false
# Shared pipeline lowering helpers. Operator-specific lowering lives in
# PipelineHost and lowers through structural MIR/runtime calls.
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

  # Save and restore all pipeline state around a block. Ensures that nested
  # pipeline visits (chained pipelines, SHARD bodies, etc.) don't leak state.
  # Any keyword argument overrides the corresponding state for the block's duration.
  sig { params(placeholder: T.untyped, acc: T.untyped, soa: T.untyped, shard_map: T.untyped, shard_idx: T.untyped, shard_key: T.untyped, shard_hash: T.untyped, blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def with_pipeline_context(placeholder: nil, acc: nil, soa: :inherit, shard_map: nil, shard_idx: nil, shard_key: nil, shard_hash: nil, &blk)
    T.bind(self, T.untyped) rescue ""
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
    # :inherit means "don't touch SOA".
    managing_soa = soa != :inherit
    if managing_soa
      prev_soa_active = @soa_rewrite_active
      prev_soa_fields = @soa_needed_fields
      @soa_rewrite_active = soa
      @soa_needed_fields = T.let(Set.new, T.nilable(T::Set[T.untyped])) if soa
    end

    result = blk.call
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

  # Emits Zig lines that produce `pipe_items` (a slice) from `pipe_src_list`.
  # Handles regular arrays, @pool, @pool:sharded(N), @list, and @list:sharded(N).
  #
  # Pools and sharded lists materialise live items into a temporary buffer.
  # We always use rt.heapAlloc() for that buffer because the fiber frame is
  # small (4 KB) and running many pipeline ops in one function would overflow it.
  sig { params(lhs_type: T.untyped, _alloc: String).returns(String) }
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

  # Returns [min_sentinel, max_sentinel] for a given Zig numeric type.
  # min_sentinel is the initial value for a MIN accumulator (highest possible).
  # max_sentinel is the initial value for a MAX accumulator (lowest possible).
  sig { params(zig_t: String, resolved_sym: Symbol).returns(T::Array[String]) }
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

end
