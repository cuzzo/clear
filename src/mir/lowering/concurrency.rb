# typed: false
require "sorbet-runtime"

module MIRLoweringConcurrency
    extend T::Sig

  sig { params(node: AST::DoBlock).returns(MIR::DoBlock) }
  def lower_do_block(node)
    @do_block_counter = (@do_block_counter || 0) + 1
    id = @do_block_counter - 1
    n = node.branches.length
    wg_var = "__do#{id}_wg"

    all_branch_bodies = []
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

      # Capture handling delegated to FiberCtxBuilder -- same builder
      # BG/BG STREAM/CONCURRENT use. DO branches use "ctx" as the body
      # access prefix (no per-id suffix).
      caps = FiberCtxBuilder.build(analysis, body_access_prefix: "ctx")

      capture_fields = caps.specs.map { |s| "#{s.name}: #{s.field_type_zig}," }.join("\n    ")
      capture_inits = ([".wg = &#{wg_var}"] +
        caps.specs.map { |s| ".#{s.name} = #{s.init_value_zig}" }).join(", ")

      # Lower branch body to MIR nodes (for checker visibility) and emit Zig code.
      branch_mir = T.let(nil, T.untyped)
      body_code = with_fiber_capture_map(caps.capture_map,
                                         capture_symbols: caps.capture_symbols,
                                         rt_override: "__rt") do
        pairs = branch[:body].flat_map { |e|
          mir = lower(e)
          nodes = mir.is_a?(Array) ? mir.compact : [mir]
          nodes.map { |m| [e, m] }
        }
        body_stmts = pairs.map(&:last)
        branch_mir = body_stmts
        pairs.filter_map { |expr, mir|
          code = emit_expr(mir)
          next nil if code.nil? || code.empty?
          code = if code.strip.match?(/\A__bg\d+:/)
            @tmp_counter += 1
            discard_name = "__discard_bg_#{@tmp_counter}"
            "const #{discard_name} = #{code};\n        _ = try #{discard_name}.next();"
          elsif code.strip.end_with?(";")
            code
          elsif code.strip.end_with?("}")
            expr_type = expr.full_type
            is_void_expr = expr_type.nil? || expr_type == :Void ||
              (expr_type.respond_to?(:to_s) && Type.new(expr_type).zig_type == "void")
            is_void_expr = false if mir.is_a?(MIR::BgBlock)
            is_void_expr = false if code.strip.match?(/\A__bg\d+:/)
            is_void_expr ? code : "_ = #{code};"
          else
            code + ";"
          end
          code
        }.join("\n        ")
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
                #{body_code}
            }
        };
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
    MIR::DoBlock.new(do_code, all_branch_bodies)
  end

  sig { params(node: AST::BgBlock).returns(MIR::BgBlock) }
  def lower_bg_block(node)
    @bg_block_counter = (@bg_block_counter || 0) + 1
    id = @bg_block_counter - 1

    tense_t = Type.new(node.full_type)
    inner_t = Type.new(tense_t.tense_type)
    inner_zig = inner_t.zig_type
    promise_zig = tense_t.zig_type
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
                                 source_overrides: outer_capture_map)

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
    }.join("\n        ")
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
            expr_type = step[:expr].full_type
            is_void_step = expr_type.nil? || expr_type == :Void || (expr_type.respond_to?(:to_s) && Type.new(expr_type).zig_type == "void")
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
        result_alloc = inner_t.string? ? :heap : nil
        last_mir = with_decl_alloc(result_alloc) { lower(last_step[:expr]) }
        last_mir = place_value_for_destination(last_mir, last_step[:expr], result_alloc, inner_t)
        last_mir = hoist_alloc(last_mir, last_step[:expr], err_cleanup: true) if last_mir && mir_allocates?(last_mir)
        last_pending = flush_pending
        body_mir.concat(last_pending)
        body_mir << last_mir
        result_code = emit_expr(last_mir)
        pending_code = last_pending.filter_map { |p| c = emit_expr(p); (c.nil? || c.empty?) ? nil : c }.join("\n            ")
        result_code = T.must(result_code).sub(/\Atry /, '') if T.must(result_code).start_with?("try ")
        assignment = "__ctx_#{id}.inner.result = #{result_code};"
        pending_code.empty? ? assignment : "#{pending_code}\n            #{assignment}"
      end
      run_body = body_mir
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
        is_void: is_void, alloc_var: alloc_var, promise_var: promise_var,
        ctx_var: ctx_var, promoted_decls: promoted_decls,
        capture_inits: capture_inits, rt_name: rt_name, pin_mode: pin_mode,
        parallel: !!node.parallel,
        profile_site_id: bg_site_id, profile_line: bg_site_line,
        profile_column: bg_site_col,
        inner_zig: inner_zig, arena_init_flag: !!node.arena_mode,
      }
      transform_result = FsmTransform.transform(node, transform_ctx, self)
      if transform_result
        bg_code, fsm_structure = transform_result
        MIRChecker.check_fsm_structure!(fsm_structure, source: node) if fsm_structure
        # Match legacy emit_fsm_*_bg_code call sites: pass [] for
        # run_body. The fiber body is consumed inside the FSM
        # state machine; exposing it again to the BgBlock-level
        # checker double-walks ownership and triggers spurious
        # diagnostics.
        return MIR::BgBlock.new(bg_code, captured, [], fsm_structure)
      end
    end

    # All FSM-eligible BG bodies route through FsmTransform above
    # (CLAUDE.md Invariant 13). If the transform returned nil, the
    # body falls outside the universal transform's coverage today
    # (e.g. nested suspends inside a user fn call) and lowers to a
    # stackful fiber via the standard spawn path below. The legacy
    # use_fsm_io / use_fsm_next / use_fsm_with / use_fsm branches +
    # find_fsm_*_split shape detectors + emit_fsm_*_bg_code emit
    # functions are still available in fsm_lowering.rb so Stage 3
    # delegation works; Stage 4b inlines them into Emit.build_*
    # and deletes them.

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
    MIR::BgBlock.new(bg_code, captured, run_body || [])
  end

  # Raise a CLEAR-level diagnostic if any capture classifies as Refuse.
  # This is the rule enforcement step — refusing at lowering time stops
  # the dangling-pointer family of bugs (docs/agents/vm-bugs.md) from
  # producing silent UAFs. Users must write GIVE / COPY / CLONE inside
  # the BG body to transfer ownership, or wrap the container in
  # @shared:locked / @multiowned for shared access.
  sig { params(node: T.any(AST::BgBlock, AST::BgStreamBlock), _captured: T::Hash[String, Type]).void }
  def enforce_bg_capture_strategies!(node, _captured)
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

  sig { params(node: AST::BgStreamBlock).returns(T.any(MIR::BgBlock, MIR::BlockExpr, MIR::InlineBc, MIR::StreamSpawn)) }
  def lower_bg_stream_block(node)
    @stream_gen_counter = (@stream_gen_counter || 0) + 1
    id = @stream_gen_counter - 1

    tense_t = Type.new(node.full_type)
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
        return MIR::StreamSpawn.new(captures_map, run_body)
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
                                 promoted_names: promoted_names)

    capture_fields = caps.specs.map { |s| "#{s.name}: #{s.field_type_zig}," }.join("\n        ")
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
        mir.is_a?(Array) ? mir.compact : [mir]
      }
      stream_run_body = body_mir
      body_mir.filter_map { |mir|
        code = emit_expr(mir)
        next nil if code.nil? || code.empty?
        code = code + ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
        code
      }.join("\n            ")
    end

    @current_stream_local = prev_stream_local
    @current_stream_is_inf = prev_stream_is_inf

    promoted_decls = ""
    string_frees = ""

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
    MIR::BgBlock.new(sg_code, analysis&.captures || {}, stream_run_body || [])
  end

  sig { params(node: AST::YieldExpr).returns(T.any(MIR::MethodCall, MIR::StreamYield)) }
  def lower_yield(node)
    stream_local = @current_stream_local || "__stream_local"
    lowered = lower(node.expr)
    # BC inf-stream path: emit MIR::StreamYield so the bc_emitter routes
    # to the rendezvous-channel STREAM_YIELD opcode. The Zig backend
    # never reaches this branch (it sets @current_stream_is_inf only for
    # the materializing path; @target check guards against confusion).
    if @target == :bc && @current_stream_is_inf
      return MIR::StreamYield.new(lowered)
    end
    # The yielded value is a hoisted, escape-placed binding (Hoist lifts
    # anonymous YIELD operands; escape analysis marks it heap because it
    # escapes the fiber). The stream owns it; the consumer frees it. No
    # dupe -- one allocation, placed by escape analysis.
    MIR::MethodCall.new(MIR::Ident.new(stream_local), "push", [lowered], true)
  end

  sig { params(node: AST::NextExpr, alloc_sym: Symbol).returns(T.untyped) }
  def lower_next_expr(node, alloc_sym = :frame)
    promise_type = Type.new(node.expr.full_type)

    if promise_type.promise_list?
      # NEXT on ~T[]@list: iterate the promise list, await each promise, collect results.
      # alloc_sym determines whether results are heap- or frame-allocated (caller passes
      # decl_alloc from the enclosing VarDecl so the allocator matches the cleanup plan).
      inner = lower(node.expr)

      # In BC the BG runtime spawns real fibers via BG_SPAWN and stashes
      # their futures in `futureTable`; the list elements are
      # Pair("__future__", id) markers, not yet-resolved values. Route
      # through MethodCall("next") so the bc_emitter emits AWAIT, which
      # the runner extends to walk Value.List (await each item, build
      # result list).
      return MIR::MethodCall.new(inner, "next", [], true) if @target == :bc

      inner_str = emit_expr(inner)
      elem_zig = promise_type.tense_type.element_type.zig_type
      @tmp_counter += 1
      blk_label = "__next_all_#{@tmp_counter}"
      results_var = "__next_results_#{@tmp_counter}"
      alloc_fn = alloc_sym == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
      code = "#{blk_label}: {\n" \
             "    var #{results_var} = std.ArrayListUnmanaged(#{elem_zig}).empty;\n" \
             "    for (#{inner_str}.items) |__p| {\n" \
             "        try #{results_var}.append(#{alloc_fn}, try __p.next());\n" \
             "    }\n" \
             "    break :#{blk_label} #{results_var};\n" \
             "}"
      iz = MIR::InlineZig.new(code, "next_promise_list")
      iz.stdlib_def = { allocates: true }
      iz.allocs = { results_var => alloc_sym }
      return iz
    end

    # Collection observable (`~T[]@set:observable`): NEXT yields an owned
    # ArrayListUnmanaged(T) via `materializeNext(alloc)` rather than a
    # snapshot handle, so user code (`final = NEXT running`) gets
    # something it can iterate without explicit `.release()`. The
    # materialized list is placed by the receiving binding's allocator
    # (alloc_sym) -- one allocator per binding, like every other value.
    if promise_type.observable? && promise_type.tense_type&.array?
      inner = lower(node.expr)
      # The materialized list inherits the receiving binding's placement
      # (@decl_alloc, set during lower_var_decl); alloc_sym is the
      # fallback when NEXT is lowered outside a binding.
      return MIR::MethodCall.new(inner, "materializeNext",
        [MIR::AllocatorRef.new(@decl_alloc || alloc_sym)], true)
    end

    if promise_type.observable?
      tt = promise_type.tense_type
      wt = tt&.optional? ? tt.wrapped_type : tt
      if wt&.string?
        inner = lower(node.expr)
        inner_str = emit_expr(inner)
        @tmp_counter += 1
        blk_label = "__obs_next_string_#{@tmp_counter}"
        return MIR::InlineZig.new("#{blk_label}: {\n    #{inner_str}.wait();\n    break :#{blk_label} try #{inner_str}.materialize(#{@rt_name}.heapAlloc());\n}", "obs_next_string")
      end
    end

    inner = lower(node.expr)
    MIR::MethodCall.new(inner, "next", [], true)
  end


end
