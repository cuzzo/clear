# typed: strict
require "sorbet-runtime"

module MIRLoweringConcurrency
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  class NextExprPlan < T::Struct
    extend T::Sig

    const :source_kind, Symbol
    const :promise_type, Type
    const :async_result_shape, T.nilable(AsyncResultShape)
    const :result_type, Type
    const :result_alloc, T.nilable(Symbol)
    const :inner, MIR::Node

    sig { returns(T::Boolean) }
    def promise_list?
      source_kind == :promise_list
    end

    sig { returns(T::Boolean) }
    def observable_list?
      source_kind == :observable_list
    end

    sig { returns(T::Boolean) }
    def observable_string?
      source_kind == :observable_string
    end
  end

  sig { params(parallel: T.nilable(T::Boolean), pinned: T.nilable(T.any(T::Boolean, Symbol))).returns(Symbol) }
  def execution_boundary_dispatch(parallel, pinned)
    return :parallel if parallel
    return :pinned if pinned

    :local
  end

  sig { params(kind: Symbol, dispatch: Symbol, analysis: T.nilable(CapabilityHelper::CaptureAnalysis)).returns(MIR::ExecutionBoundaryFact) }
  def execution_boundary_fact(kind, dispatch, analysis)
    symbols = T.let(analysis&.capture_symbols || {}, T::Hash[String, SymbolEntry])
    captured = T.let(
      T.cast(analysis&.captures, T.nilable(T::Hash[String, T.any(Type, Symbol, String)])) || {},
      T::Hash[String, T.any(Type, Symbol, String)],
    )
    names = T.let((symbols.keys + captured.keys).map(&:to_s).uniq.sort, T::Array[String])
    MIR::ExecutionBoundaryFact.new(
      kind: kind,
      dispatch: dispatch,
      captures: names.map { |name| boundary_capture_fact(name, symbols[name]) },
    )
  end

  sig { params(caps: FiberCtxBuilder::Result, analysis: T.nilable(CapabilityHelper::CaptureAnalysis), receiver: String).returns(T::Array[MIR::Stmt]) }
  def capture_ownership_mirror_nodes(caps, analysis, receiver)
    captured = T.let(
      T.cast(analysis&.captures, T.nilable(T::Hash[String, T.any(Type, Symbol, String)])) || {},
      T::Hash[String, T.any(Type, Symbol, String)],
    )
    caps.specs.filter_map do |spec|
      next nil unless spec.body_cleanup_zig

      raw_type = captured[spec.name]
      type_info = raw_type.is_a?(Type) ? Type.new(raw_type) : Type.new(raw_type || :Any)
      type_info = Type.new(:CapturedValue, location: :heap) if spec.field_type_zig.start_with?("CheatLib.CapturedValue(")
      name = "#{receiver}.#{spec.name}"
      entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true)
      mark = MIR::AllocMark.new(name, :heap, type_info)
      mark.scope = :heap
      [mark, MIR::Cleanup.new(name, entry)]
    end.flatten
  end

  sig { params(specs: T::Array[FiberCtxBuilder::CaptureSpec]).returns(T::Array[String]) }
  def capture_moved_guard_fields(specs)
    specs.filter_map do |spec|
      next nil unless spec.body_cleanup_zig

      "#{spec.name}_moved: bool = false,"
    end
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def finalized_boundary_body_for_emit(body)
    prev_alloc_names = T.unsafe(self).instance_variable_get(:@lowered_alloc_names)
    prev_guarded_names = T.unsafe(self).instance_variable_get(:@lowered_guarded_cleanup_names)
    T.unsafe(self).append_ownership_transfers_for_mir_body(body)
  ensure
    T.unsafe(self).instance_variable_set(:@lowered_alloc_names, prev_alloc_names)
    T.unsafe(self).instance_variable_set(:@lowered_guarded_cleanup_names, prev_guarded_names)
  end

  sig { params(node: T.untyped, receiver: String).returns(T::Boolean) }
  def capture_ownership_mirror_node?(node, receiver)
    return false unless node.is_a?(MIR::AllocMark) || node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)

    node.name.to_s.start_with?("#{receiver}.")
  end

  sig { params(name: String, symbol: T.nilable(SymbolEntry)).returns(MIR::BoundaryCaptureFact) }
  def boundary_capture_fact(name, symbol)
    storage = symbol&.storage
    sync = symbol&.sync
    ownership = symbol&.ownership_kind
    forbidden = boundary_capture_forbidden_reason(symbol)
    MIR::BoundaryCaptureFact.new(
      name: name,
      storage: storage,
      sync: sync,
      ownership: ownership,
      parallel_safe: forbidden.nil?,
      scheduler_affine: boundary_capture_scheduler_affine?(symbol),
      requires_pinned: boundary_capture_requires_pinned?(symbol),
      forbidden_reason: forbidden,
    )
  end

  sig { params(symbol: T.nilable(SymbolEntry)).returns(T.nilable(Symbol)) }
  def boundary_capture_forbidden_reason(symbol)
    return nil unless symbol
    return :local_scheduler_affinity if symbol.local?
    return :non_atomic_rc if boundary_capture_multiowned_rc?(symbol)
    return nil if boundary_capture_shared_arc?(symbol)
    return :affine_locked if symbol.locked?
    return :affine_write_locked if symbol.write_locked?
    return :affine_versioned if SymbolEntry.versioned_sync?(symbol.sync)

    nil
  end

  sig { params(symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def boundary_capture_scheduler_affine?(symbol)
    return false unless symbol
    return true if symbol.local?
    return false if boundary_capture_shared_arc?(symbol)

    symbol.locked? || symbol.write_locked? || SymbolEntry.versioned_sync?(symbol.sync)
  end

  sig { params(symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def boundary_capture_requires_pinned?(symbol)
    boundary_capture_scheduler_affine?(symbol) || boundary_capture_multiowned_rc?(symbol)
  end

  sig { params(symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def boundary_capture_shared_arc?(symbol)
    return false unless symbol

    type_info = symbol.type
    return true if type_info.respond_to?(:shared?) && type_info.shared?

    symbol.storage == :shared
  end

  sig { params(symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def boundary_capture_multiowned_rc?(symbol)
    return false unless symbol

    type_info = symbol.type
    return true if type_info.respond_to?(:multiowned?) && type_info.multiowned?

    symbol.storage == :multiowned
  end

  sig { params(node: AST::DoBlock).returns(MIR::DoBlock) }
  def lower_do_block(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @do_block_counter = T.let(@do_block_counter, T.untyped)
    @do_block_counter = (@do_block_counter || 0) + 1
    id = @do_block_counter - 1
    n = node.branches.length
    wg_var = "__do#{id}_wg"

    all_branch_bodies = []
    boundary_facts = T.let([], T::Array[MIR::ExecutionBoundaryFact])
    branch_parts = node.branches.each_with_index.map { |branch, i|
      ctx_type = "__DoBranchCtx#{id}_#{i}"
      ctx_var = "__do#{id}_ctx#{i}"
      analysis = branch[:capture_analysis]
      pinned = branch[:pinned]
      if analysis
        AST.each_capture_analysis(branch[:body]) do |nested|
          next if nested.equal?(analysis)
          analysis.captures ||= {}
          analysis.capture_symbols ||= {}
          analysis.close_patterns ||= {}
          analysis.pointer_captures ||= Set.new
          analysis.string_captures ||= Set.new
          analysis.resource_captures ||= Set.new
          analysis.captures.merge!(nested.captures || {}) { |_k, old, _new| old }
          analysis.capture_symbols.merge!(nested.capture_symbols || {}) { |_k, old, _new| old }
          analysis.close_patterns.merge!(nested.close_patterns || {}) { |_k, old, _new| old }
          analysis.pointer_captures.merge(nested.pointer_captures || Set.new)
          analysis.string_captures.merge(nested.string_captures || Set.new)
          analysis.resource_captures.merge(nested.resource_captures || Set.new)
        end
      end
      boundary_facts << execution_boundary_fact(
        :do_branch,
        execution_boundary_dispatch(branch[:parallel], pinned),
        analysis,
      )

      # Capture handling delegated to FiberCtxBuilder -- same builder
      # BG/BG STREAM/CONCURRENT use. DO branches use "ctx" as the body
      # access prefix (no per-id suffix).
      caps = FiberCtxBuilder.build(analysis, body_access_prefix: "ctx", fresh_heap_id: (id * 1000) + i, schema_lookup: @schema_lookup)

      capture_fields = (caps.specs.map { |s| "#{s.name}: #{s.field_type_zig}," } +
                        capture_moved_guard_fields(caps.specs)).join("\n    ")
      capture_inits = ([".wg = &#{wg_var}"] +
        caps.specs.map { |s| ".#{s.name} = #{s.init_value_zig}" }).join(", ")
      capture_pre_decls = caps.specs.filter_map(&:dupe_decl_zig).join("\n        ")
      capture_body_cleanups = caps.specs.filter_map(&:body_cleanup_zig).join("\n                ")

      # Lower branch body to MIR nodes, finalize ownership once, then emit from
      # that same finalized body. Branch-local allocating temporaries must not
      # be hidden inside already-rendered Zig.
      branch_mir = T.let(nil, T.untyped)
      body_code = with_fiber_capture_map(caps.capture_map,
                                         capture_symbols: caps.capture_symbols,
                                         rt_override: "__rt") do
        body_stmts = branch[:body].flat_map { |e|
          mir = lower(e)
          nodes = mir.is_a?(Array) ? mir.compact : do_branch_stmt_nodes(e, mir)
          nodes.compact
        }
        branch_mir = finalized_boundary_body_for_emit(body_stmts)
        render_mir_list(branch_mir).gsub("\n", "\n        ")
      end
      all_branch_bodies << (branch_mir || [])

      task_cfg = task_config_zig(branch[:stack_size], branch[:computed_stack_tier])
      spawn_fn = pinned ? "try #{wg_var}.sched.submitSpawn" : "try CheatHeader.spawnBest"

      <<~ZIG.chomp
        const #{ctx_type} = struct {
            wg: *CheatHeader.WaitGroup,
            #{capture_fields}
            fn run(__raw_rt_do#{id}_#{i}: *anyopaque, __raw_args_do#{id}_#{i}: ?*anyopaque) anyerror!void {
                const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_do#{id}_#{i})));
                #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_do#{id}_#{i}.?)));
                defer ctx.wg.done();
                #{capture_body_cleanups}
                #{body_code}
            }
        };
        #{capture_pre_decls}
        var #{ctx_var} = #{ctx_type}{ #{capture_inits} };
        #{spawn_fn}(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
            &#{ctx_var},
            #{task_cfg}
        );
        #{wg_var}.add(1);
      ZIG
    }

    inner = branch_parts.join("\n")
    do_code = <<~ZIG.chomp
      {
          var #{wg_var} = CheatHeader.WaitGroup.init(rt.getSched());
          errdefer #{wg_var}.wait();
          #{inner}
      #{wg_var}.wait();
      }
    ZIG
    do_block = MIR::DoBlock.new(do_code, all_branch_bodies)
    do_block.boundary_facts = boundary_facts
    do_block
  end

  sig { params(expr: T.untyped, mir: T.untyped).returns(T::Array[T.untyped]) }
  def do_branch_stmt_nodes(expr, mir)
    T.bind(self, MIRLowering) rescue nil
    if mir.is_a?(MIR::BgBlock)
      @tmp_counter += 1
      name = "__discard_bg_#{@tmp_counter}"
      next_contract = MIR::CallableContract.new(
        MIR::CallableContract.no_ownership(0).signature,
        MIR::OwnershipContract.consume_operands([
          MIR::OwnershipOperandFact.owned_binding(name, Type.new(:Any), "DO branch BG discard", :heap),
        ]),
        0,
      )
      return [
        MIR::Let.new(name, mir, false, nil, nil),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(MIR::Ident.new(name), "next", [], true, next_contract),
          true,
        ),
      ]
    end

    [wrap_step_as_stmt({ expr: expr, binding: nil }, mir)]
  end

  sig { params(node: AST::BgBlock).returns(MIR::BgBlock) }
  def lower_bg_block(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @bg_block_counter = T.let(@bg_block_counter, T.untyped)
    @current_bg_pointer_captures = T.let(@current_bg_pointer_captures, T.untyped)
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    @pending_stmts = T.let(@pending_stmts, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    @bg_block_counter = (@bg_block_counter || 0) + 1
    id = @bg_block_counter - 1

    tense_t = Type.new(node.full_type!)
    async_shape = T.unsafe(node).async_result_shape || AsyncResultShape.promise(tense_t.tense_type, shared: tense_t.shared_promise?)
    inner_t = Type.new(async_shape.payload_type)
    inner_zig = inner_t.zig_type
    promise_zig = async_shape.handle_zig_type
    is_void = inner_zig == "void"

    ctx_type = "__BgCtx#{id}"
    alloc_var = "__bg#{id}_alloc"
    promise_var = "__bg#{id}_promise"
    ctx_var = "__bg#{id}_ctx"
    blk_label = "__bg#{id}"
    bg_rt = "__rt_bg#{id}"

    analysis = node.capture_analysis
    captured = analysis&.captures || {}
    capture_close_zig = analysis&.close_patterns || {}
    pointer_captures = analysis&.pointer_captures || Set.new

    rt_name = @rt_name

    # Strategies + site_info come from BgCaptureClassifier (one writer,
    # all consumers read). lower_bg_block reads from
    # analysis.strategies directly -- enforce_bg_capture_strategies!
    # below picks up the same field.
    enforce_bg_capture_strategies!(node, captured)

    # Capture handling delegated to FiberCtxBuilder -- the same builder
    # DO branches and pipeline_host CONCURRENT callbacks call. Only the
    # site-specific control fields (Promise.inner / alloc) and the
    # body access prefix (__ctx_<id> for BG) are added here.
    promoted_names = T.let({}, T::Hash[String, String])
    outer_capture_map = @do_capture_map || {}
    caps = FiberCtxBuilder.build(analysis,
                                 body_access_prefix: "__ctx_#{id}",
                                 promoted_names: promoted_names,
                                 fresh_heap_alloc: alloc_var,
                                 fresh_heap_id: id,
                                 source_overrides: outer_capture_map,
                                 schema_lookup: @schema_lookup)

    # If this BG sits inside an outer fiber/FSM whose capture_map
    # rewrites the surrounding scope's identifiers (e.g. an outer
    # FSM-NEXT chain stores cross-suspend values in __ctx_OUTER.X),
    # the bare-name init AND the @TypeOf(...) field type below must
    # use that rewritten reference too — the outer name is no longer
    # in scope at the spawn site, only the rewritten one is.
    # FreshHeapCopy dupes already point to a local generated above the
    # spawn, so they don't need rewriting.
    capture_fields = caps.specs.map { |s|
      ftype = if s.dupe_decl_zig || promoted_names[s.name] || outer_capture_map[s.name].nil?
                s.field_type_zig
              else
                # @TypeOf(<outer_ref>) so the field type resolves under the
                # rewritten scope (e.g. @TypeOf(__ctx_0.x) instead of
                # @TypeOf(x)).
                s.field_type_zig.sub(/\(#{Regexp.escape(s.name)}\)/, "(#{outer_capture_map[s.name]})")
      end
      "#{s.name}: #{ftype},"
    }
    capture_fields = (capture_fields + capture_moved_guard_fields(caps.specs)).join("\n        ")
    capture_inits = ([".inner = #{promise_var}.inner", ".alloc = #{alloc_var}"] +
                     caps.specs.map { |s|
                       outer_ref = outer_capture_map[s.name]
                       init_val = if s.dupe_decl_zig || promoted_names[s.name] || outer_ref.nil?
                                    s.init_value_zig
                                  else
                                    outer_ref
                                  end
                       ".#{s.name} = #{init_val}"
                     }).join(", ")
    fresh_heap_decls = caps.specs.filter_map(&:dupe_decl_zig).join("\n        ")
    fresh_heap_cleanups = caps.specs.filter_map(&:body_cleanup_zig).join("\n                    ")
    fresh_heap_cleanup_names = caps.specs.filter_map { |spec| spec.body_cleanup_zig ? spec.name : nil }

    # Flatten ThenChain + lower body
    flat_steps = []
    node.body.each { |stmt|
      if stmt.is_a?(AST::ThenChain)
        stmt.steps.each { |s| flat_steps << s }
      else
        flat_steps << { expr: stmt, binding: nil }
      end
    }
    last_step = flat_steps.pop
    pre_steps = flat_steps

    # Rewrite captured variable references and rt inside the fiber body
    prev_bg_ptr_caps = @current_bg_pointer_captures
    @current_bg_pointer_captures = pointer_captures
    # Lower the fiber body to MIR nodes (for checker visibility) and build Zig strings.
    # run_body carries the MIR stmts so the checker can walk allocations inside the fiber.
    # Save outer @pending_stmts: hoists from fiber body (e.g. auto-COPY string fields in
    # OR fallback struct literals) must be emitted INSIDE the fiber's run function, not in
    # the outer function where Zig's inner-function capture rules would reject them.
    run_body = T.let(nil, T.untyped)
    prev_fiber_pending = @pending_stmts
    @pending_stmts = []
    stmt_code, result_line = with_fiber_capture_map(caps.capture_map,
                                                    capture_symbols: caps.capture_symbols,
                                                    rt_override: bg_rt) do
      body_mir = []
      sc = pre_steps.flat_map { |step|
        mir = lower(step[:expr])
        step_pending = flush_pending
        body_mir.concat(step_pending)

        # `lower_var_decl` may return [AllocMark, Let, Cleanup] when the
        # binding needs cleanup (e.g. `snapshot = COPY items` inside a
        # BG body). Each element is its own MIR statement; AllocMark /
        # Cleanup are checker-visible markers that emit no code.
        mir_nodes = mir.is_a?(Array) ? mir.compact : [mir]
        step[:binding] ? body_mir << MIR::Let.new(step[:binding], mir_nodes.last, false, nil, nil) : body_mir.concat(mir_nodes)

        pending_code = step_pending.filter_map { |p| c = emit_expr(p); (c.nil? || c.empty?) ? nil : c }
        emit_lines = mir_nodes.filter_map.with_index do |m, i|
          code = emit_expr(m)
          # AllocMark and other verification-only nodes emit nil -- skip them.
          next nil if code.nil?
          if step[:binding] && i == mir_nodes.size - 1
            "const #{step[:binding]} = #{code};"
          elsif code.strip.end_with?(";") || code.strip.end_with?("}")
            code
          else
            expr_type = step[:expr].full_type!
            is_void_step = ast_void_type?(expr_type)
            is_void_step ? "#{code};" : "_ = #{code};"
          end
        end
        pending_code + emit_lines
      }.join("\n            ")

      last_is_assign = last_step && last_step[:expr].is_a?(AST::Assignment)
      rl = if last_step.nil? || is_void || last_is_assign
        if last_step
          last_mir = lower(last_step[:expr])
          last_pending = flush_pending
          body_mir.concat(last_pending)
          body_mir << last_mir
          last_code = emit_expr(last_mir)
          pending_code = last_pending.filter_map { |p| c = emit_expr(p); (c.nil? || c.empty?) ? nil : c }.join("\n            ")
          stmt = (T.must(last_code).strip.end_with?("}") || T.must(last_code).strip.end_with?(";")) ? last_code : "#{last_code};"
          pending_code.empty? ? stmt : "#{pending_code}\n            #{stmt}"
        else
          ""
        end
      else
        result_alloc = escaping_value_alloc(inner_t)
        last_mir = with_decl_alloc(result_alloc) { lower(last_step[:expr]) }
        last_mir = place_value_for_destination(last_mir, last_step[:expr], result_alloc, inner_t)
        last_mir = hoist_alloc(last_mir, last_step[:expr], err_cleanup: true) if last_mir && mir_allocates?(last_mir)
        last_pending = flush_pending
        body_mir.concat(last_pending)
        result_code = emit_expr(last_mir)
        pending_code = last_pending.filter_map { |p| c = emit_expr(p); (c.nil? || c.empty?) ? nil : c }.join("\n            ")
        result_code = T.must(result_code).sub(/\Atry /, '') if T.must(result_code).start_with?("try ")
        result_target = MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new("__ctx_#{id}"), "inner"), "result")
        body_mir.concat(ownership_marks_for_transferred_temp(last_mir, target_alloc: :heap))
        body_mir << MIR::Set.new(result_target, last_mir)
        assignment = "__ctx_#{id}.inner.result = #{result_code};"
        pending_code.empty? ? assignment : "#{pending_code}\n            #{assignment}"
      end
      run_body = finalized_boundary_body_for_emit(capture_ownership_mirror_nodes(caps, analysis, "__ctx_#{id}") + body_mir)
      [sc, rl]
    end
    @pending_stmts = prev_fiber_pending
    @current_bg_pointer_captures = prev_bg_ptr_caps

    arena_init = node.arena_mode ? "#{bg_rt}.arena_mode = true;" : ""

    capture_frees = captured.filter_map { |name, _|
      if capture_close_zig[name]
        "defer #{capture_close_zig[name].gsub('{0}', "__ctx_#{id}.#{name}")};"
      end
    }.join("\n                    ")
    capture_frees = [capture_frees, fresh_heap_cleanups].reject(&:empty?).join("\n                    ")

    promoted_decls = fresh_heap_decls

    task_cfg = task_config_zig(node.stack_size, node.computed_stack_tier)
    pin_mode = node.respond_to?(:pinned) ? node.pinned : nil
    bg_site_id = id + 1
    bg_site_line = node.token&.line || 0
    bg_site_col = node.token&.column || 0

    # Universal transform path (CLAUDE.md Invariant 13). The
    # transform inspects the AST body via Segments.split, produces
    # a typed segment graph, and Emit.build builds the wrapper
    # body. Runs FIRST -- before any per-shape use_fsm_* branch --
    # so shape detection lives in one place. Returns nil for
    # graphs the transform doesn't yet cover; the matching legacy
    # branch below fires for those. As migration stages land, the
    # nil-returning surface shrinks until the legacy branches are
    # deleted entirely (Stage 4).
    #
    # The transform handles per-shape pin_mode constraints
    # itself: B1 / B2-IO / B2-NEXT-CHAIN reject :shared (matching
    # legacy use_fsm / use_fsm_io / use_fsm_next), B2-WITH
    # accepts :shared (matching legacy use_fsm_with). The outer
    # guard is just `spawn_form == :fsm`.
    # Skip the FSM transform for the :bc target. The bytecode VM has no
    # state-machine runtime; the FSM path consumes the body into Zig text
    # and leaves run_body=[] which the bc emitter cannot lower. The
    # legacy stackful-fiber lowering below populates run_body so the bc
    # emitter has structured MIR to walk -- the BG body executes
    # synchronously inline in the bc VM (single-threaded, deterministic).
    if node.spawn_form == :fsm && @target != :bc
      transform_ctx = {
        node: node,
        blk_label: blk_label, ctx_type: ctx_type, promise_zig: promise_zig,
        id: id, bg_rt: bg_rt, capture_fields: capture_fields,
        captured: captured, capture_close_zig: capture_close_zig,
        pointer_captures: pointer_captures,
        stmt_code: stmt_code, result_line: result_line,
        capture_frees: capture_frees, arena_init: arena_init,
        # FreshHeapCopy body cleanups (master's `defer CheatLib.cleanup
        # (...)` lines) need to lift to destroyTask in the FSM path so
        # they fire once when the ctx tears down, not on each segment
        # return. Thread them separately from capture_frees so the
        # transform can emit them as destroy lines (see emit.rb).
        fresh_heap_cleanups: fresh_heap_cleanups,
        fresh_heap_cleanup_names: fresh_heap_cleanup_names,
        is_void: is_void, alloc_var: alloc_var, promise_var: promise_var,
        ctx_var: ctx_var, promoted_decls: promoted_decls,
        capture_inits: capture_inits, rt_name: rt_name, pin_mode: pin_mode,
        parallel: !!node.parallel,
        profile_site_id: bg_site_id, profile_line: bg_site_line,
        profile_column: bg_site_col,
        inner_zig: inner_zig, arena_init_flag: !!node.arena_mode,
      }
      transform_result = FsmTransform.transform(node, transform_ctx, self)
      return fsm_bg_block_from_transform!(node, transform_result, captured, analysis) if transform_result
    end

    # Non-FSM BG bodies and FSM shapes not yet covered by FsmTransform lower to
    # the stackful fiber path below. This is a distinct execution model, not a
    # verifier shortcut: run_body remains structured MIR so ownership is still
    # visible to MIRChecker.

    bg_dispatch = node.parallel ? :parallel : ((pin_mode == false || pin_mode.nil?) ? :local : pin_mode)
    profiled_task_cfg = task_config_with_profile(task_cfg, bg_site_id, bg_dispatch)
    spawn_call = fiber_spawn_call_zig(rt_name, ctx_type, ctx_var, profiled_task_cfg, bg_dispatch)
    profile_comment = bg_profile_site_comment(bg_site_id, bg_site_line, bg_site_col, bg_dispatch, :stack)

    bg_code = <<~ZIG.chomp
      #{blk_label}: {
          #{profile_comment}
          const #{ctx_type} = struct {
              inner: *#{promise_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_#{id}: *anyopaque, __raw_args_#{id}: ?*anyopaque) anyerror!void {
                  const #{bg_rt} = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_#{id})));
                  #{(stmt_code + result_line + capture_frees + arena_init).include?(bg_rt) ? "" : "_ = &#{bg_rt};"}
                  #{arena_init}
                  const __ctx_#{id} = @as(*@This(), @ptrCast(@alignCast(__raw_args_#{id}.?)));
                  defer __ctx_#{id}.alloc.destroy(__ctx_#{id});
                  defer __ctx_#{id}.inner.wg.done();
                  errdefer |fiber_err| __ctx_#{id}.inner.result = fiber_err;
                  #{capture_frees}
                  #{stmt_code}
                  #{result_line}
                  #{is_void ? "__ctx_#{id}.inner.result = {};" : ""}
              }
          };
          const #{alloc_var} = #{node.pinned == true || node.pinned == :local ? "#{rt_name}.getSched().allocator" : "#{rt_name}.heapAlloc()"};
          const #{promise_var} = try #{promise_zig}.spawn(#{alloc_var}, #{rt_name}.getSched());
          #{promoted_decls}
          const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
          errdefer #{alloc_var}.destroy(#{ctx_var});
          #{ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{blk_label} #{promise_var};
      }
    ZIG
    bg = MIR::BgBlock.new(bg_code, captured, run_body || [])
    bg.result_type = Type.new(node.full_type!)
    bg.boundary_fact = execution_boundary_fact(
      :bg,
      execution_boundary_dispatch(node.parallel, node.pinned),
      analysis,
    )
    bg
  end

  # Raise a CLEAR-level diagnostic if any capture classifies as Refuse.
  # This is the rule enforcement step — refusing at lowering time stops
  # the dangling-pointer family of bugs (docs/agents/vm-bugs.md) from
  # producing silent UAFs. Users must write GIVE / COPY / CLONE inside
  # the BG body to transfer ownership, or wrap the container in
  # @shared:locked / @multiowned for shared access.
  sig { params(node: T.any(AST::BgBlock, AST::BgStreamBlock), _captured: T::Hash[String, Type]).void }
  def enforce_bg_capture_strategies!(node, _captured)
    T.bind(self, MIRLowering) rescue nil
    refused = (node.capture_analysis&.strategies || {}).select do |_name, strat|
      strat.is_a?(CaptureStrategy::Refuse)
    end
    return if refused.empty?
    lines = refused.map do |name, strat|
      hint = case strat.reason
             when :pointer_passed_without_transfer
               "'#{name}' is @pool/@map/HashMap — wrap in @shared:locked, or GIVE/COPY inside the BG body."
             when :list_borrow_without_transfer
               "'#{name}' is @list — GIVE inside the BG body to transfer ownership, or COPY to deep-copy."
             when :pool_borrow_without_transfer
               "'#{name}' is @pool — wrap in @shared:locked, or GIVE inside the BG body."
             when :array_borrow_without_transfer
               "'#{name}' is a slice borrow — COPY inside the BG body for a fresh heap copy."
             when :heap_backed_without_transfer
               "'#{name}' is heap-backed — GIVE/COPY inside the BG body, or use @multiowned/@shared."
             else
               "'#{name}' cannot be safely captured (#{strat.reason})."
             end
      "  - #{hint}"
    end
    raise "BG block captures values that cannot safely cross the fiber boundary:\n" +
          lines.join("\n") +
          "\n(See docs/agents/vm-bugs.md for the ownership rules.)"
  end

  sig do
    params(
      node: AST::BgBlock,
      transform_result: T.untyped,
      captured: T::Hash[String, Type],
      analysis: T.untyped,
    ).returns(MIR::BgBlock)
  end
  def fsm_bg_block_from_transform!(node, transform_result, captured, analysis)
    unless transform_result.is_a?(MIR::FsmLoweringResult)
      Kernel.raise "FSM lowering must return MIR::FsmLoweringResult; rendered Zig without typed FSM structure is unverifiable"
    end
    bg_code = transform_result.code
    fsm_structure = transform_result.structure
    moved_captures = (analysis&.move_mark_names || Set.new).map(&:to_s) & captured.keys.map(&:to_s)
    fsm_structure.required_move_guards = moved_captures
    result_type = Type.from_node!(node, context: "FSM BG result").tense_type
    fsm_structure.owned_result_required =
      !!(result_type && T.unsafe(self).ownership_tracked_transfer_type?(result_type))
    MIRChecker.check_fsm_structure!(fsm_structure, source: node)
    # The fiber body is consumed into the FSM state machine. Exposing it again
    # through run_body would double-walk ownership and manufacture diagnostics.
    bg = MIR::BgBlock.new(bg_code, captured, [], fsm_structure)
    bg.result_type = Type.new(node.full_type!)
    bg.boundary_fact = execution_boundary_fact(
      :bg,
      execution_boundary_dispatch(node.parallel, node.pinned),
      analysis,
    )
    bg
  end

  sig { params(node: AST::BgStreamBlock).returns(T.any(MIR::BgBlock, MIR::BlockExpr, MIR::InlineBc, MIR::StreamSpawn)) }
  def lower_bg_stream_block(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_stream_is_inf = T.let(@current_stream_is_inf, T.untyped)
    @current_stream_local = T.let(@current_stream_local, T.untyped)
    @current_expected_type = T.let(@current_expected_type, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    @stream_gen_counter = T.let(@stream_gen_counter, T.untyped)
    @target = T.let(@target, T.untyped)
    @stream_gen_counter = (@stream_gen_counter || 0) + 1
    id = @stream_gen_counter - 1

    expected_t = Type.from_node(@current_expected_type)
    tense_t = bg_stream_expected_type?(expected_t) ? T.must(expected_t) : Type.new(node.full_type!)
    is_inf = tense_t.inf_stream?
    stream_zig = tense_t.zig_type

    ctx_type = "__SgCtx#{id}"
    alloc_var = "__sg#{id}_alloc"
    stream_var = "__sg#{id}_stream"
    ctx_var = "__sg#{id}_ctx"
    blk_label = "__sg#{id}"
    local_stream = "__sg#{id}_local"

    # BC backend: there are no real coroutines, so model the stream as
    # an eager List materialization. Run the body inline; YIELD becomes
    # `__sg<id>_local.push(x)` which we rewrite to list-append in the
    # bc_emitter, and NEXT pops the head of the list. This works for all
    # finite streams. For ~T[INF] (`WHILE TRUE`-driven generators) the
    # eager path would loop forever, so we emit a producer-fiber +
    # rendezvous-channel form (MIR::StreamSpawn / MIR::StreamYield)
    # that the bc_emitter compiles to STREAM_SPAWN + STREAM_YIELD opcodes.
    if @target == :bc
      prev_stream_local = @current_stream_local
      prev_stream_is_inf = @current_stream_is_inf
      @current_stream_local = T.let(local_stream, T.nilable(String))
      @current_stream_is_inf = T.let(is_inf, T.nilable(T::Boolean))
      run_body = node.body.map { |expr| lower(expr) }
      @current_stream_local = prev_stream_local
      @current_stream_is_inf = prev_stream_is_inf

      if is_inf
        # Real producer fiber. The captures handed to FiberCtxBuilder
        # become the fiber's captures; bc_emitter prepends the channel
        # handle as arg 0 inside STREAM_SPAWN and inside the producer
        # frame the channel binds to a synthetic slot consumed by
        # MIR::StreamYield via lower_yield.
        captures_map = node.capture_analysis&.captures || {}
        spawn = MIR::StreamSpawn.new(captures_map, run_body)
        spawn.boundary_fact = execution_boundary_fact(:stream_spawn, :local, node.capture_analysis)
        return spawn
      end

      block = MIR::BlockExpr.new(blk_label, [
        MIR::Let.new(local_stream, MIR::MakeList.new("anytype", [], :frame), true, "anytype", nil),
        *run_body,
        MIR::BreakStmt.new(blk_label, MIR::Ident.new(local_stream))
      ])
      # @split: wrap the materialized list in a Value.SplitStream so the
      # value carries a per-handle cursor. CLONE on a split stream then
      # produces an independent handle pointing at the same buffer.
      if tense_t.split_open_stream?
        return MIR::InlineBc.new(:split_stream_new, [block], { tag: :split_stream })
      end
      return block
    end

    analysis = node.capture_analysis
    rt_name = @rt_name
    enforce_bg_capture_strategies!(node, analysis&.captures || {})

    # Capture handling delegated to FiberCtxBuilder -- same builder
    # BG/DO/CONCURRENT use. BG STREAM's site-specific extras are the
    # control fields (stream_inner / alloc) and "ctx" body prefix.
    promoted_names = T.let({}, T::Hash[String, String])
    caps = FiberCtxBuilder.build(analysis,
                                 body_access_prefix: "ctx",
                                 promoted_names: promoted_names,
                                 fresh_heap_alloc: alloc_var,
                                 fresh_heap_id: id,
                                 schema_lookup: @schema_lookup)

    capture_fields = (caps.specs.map { |s| "#{s.name}: #{s.field_type_zig}," } +
                      capture_moved_guard_fields(caps.specs)).join("\n        ")
    capture_inits = ([".stream_inner = #{stream_var}.inner", ".alloc = #{alloc_var}"] +
                     caps.specs.map { |s| ".#{s.name} = #{s.init_value_zig}" }).join(", ")

    # Save/restore stream context for YieldExpr
    prev_stream_local = @current_stream_local
    prev_stream_is_inf = @current_stream_is_inf
    @current_stream_local = T.let(local_stream, T.nilable(String))
    @current_stream_is_inf = T.let(is_inf, T.nilable(T::Boolean))

    # Lower stream body to MIR nodes (for checker visibility) and build Zig strings.
    stream_run_body = T.let(nil, T.untyped)
    body_code = with_fiber_capture_map(caps.capture_map,
                                       capture_symbols: caps.capture_symbols,
                                       rt_override: "__rt") do
      body_mir = node.body.flat_map { |expr|
        mir = lower(expr)
        pending = flush_pending
        mir_nodes = mir.is_a?(Array) ? mir.compact : [mir]
        pending + mir_nodes
      }
      stream_run_body = finalized_boundary_body_for_emit(capture_ownership_mirror_nodes(caps, analysis, "ctx") + body_mir)
      stream_run_body.filter_map { |mir|
        next nil if capture_ownership_mirror_node?(mir, "ctx")
        code = emit_expr(mir)
        next nil if code.nil? || code.empty?
        code = code + ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
        code
      }.join("\n            ")
    end

    @current_stream_local = prev_stream_local
    @current_stream_is_inf = prev_stream_is_inf

    promoted_decls = caps.specs.filter_map(&:dupe_decl_zig).join("\n        ")
    string_frees = caps.specs.filter_map(&:body_cleanup_zig).join("\n                  ")

    task_cfg = task_config_zig(node.stack_size, node.computed_stack_tier)
    spawn_call = fiber_spawn_call_zig(rt_name, ctx_type, ctx_var, task_cfg, :local)

    sg_code = <<~ZIG.chomp
      #{blk_label}: {
          const #{ctx_type} = struct {
              stream_inner: *#{stream_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_sg#{id}: *anyopaque, __raw_args_sg#{id}: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_sg#{id})));
                  #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_sg#{id}.?)));
                  defer ctx.alloc.destroy(ctx);
                  #{string_frees}
                  var #{local_stream} = #{stream_zig}{ .inner = ctx.stream_inner, .alloc = ctx.alloc };
                  defer #{local_stream}.close();
                  errdefer |gen_err| #{local_stream}.inner.err = gen_err;
                  #{body_code}
              }
          };
          const #{alloc_var} = #{rt_name}.getSched().allocator;
          const #{stream_var} = try #{stream_zig}.spawnNew(#{alloc_var}, #{rt_name}.getSched());
          #{promoted_decls}
          const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
          errdefer #{alloc_var}.destroy(#{ctx_var});
          #{ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{blk_label} #{stream_var};
      }
    ZIG
    bg = MIR::BgBlock.new(sg_code, analysis&.captures || {}, stream_run_body || [])
    bg.result_type = Type.new(tense_t)
    bg.boundary_fact = execution_boundary_fact(:bg_stream, :local, analysis)
    bg
  end

  sig { params(node: AST::YieldExpr).returns(T.untyped) }
  def lower_yield(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_stream_is_inf = T.let(@current_stream_is_inf, T.untyped)
    @current_stream_local = T.let(@current_stream_local, T.untyped)
    @target = T.let(@target, T.untyped)
    stream_local = @current_stream_local || "__stream_local"
    lowered = with_decl_alloc(:heap) do
      value = lower(node.expr)
      place_value_for_destination(value, node.expr, :heap, node.expr.full_type!)
    end
    lowered = hoist_alloc(lowered, node.expr, err_cleanup: true) if lowered && mir_allocates?(lowered)
    transfer_marks = ownership_marks_for_transferred_temp(lowered, target_alloc: :heap)
    # BC inf-stream path: emit MIR::StreamYield so the bc_emitter routes
    # to the rendezvous-channel STREAM_YIELD opcode. The Zig backend
    # never reaches this branch (it sets @current_stream_is_inf only for
    # the materializing path; @target check guards against confusion).
    if @target == :bc && @current_stream_is_inf
      stream_yield = MIR::StreamYield.new(lowered)
      return transfer_marks.empty? ? stream_yield : MIR::ScopeBlock.new([*transfer_marks, stream_yield])
    end
    # The yielded value is a hoisted, escape-placed binding (Hoist lifts
    # anonymous YIELD operands; escape analysis marks it heap because it
    # escapes the fiber). The stream owns it; the consumer frees it. No
    # dupe -- one allocation, placed by escape analysis.
    push = MIR::MethodCall.new(MIR::Ident.new(stream_local), "push", [lowered], true,
      MIR::CallableContract.no_ownership(1))
    # YIELD transfers ownership to the stream at the push boundary. InfStream
    # owns and cleans the value even if push returns StreamClosed, so the local
    # error cleanup must be disarmed before the fallible call.
    transfer_marks.empty? ? push : MIR::ScopeBlock.new([*transfer_marks, MIR::ExprStmt.new(push, false)])
  end

  sig { params(promise_type: Type, result_type: Type, fallback_alloc: Symbol).returns(T.nilable(Symbol)) }
  def next_result_owned_alloc(promise_type, result_type, fallback_alloc)
    T.bind(self, MIRLowering) rescue nil
    @schema_lookup = T.let(@schema_lookup, T.untyped)
    return fallback_alloc if promise_type.promise_list?
    return fallback_alloc if promise_type.observable_array_future?
    return :heap if promise_type.observable? && ownership_bearing_type?(result_type)
    return :heap if ownership_bearing_type?(result_type)
    nil
  end

  sig { params(node: AST::NextExpr, alloc_sym: Symbol).returns(NextExprPlan) }
  def next_expr_plan(node, alloc_sym)
    T.bind(self, MIRLowering) rescue nil
    promise_type = Type.new(node.expr.full_type!)
    result_type = node.full_type!(context: "NEXT result")
    async_shape = node.expr.is_a?(AST::Identifier) ? node.expr.symbol&.async_result_shape : nil
    source_kind = if async_shape&.promise?
      async_shape.shared_promise? ? :shared_promise : :plain
    elsif promise_type.promise_list?
      :promise_list
    elsif promise_type.observable_array_future?
      :observable_list
    elsif promise_type.observable? && observable_next_string?(promise_type)
      :observable_string
    else
      :plain
    end
    NextExprPlan.new(
      source_kind: source_kind,
      promise_type: promise_type,
      async_result_shape: async_shape,
      result_type: result_type,
      result_alloc: next_result_owned_alloc(promise_type, result_type, alloc_sym),
      inner: T.cast(lower(node.expr), MIR::Node),
    )
  end

  sig { params(promise_type: Type).returns(T::Boolean) }
  def observable_next_string?(promise_type)
    tt = promise_type.tense_type
    wt = tt&.optional? ? tt.wrapped_type : tt
    !!wt&.string?
  end

  sig { params(type_info: T.nilable(Type)).returns(T::Boolean) }
  def bg_stream_expected_type?(type_info)
    return false unless type_info

    type_info.inf_stream? || type_info.open_stream? || type_info.bounded_stream?
  end

  sig { params(node: AST::NextExpr, alloc_sym: Symbol).returns(T.untyped) }
  def lower_next_expr(node, alloc_sym = :frame)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    @target = T.let(@target, T.untyped)
    @tmp_counter = T.let(@tmp_counter, T.untyped)
    plan = next_expr_plan(node, alloc_sym)
    promise_type = plan.promise_type
    result_t = plan.result_type

    if plan.promise_list?
      # NEXT on ~T[]@list: iterate the promise list, await each promise, collect results.
      # alloc_sym determines whether results are heap- or frame-allocated (caller passes
      # decl_alloc from the enclosing VarDecl so the allocator matches the cleanup plan).
      promise_list_inner = plan.inner

      # In BC the BG runtime spawns real fibers via BG_SPAWN and stashes
      # their futures in `futureTable`; the list elements are
      # Pair("__future__", id) markers, not yet-resolved values. Route
      # through MethodCall("next") so the bc_emitter emits AWAIT, which
      # the runner extends to walk Value.List (await each item, build
      # result list).
      if @target == :bc
        call = MIR::MethodCall.new(promise_list_inner, "next", [], true, MIR::CallableContract.no_ownership(0), alloc_sym)
        call.result_type = Type.new(result_t)
        return call
      end

      promise_list_inner_str = emit_expr(promise_list_inner)
      elem_zig = promise_type.tense_type.element_type.zig_type
      @tmp_counter += 1
      promise_list_label = "__next_all_#{@tmp_counter}"
      results_var = "__next_results_#{@tmp_counter}"
      alloc_fn = MIR::Placement.zig_allocator(alloc_sym, @rt_name)
      code = "#{promise_list_label}: {\n" \
             "    var #{results_var} = std.ArrayListUnmanaged(#{elem_zig}).empty;\n" \
             "    for (#{promise_list_inner_str}.items) |__p| {\n" \
             "        try #{results_var}.append(#{alloc_fn}, try __p.next());\n" \
             "    }\n" \
             "    break :#{promise_list_label} #{results_var};\n" \
             "}"
      iz = MIR::InlineZig.new(code, "next_promise_list")
      iz.stdlib_def = FunctionSignature.intrinsic_contract(return_type: Type.new(result_t), allocates: true)
      iz.allocs = { results_var => alloc_sym }
      return iz
    end

    # Collection observable (`~T[]@set:observable`): NEXT yields an owned
    # ArrayListUnmanaged(T) via `materializeNext(alloc)` rather than a
    # snapshot handle, so user code (`final = NEXT running`) gets
    # something it can iterate without explicit `.release()`. The
    # materialized list is placed by the receiving binding's allocator
    # (alloc_sym) -- one allocator per binding, like every other value.
    if plan.observable_list?
      observable_list_inner = plan.inner
      # The materialized list inherits the receiving binding's placement
      # alloc_sym is the
      # fallback when NEXT is lowered outside a binding.
      call = MIR::MethodCall.new(observable_list_inner, "materializeNext",
        [MIR::AllocatorRef.new(alloc_sym)], true, MIR::CallableContract.no_ownership(1), alloc_sym)
      call.result_type = Type.new(result_t)
      return call
    end

    if plan.observable_string?
      observable_string_inner = plan.inner
      @tmp_counter += 1
      observable_string_label = "__obs_next_string_#{@tmp_counter}"
      materialize = MIR::MethodCall.new(observable_string_inner, "materialize", [MIR::AllocatorRef.new(:heap)], true,
        MIR::CallableContract.no_ownership(1), :heap)
      materialize.result_type = Type.new(result_t)
      block = MIR::BlockExpr.new(observable_string_label, [
        MIR::ExprStmt.new(MIR::MethodCall.new(observable_string_inner, "wait", [], false,
          MIR::CallableContract.no_ownership(0)), nil),
        MIR::BreakStmt.new(observable_string_label, materialize),
      ])
      block.result_type = Type.new(result_t)
      return block
    end

    receiver = plan.inner
    if promise_type.stream? && !receiver.is_a?(MIR::Ident)
      @tmp_counter += 1
      label = "__next_recv_#{@tmp_counter}"
      temp = "__next_source_#{@tmp_counter}"
      return MIR::BlockExpr.new(label, [
        MIR::Let.new(temp, receiver, true, nil, nil),
        MIR::BreakStmt.new(label,
          MIR::MethodCall.new(MIR::Ident.new(temp), "next", [], true,
            MIR::CallableContract.no_ownership(0), plan.result_alloc)),
      ])
    end

    MIR::MethodCall.new(receiver, "next", [], true, MIR::CallableContract.no_ownership(0),
      plan.result_alloc)
  end


end
