# typed: strict
# fsm_transform/emit.rb -- state-machine emitter.
#
# Given a segment graph + liveness output + lowering context, builds
# an MIR FSM wrapper body (FsmGenericBody) for FsmWrapperEmitter to
# render.
#
# The emit is mechanical given the segment graph. Each tail kind
# routes through a fixed pattern in `build_dispatch_tail` /
# `build_fsm_unified`; new SegmentTail kinds add a single arm there.
# Lock fan-out (multi-segment expansion of a LockSuspend) lives in
# `expand_lock_segment` -- the only suspend kind that needs more
# than one dispatch arm. Per CLAUDE.md Invariant 13, never a new
# top-level build_* function.

require "sorbet-runtime"

require "set"
require_relative "../mir"
require_relative "../fsm_wrapper_emitter"
require_relative "suspend_resolvers"

module FsmTransform
  module Emit
    extend T::Sig
    module_function

    FsmStructureSource = T.type_alias { T.any(MIR::Node, String) }
    FsmStructureSourceInput = T.type_alias { T.nilable(T.any(FsmStructureSource, T::Array[FsmStructureSource])) }
    SegmentSpec = T.type_alias { T::Hash[Symbol, Object] }
    FsmContext = T.type_alias { T::Hash[Symbol, Object] }
    PromotableFsmValue = T.type_alias { T.any(MIR::Node, Object) }
    FsmTail = T.type_alias do
      T.any(
        MIR::FsmTailDone,
        MIR::FsmTailJump,
        MIR::FsmTailYield,
        MIR::FsmTailRegisterYield,
        MIR::FsmTailCondJump,
        MIR::FsmTailLockTry,
        MIR::FsmTailWokenCheck,
        MIR::FsmTailRetryOrError,
      )
    end
    SegmentTail = T.type_alias do
      T.any(
        Segments::Done,
        Segments::Goto,
        Segments::LoopBack,
        Segments::CondBranch,
        Segments::IoSuspend,
        Segments::NextSuspend,
        Segments::LockSuspend,
        FsmTail,
      )
    end

    class DestroyLine < T::Struct
      extend T::Sig

      const :kind, Symbol
      const :name, T.nilable(String)
      const :zig, String
    end

    # ================================================================
    # Unified FSM emit (kind-agnostic, shape-agnostic)
    # ================================================================
    #
    # Single emitter that produces an FsmGenericBody from a segment
    # graph + per-suspend SuspendDescriptors. Replaces (incrementally)
    # the four legacy `emit_fsm_*_bg_code` snowflakes.
    #
    # Inputs (a "segment spec" per segment, prepared by the caller
    # with the right capture-map context already applied):
    #
    #   ctx               -- standard ctx (id, bg_rt, blk_label,
    #                         ctx_type, promise_zig, capture_fields,
    #                         alloc_var, promise_var, ctx_var,
    #                         pin_mode, rt_name, arena_init_flag,
    #                         capture_inits, promoted_decls,
    #                         is_void, captured, ...)
    #   segment_specs     -- array of hashes:
    #                          {
    #                            index:           Integer,
    #                            prologue_stmts:  [MIR::Stmt] | nil,
    #                            body_stmts:      [MIR::Stmt | String],
    #                            tail:            Segments::*,
    #                            descriptor:      MIR::SuspendDescriptor | nil,
    #                            fn_name:         String,    # "runStep0",
    #                                                          "runSeg0",
    #                                                          "runPre", ...
    #                            rt_suppress:     String | nil,
    #                            err_cleanups:    [MIR::Stmt] | nil,
    #                            pre_body_skip:   MIR::FsmTailCondSkip | nil,
    #                            pre_body_zig:    String | nil,
    #                          }
    #
    # `prologue_stmts` runs FIRST in the runStepK fn, BEFORE the
    # prior descriptor's bind_stmts. Used for entries like
    # arena_init (seg 0) and capture_frees_defer (the segment
    # whose runStep is the FSM's last entry) -- these must
    # register defers before any potentially-erroring bind block.
    #
    # `rt_suppress` is the `_ = &<bg_rt>;` line emitted at the
    # top of runStepK when the rendered body doesn't reference
    # bg_rt (avoiding the unused-binding diagnostic). The caller
    # computes this from the rendered body text -- the unified
    # emit can't reliably introspect MIR nodes for the check.
    #
    # `err_cleanups` are direct (non-defer) stmts injected into
    # the dispatch arm's catch handler before the standard
    # store-err / wg.done / destroy / Done sequence. Used by
    # B2-IO step-0 for capture frees on setup error.
    #   promoted_field_decls -- [String] from Liveness or legacy walk.
    #
    # Outputs: rendered Zig text (the FsmGenericBody emission).
    #
    # The caller is responsible for:
    #   - Lowering segment stmts to MIR (in capture-map context).
    #   - Resolving descriptors via SuspendResolvers (in same context).
    #   - Computing promoted_field_decls (via Liveness).
    #   - Threading arena_init / capture_frees prologue into the FIRST
    #     segment's body_stmts.
    #   - Threading post-result line / void_assign into the FINAL
    #     segment's body_stmts.
    #
    # The unified emit is responsible for:
    #   - Concatenating each descriptor's setup_stmts onto the END of
    #     its segment's runStep body.
    #   - Concatenating each descriptor's bind_stmts onto the START of
    #     the NEXT segment's runStep body.
    #   - Building FsmDispatch arms from segment tails + descriptors.
    #   - Building FsmGenericCtxStruct (extra fields = step + each
    #     descriptor's ctx_field_decls; member_fns = one per segment;
    #     resume_fn = the dispatch).
    #   - Wrapping in FsmGenericBody with shared spawn_setup.
    sig { params(ctx: T.untyped, segment_specs: T.untyped, promoted_field_decls: T.untyped, lowering: T.untyped).returns(T.nilable(MIR::FsmLoweringResult)) }
    def build_fsm_unified(ctx, segment_specs, promoted_field_decls, lowering)
      T.bind(self, T.untyped) rescue nil
      return nil if segment_specs.nil? || segment_specs.empty?

      id = ctx[:id]
      bg_rt = ctx[:bg_rt]

      # 1. Compose member fn body_stmts: segment body + setup at end
      #    + bind from the suspend whose next_index points HERE at
      #    start. Bind targeting via next_index (not array adjacency)
      #    matters once the recursive splitter produces non-linear
      #    segment graphs -- a suspend at position K can resume to
      #    any position M, and M's body must run K's bind.
      bind_for_index = {}
      segment_specs.each do |s|
        d = s[:descriptor]
        next unless d && d.bind_stmts && !d.bind_stmts.empty?
        target =
          if s[:tail].respond_to?(:next_index) && s[:tail].next_index
            s[:tail].next_index
          elsif s[:tail].respond_to?(:next_step) && s[:tail].next_step
            s[:tail].next_step
          else
            # Linear fallback: previous behavior was array-adjacent.
            (segment_specs.index(s) || 0) + 1
          end
        bind_for_index[target] = d.bind_stmts
      end

      member_fns = segment_specs.filter_map do |spec|
        body = []
        body.concat(spec[:prologue_stmts] || [])
        incoming_bind = bind_for_index[spec[:index]]
        if incoming_bind
          spec[:fn_name] ||= "runSeg#{spec[:index]}"
          body.concat(incoming_bind)
        end
        next nil if spec[:fn_name].nil?
        body.concat(spec[:body_stmts] || [])
        if (d = spec[:descriptor])
          body.concat(d.setup_stmts || [])
        end
        body.compact!
        body.reject! { |s| s.is_a?(String) && s.strip.empty? }

        rt_suppress = spec[:rt_suppress] || ""

        MIR::FsmMemberFn.new(
          spec[:fn_name], id, bg_rt, rt_suppress, body,
          spec[:extra_prologue_zig],
        )
      end

      # 2. Build dispatch from segment tails. All FSM shapes now
      #    construct a flat MIR::FsmDispatch via narrower tail
      #    variants (FsmTailLockTry / FsmTailWokenCheck /
      #    FsmTailRetryOrError for the LOCK fan-out, etc.) -- no
      #    more per-shape dispatch overrides.
      arms = segment_specs.map.with_index do |spec, k|
        tail = build_dispatch_tail(spec, k, segment_specs, id)
        MIR::FsmStateArm.new(
          spec[:index],
          spec[:pre_body_skip],
          spec[:pre_body_zig],
          spec[:fn_name],
          spec[:err_cleanups],
          tail,
        )
      end
      dispatch = MIR::FsmDispatch.new(id, arms, true)

      # 3. Extra ctx fields: step counter + each descriptor's
      #    suspend-protocol fields + caller-supplied extras (used by
      #    WITH for lock_waiter + retry_count, since those don't
      #    correspond to a generic suspend descriptor today).
      extra_field_decls = ["step: u8 = 0,"]
      segment_specs.each do |spec|
        d = spec[:descriptor]
        next unless d
        extra_field_decls.concat(d.ctx_field_decls || [])
      end
      extra_field_decls.concat(ctx[:extra_ctx_fields] || [])
      extra_field_decls.uniq!
      capture_field_names = ctx[:capture_fields].to_s.lines.each_with_object({}) do |decl, names|
        name = decl.to_s.split(":").first&.strip
        names[name] = true if name && !name.empty?
      end
      extra_field_decls = extra_field_decls.reject do |decl|
        name = decl.to_s.split(":").first&.strip
        name && capture_field_names[name]
      end
      extra_field_names = extra_field_decls.each_with_object(capture_field_names.dup) do |decl, names|
        name = decl.to_s.split(":").first&.strip
        names[name] = true if name && !name.empty?
      end
      promoted_field_decls = promoted_field_decls.reject do |decl|
        name = decl.to_s.split(":").first&.strip
        name && extra_field_names[name]
      end

      # 4. Wrap in FsmGenericCtxStruct + spawn_setup + FsmGenericBody.
      # Assemble destroy_extra_zig from the unified fsm_destroy_lines
      # pipeline. Locks first (so other tasks can acquire) in reverse
      # acquisition order, then captures, then any lifted body
      # cleanups.
      destroy_entries = T.cast(Array(ctx[:fsm_destroy_lines]).select { |entry|
        entry.is_a?(DestroyLine) && fsm_destroy_zig_present?(entry.zig)
      }, T::Array[DestroyLine])
      lock_zigs    = destroy_entries.select { |e| e.kind == :lock    }.map(&:zig)
      capture_zigs = destroy_entries.select { |e| e.kind == :capture }.map(&:zig)
      body_zigs    = destroy_entries.select { |e| e.kind == :body    }.map(&:zig)
      destroy_seq  = lock_zigs.reverse + capture_zigs + body_zigs
      destroy_extra = destroy_seq.empty? ? nil : destroy_seq.join("\n")
      ctx_struct = MIR::FsmGenericCtxStruct.new(
        ctx[:ctx_type], ctx[:promise_zig], ctx[:capture_fields],
        extra_field_decls, promoted_field_decls,
        member_fns, dispatch, destroy_extra,
      )
      spawn_setup = build_spawn_setup(ctx, lowering)
      fsm_body = MIR::FsmGenericBody.new(ctx[:blk_label], ctx_struct, spawn_setup)
      MIR::FsmLoweringResult.new(
        code: FsmWrapperEmitter.render(fsm_body),
        structure: build_fsm_structure(ctx, segment_specs, destroy_entries, id),
      )
    end

    sig { params(ctx: FsmContext, segment_specs: T::Array[SegmentSpec], destroy_entries: T::Array[DestroyLine], id: Integer).returns(MIR::FsmStructure) }
    def build_fsm_structure(ctx, segment_specs, destroy_entries, id)
      T.bind(self, T.untyped) rescue nil
      cleanup_names = destroy_entries.filter_map { |entry|
        next nil unless entry.kind == :capture || entry.kind == :body
        entry.name&.to_s
      }.uniq
      captured = T.cast(ctx[:captured] || {}, T::Hash[String, Object])
      capture_names = captured.keys.map(&:to_s)
      captures = capture_names.filter_map do |name|
        next nil unless cleanup_names.include?(name)
        { name: name, cleanup_at: :finalize }
      end
      structure_sources = fsm_structure_sources(segment_specs)
      steps = segment_specs.map do |spec|
        step_sources = fsm_structure_sources_for_spec(spec)
        {
          index: spec[:index],
          reads: collect_ctx_field_reads(step_sources, id),
          cleanups: [],
        }
      end
      structure = MIR::FsmStructure.new(captures, [], steps, cleanup_names, id, nil)
      structure.required_move_guards =
        collect_required_move_guards(structure_sources, id, cleanup_names)
      structure.move_guard_writes = collect_move_guard_writes(structure_sources, id)
      result_names = collect_result_names(structure_sources, id)
      result_facts = result_names.uniq.map do |name|
        MIR::FsmOwnershipFact.new(name: name, target: :result, target_alloc: :heap, move_guarded: true)
      end
      structured_facts = segment_specs.flat_map do |spec|
        facts = T.cast(spec[:fsm_result_transfer_facts] || [], T::Array[MIR::FsmResultTransferFact])
        facts.filter_map do |fact|
          guard_name = fsm_fact_guard_name(fact.name)
          next nil if guard_name.empty?

          MIR::FsmOwnershipFact.new(
            name: guard_name,
            target: :result,
            target_alloc: fact.target_alloc,
            move_guarded: fact.move_guarded,
          )
        end
      end
      structure.ownership_facts = (structured_facts + result_facts).uniq do |fact|
        [fact.name, fact.target, fact.target_alloc, fact.move_guarded]
      end
      structure
    end

    sig { params(zig: T.nilable(String)).returns(T::Boolean) }
    def fsm_destroy_zig_present?(zig)
      stripped = zig.to_s.strip
      !stripped.empty? && stripped != ";"
    end

    sig { params(sources: T::Array[FsmStructureSource], id: Integer, cleanup_names: T::Array[String]).returns(T::Array[String]) }
    def collect_required_move_guards(sources, id, cleanup_names)
      collect_fsm_nodes(sources).filter_map do |node|
        next nil unless node.is_a?(MIR::TransferMark)
        next nil unless node.target == :owned_sink || node.target == :return
        name = normalized_ctx_field_name(node.name.to_s, id)
        cleanup_names.include?(name) ? name : nil
      end.uniq
    end

    sig { params(segment_specs: T::Array[SegmentSpec]).returns(T::Array[FsmStructureSource]) }
    def fsm_structure_sources(segment_specs)
      segment_specs.flat_map { |spec| fsm_structure_sources_for_spec(spec) }
    end

    sig { params(spec: SegmentSpec).returns(T::Array[FsmStructureSource]) }
    def fsm_structure_sources_for_spec(spec)
      out = T.let([], T::Array[FsmStructureSource])
      out.concat(fsm_structure_source_array(T.cast(spec[:prologue_stmts], FsmStructureSourceInput)))
      structure_stmts = spec[:structure_stmts]
      out.concat(fsm_structure_source_array(T.cast(structure_stmts || spec[:body_stmts], FsmStructureSourceInput)))
      descriptor = T.cast(spec[:descriptor], T.nilable(MIR::SuspendDescriptor))
      if descriptor
        out.concat(fsm_structure_source_array(descriptor.setup_stmts))
        out.concat(fsm_structure_source_array(descriptor.bind_stmts))
      end
      out
    end

    sig { params(value: FsmStructureSourceInput).returns(T::Array[FsmStructureSource]) }
    def fsm_structure_source_array(value)
      Kernel.Array(value).filter_map do |item|
        next item if item.is_a?(String)
        next item if item.is_a?(MIR::Emittable)
        nil
      end
    end

    sig { params(sources: T::Array[FsmStructureSource], id: Integer).returns(T::Array[String]) }
    def collect_move_guard_writes(sources, id)
      collect_fsm_nodes(sources).filter_map do |node|
        if node.is_a?(MIR::MoveMark)
          name = node.name.to_s
          normalized = normalized_ctx_field_name(name, id)
          next [normalized, "__ctx_#{id}.#{normalized}"]
        end

        next nil unless node.is_a?(MIR::Set)
        next nil unless true_literal?(node.value)
        field = ctx_field_name(node.target, id)
        next nil unless field&.end_with?("_moved")
        field.delete_suffix("_moved")
      end.flatten.uniq
    end

    sig { params(name: String, id: Integer).returns(String) }
    def normalized_ctx_field_name(name, id)
      name.delete_prefix("__ctx_#{id}.")
    end

    sig { params(sources: T::Array[FsmStructureSource], id: Integer).returns(T::Array[String]) }
    def collect_result_names(sources, id)
      collect_fsm_nodes(sources).filter_map do |node|
        next nil unless node.is_a?(MIR::Set)
        next nil unless ctx_inner_result_target?(node.target, id)
        result_source_name(node.value, id)
      end.uniq
    end

    sig { params(name: String).returns(String) }
    def fsm_fact_guard_name(name)
      return "" if fsm_ctx_name?(name)
      fsm_ctx_field_prefix(name) || name
    end

    sig { params(name: String).returns(T::Boolean) }
    def fsm_ctx_name?(name)
      return false unless name.start_with?("__ctx_")
      suffix = name.delete_prefix("__ctx_")
      decimal_digits?(suffix)
    end

    sig { params(name: String).returns(T.nilable(String)) }
    def fsm_ctx_field_prefix(name)
      return nil unless name.start_with?("__ctx_")
      dot_index = name.index(".")
      return nil unless dot_index
      ctx_id = name["__ctx_".length...dot_index]
      return nil unless ctx_id
      return nil unless decimal_digits?(ctx_id)
      name[(dot_index + 1)..]
    end

    sig { params(value: String).returns(T::Boolean) }
    def decimal_digits?(value)
      return false if value.empty?
      value.each_char.all? { |char| char >= "0" && char <= "9" }
    end

    sig { params(sources: T::Array[FsmStructureSource], id: Integer).returns(T::Array[String]) }
    def collect_ctx_field_reads(sources, id)
      collect_fsm_nodes(sources).filter_map do |node|
        ctx_field_name(node, id)
      end.uniq
    end

    sig { params(sources: T::Array[FsmStructureSource]).returns(T::Array[MIR::Node]) }
    def collect_fsm_nodes(sources)
      roots = sources.reject { |source| source.is_a?(String) }
      out = T.let([], T::Array[MIR::Node])
      MIR.each_node(roots) { |node| out << node }
      out
    end

    sig { params(expr: MIR::Node, id: Integer).returns(T.nilable(String)) }
    def ctx_field_name(expr, id)
      return nil unless expr.is_a?(MIR::FieldGet)
      object = expr.object
      return nil unless object.is_a?(MIR::Ident)
      return nil unless object.name.to_s == "__ctx_#{id}"
      expr.field.to_s
    end

    sig { params(expr: MIR::Node, id: Integer).returns(T::Boolean) }
    def ctx_inner_result_target?(expr, id)
      return false unless expr.is_a?(MIR::FieldGet)
      return false unless expr.field.to_s == "result"
      inner = expr.object
      return false unless inner.is_a?(MIR::FieldGet)
      return false unless inner.field.to_s == "inner"
      object = inner.object
      object.is_a?(MIR::Ident) && object.name.to_s == "__ctx_#{id}"
    end

    sig { params(expr: MIR::Node, id: Integer).returns(T.nilable(String)) }
    def result_source_name(expr, id)
      if expr.is_a?(MIR::Ident)
        expr.name.to_s
      else
        ctx_field_name(expr, id)
      end
    end

    sig { params(expr: MIR::Node).returns(T::Boolean) }
    def true_literal?(expr)
      expr.is_a?(MIR::Lit) && expr.value.to_s == "true"
    end

    # Translate a segment's tail into the dispatch arm's tail. Suspend
    # tails consult the descriptor for the kind-specific tail variant
    # (Yield / RegisterYield); non-suspend tails (Goto / LoopBack /
    # CondBranch / Done) map to the structural tail variants directly.
    sig { params(spec: SegmentSpec, k: Integer, all_specs: T::Array[SegmentSpec], id: Integer).returns(FsmTail) }
    def build_dispatch_tail(spec, k, all_specs, id)
      T.bind(self, T.untyped) rescue nil
      tail = T.cast(spec[:tail], SegmentTail)
      desc = T.cast(spec[:descriptor], T.nilable(MIR::SuspendDescriptor))
      index = T.cast(spec[:index], Integer)
      next_step = index + 1
      # Passthrough for tails the caller has already built as MIR
      # nodes (FsmTailLockTry / FsmTailWokenCheck / FsmTailRetryOrError
      # used by B2-WITH's fan-out, etc.).
      case tail
      when MIR::FsmTailLockTry, MIR::FsmTailWokenCheck, MIR::FsmTailRetryOrError,
           MIR::FsmTailJump, MIR::FsmTailDone
        return tail
      end
      case tail
      when Segments::Done
        MIR::FsmTailDone.new(nil)
      when Segments::Goto, Segments::LoopBack
        MIR::FsmTailJump.new(tail.target_index)
      when Segments::CondBranch
        # cond_ast may be a raw AST node (caller resolves to Zig
        # string at lower-time) or a pre-rendered string. We accept
        # either via duck-typing: prefer .cond_zig, else .zig_text,
        # else assume already a String.
        cond_zig =
          if tail.cond_ast.respond_to?(:cond_zig) && tail.cond_ast.cond_zig
            tail.cond_ast.cond_zig
          elsif tail.cond_ast.respond_to?(:zig_text)
            tail.cond_ast.zig_text
          elsif tail.cond_ast.respond_to?(:render)
            tail.cond_ast.render("__ctx_#{id}")
          elsif tail.cond_ast.is_a?(String)
            tail.cond_ast
          else
            raise ArgumentError,
              "CondBranch tail's cond_ast (#{tail.cond_ast.class}) " \
              "needs a #cond_zig accessor, #zig_text accessor, or " \
              "must be a String. Caller-side lower-then-pass-zig-text."
          end
        MIR::FsmTailCondJump.new(cond_zig, tail.then_index, tail.else_index)
      when Segments::IoSuspend, Segments::NextSuspend
        # Descriptor produced an FsmTailYield(nil, ...) or
        # FsmTailRegisterYield(nil, ..., ...) -- fill in the next
        # step index. Honor explicit next_index on the suspend tail
        # (the recursive splitter sets it to target arbitrary
        # segments, e.g. for loop-back semantics); otherwise fall
        # back to the linear seg.index + 1 default.
        raise ArgumentError,
          "Suspend tail in segment #{index} has no descriptor" if desc.nil?
        desc = T.must(desc)
        explicit_next = tail.respond_to?(:next_index) ? tail.next_index : nil
        target_step = explicit_next || next_step
        desc_tail = desc.tail
        case desc_tail
        when MIR::FsmTailYield
          MIR::FsmTailYield.new(target_step, desc_tail.yield_reason)
        when MIR::FsmTailRegisterYield
          MIR::FsmTailRegisterYield.new(
            target_step, desc_tail.register_zig, desc_tail.yield_reason,
          )
        else
          raise ArgumentError,
            "Unsupported descriptor tail #{desc_tail.class} in segment #{index}"
        end
      else
        raise ArgumentError,
          "Unsupported segment tail #{tail.class} in segment #{index}"
      end
    end

    # ================================================================
    # Production entry for the recursive splitter
    # ================================================================
    #
    # Consumes a flat segment graph from RecursiveSplitter.split and
    # produces a rendered FSM body via build_fsm_unified. This is the
    # path that eventually subsumes per-shape emitters (LOOP / IF /
    # ForRange / nested combinations all flow through here).
    #
    # `ctx` carries the standard BG lowering context (id, bg_rt,
    # blk_label, ctx_type, promise_zig, capture_fields, alloc_var,
    # promise_var, ctx_var, rt_name, pin_mode, promoted_decls,
    # capture_inits, captured, capture_close_zig, pointer_captures,
    # arena_init_flag, is_void).
    #
    # `lowering` is the MIRLowering instance; we use it for
    # capture-map context (with_fiber_capture_map), AST -> MIR
    # lowering (lower / emit_step_stmts), and capture-frees rendering.
    #
    # `liveness` is the Liveness analysis result; promoted_field_decls
    # are derived from cross_segment_vars.
    sig { params(ctx: FsmContext, segments: RecursiveSplitter::SegmentList, liveness: Liveness::Result, lowering: Object).returns(T.nilable(MIR::FsmLoweringResult)) }
    def build_recursive(ctx, segments, liveness, lowering)
      T.bind(self, T.untyped) rescue nil
      return nil if segments.segments.empty?

      id = T.cast(ctx[:id], Integer)
      bg_rt = T.cast(ctx[:bg_rt], String)
      captured = T.cast(ctx[:captured] || {}, T::Hash[String, Object])
      capture_close_zig = T.cast(ctx[:capture_close_zig] || {}, T::Hash[String, String])
      pointer_captures = T.cast(ctx[:pointer_captures], T.nilable(T::Set[String]))
      arena_init_flag = T.cast(ctx[:arena_init_flag], T.nilable(T::Boolean))
      recursive_promoted_names = T.cast(ctx[:recursive_promoted_names] || [], T::Array[String])
      extra_ctx_fields = T.cast(ctx[:extra_ctx_fields] || [], T::Array[String])
      fresh_heap_cleanup_names = T.cast(ctx[:fresh_heap_cleanup_names] || [], T::Array[String])
      fresh_heap_cleanups = T.cast(ctx[:fresh_heap_cleanups] || "", String)
      is_void = T.cast(ctx[:is_void], T::Boolean)
      lowering_api = T.unsafe(lowering)

      ctx_token = "__ctx_#{id}"
      segment_list = segments
      segments = segment_list.segments.map do |seg|
        new_stmts = seg.stmts.map do |s|
          render_segment_stmt(s, ctx_token)
        end
        new_tail = seg.tail
        if new_tail.is_a?(Segments::CondBranch) &&
            (new_tail.cond_ast.is_a?(String) || new_tail.cond_ast.is_a?(Segments::SyntheticZig))
          new_tail = Segments::CondBranch.new(
            render_segment_stmt(new_tail.cond_ast, ctx_token),
            new_tail.then_index, new_tail.else_index,
          )
        end
        Segments::Segment.new(seg.index, new_stmts, new_tail)
      end

      # Promoted field decls from Liveness. Cross-segment vars become
      # ctx fields. NEXT/IO result vars are added separately by their
      # descriptors, so exclude them here.
      suspend_result_vars =
        segments.flat_map { |seg|
          [Segments.suspend_tail?(seg.tail) ? seg.tail.result_var : nil]
        }.compact
      # Conservative-promoted names are already represented in
      # ctx[:extra_ctx_fields] by FsmTransform.transform; exclude
      # them here to avoid duplicate struct members.
      conservative_names = recursive_promoted_names.each_with_object({}) { |n, h| h[n] = true }
      fsm_promoted_names = ((liveness && liveness.cross_segment_vars || {}).keys +
                            recursive_promoted_names).compact.uniq
      promoted_value_decls =
        (liveness && liveness.cross_segment_vars || {})
          .reject { |name, _|
            suspend_result_vars.include?(name) ||
              conservative_names.include?(name)
          }
          .map do |name, info|
            t = info[:type] ? Type.new(info[:type]) : nil
            "#{name}: #{t ? t.zig_type : 'anyopaque'} = undefined,"
          end
      promoted_guard_decls = fsm_promoted_names.map { |name| "#{name}_moved: bool = false," }
      promoted_field_decls = promoted_value_decls + promoted_guard_decls

      # capture_map: outer captures + promoted locals (liveness +
      # conservative) + suspend result vars. All names that resolve
      # to ctx fields must be in the map so AST-level references
      # lower to `__ctx.NAME`. Conservative-promoted names are
      # required for vars hidden behind a LockSuspend tail (CS body
      # isn't analyzed by liveness). Suspend result vars come from
      # the suspend descriptor's ctx_field_decls -- the body
      # reads them after the bind populates ctx.NAME.
      capture_map = captured.map { |name, _| [name, "__ctx_#{id}.#{name}"] }.to_h
      (liveness && liveness.cross_segment_vars || {}).each_key do |name|
        capture_map[name] ||= "__ctx_#{id}.#{name}"
      end
      recursive_promoted_names.each do |name|
        capture_map[name] ||= "__ctx_#{id}.#{name}"
      end
      segments.each do |seg|
        next unless Segments.suspend_tail?(seg.tail)
        rv = seg.tail.result_var
        capture_map[rv] ||= "__ctx_#{id}.#{rv}" if rv && rv != "_"
      end

      arena_init_zig = arena_init_flag ? "#{bg_rt}.arena_mode = true;" : ""
      # FSM destroy pipeline: ONE source of truth for cleanups that
      # must fire when the FSM task ends, regardless of whether the
      # body completes successfully or errors out. Zig `defer` is
      # not safe for these: each runSegN fn is its own stack frame,
      # so a defer placed in any one runFn fires when THAT fn
      # returns -- before the BG body as a whole has finished.
      #
      # Three categories converge here:
      #   :lock     -- per-cap unlock (push at expand_lock_segment
      #                time). Ordered LIFO of acquisition.
      #   :capture  -- resource close_zig captures.
      #   :body     -- (reserved) MIR::Cleanup nodes for body-local
      #                vars promoted to ctx (cross-segment). Lifted
      #                from segment Zig if the invariant scan finds
      #                them; today there are none in the corpus.
      #
      # FsmGenericCtxStruct.destroy_extra_zig assembles them in
      # order: locks (reverse-acquisition) -> captures -> body.
      ctx[:fsm_destroy_lines] = T.let([], T::Array[DestroyLine])
      captured.each do |name, _|
        zig =
          if capture_close_zig[name]
            tpl = T.must(capture_close_zig[name])
            close_target = "__ctx_#{id}.#{name}"
            tpl = tpl.split("{0}").join(close_target)
            tpl = tpl.split("rt.").join("__ctx_#{id}.rt.")
            "#{tpl};"
          end
        T.cast(ctx[:fsm_destroy_lines], T::Array[DestroyLine]) << DestroyLine.new(
          kind: :capture,
          name: name.to_s,
          zig: zig,
        ) if zig
      end
      # FreshHeapCopy cleanups (master's `defer CheatLib.cleanup(...)`
      # forms inside the run fn) lift to destroyTask. The body_cleanup_zig
      # produced by FiberCtxBuilder is `defer CheatLib.cleanup(@TypeOf
      # (__ctx_<id>.<name>), __ctx_<id>.alloc, &__ctx_<id>.<name>);` —
      # we strip the leading `defer ` and trailing `;` and re-emit as a
      # destroyTask line so it fires once when the FSM ctx tears down,
      # not on each segment return.
      fresh_heap_names = fresh_heap_cleanup_names
      fresh_heap_cleanups.each_line.with_index do |line, cleanup_index|
        line = line.strip
        next if line.empty?
        # Drop the `defer ` prefix; destroy_extra_zig wraps the line at
        # the destroyTask exit anyway, so the unconditional cleanup fires
        # exactly once.
        zig = line.delete_prefix("defer ")
        zig = zig.split("rt.").join("__ctx_#{id}.rt.")
        T.cast(ctx[:fsm_destroy_lines], T::Array[DestroyLine]) << DestroyLine.new(
          kind: :capture,
          name: fresh_heap_names[cleanup_index]&.to_s,
          zig: zig,
        )
      end

      # Per-segment lowering. Stmts may be a mix of AST nodes (user
      # code) and Strings (synthesized init/cond/incr from the
      # splitter). AST nodes go through lower_step_stmts; Strings
      # pass through.
      #
      # The Done-tailed segment's stmts are lowered with
      # no_result: false so its trailing expression becomes the BG's
      # return value (`__ctx.inner.result = <expr>;`). For void
      # BGs the result is `{}` instead, appended later when the
      # spec is built.
      conservative_promoted = recursive_promoted_names
      done_idx = segments.find_index { |s| s.tail.is_a?(Segments::Done) }
      result_seg_indices = segments.each_with_index.with_object(Set.new) do |(seg, _i), acc|
        next if seg.stmts.empty?
        if seg.tail.is_a?(Segments::Done)
          acc << seg.index
        elsif seg.tail.is_a?(Segments::Goto) && seg.tail.target_index == done_idx
          acc << seg.index
        end
      end
      owned_result_guards = fsm_owned_result_guards(segments, lowering)
      seg_result_facts = T.let({}, T::Hash[Integer, T::Array[Object]])
      seg_mir_codes = T.let([], T::Array[T::Array[MIR::Node]])
      seg_codes = segments.each_with_index.map do |seg, i|
        ast_stmts, raw_stmts = seg.stmts.partition { |s| !s.is_a?(String) }
        if ast_stmts.empty?
          seg_mir_codes[i] = []
          raw_stmts
        else
          want_result = !is_void && result_seg_indices.include?(seg.index)
          inherited_capture_names = T.let(Array(ctx[:fsm_destroy_lines]).filter_map do |entry|
            next nil unless entry.is_a?(DestroyLine) && (entry.kind == :capture || entry.kind == :body)
            name = entry.name
            name ? "__ctx_#{id}.#{name}" : nil
          end.to_set, T::Set[String])
          captured.keys.each { |name| inherited_capture_names << "__ctx_#{id}.#{name}" }
          # Per-segment alias overrides (e.g. WITH's `inner` ->
          # __ctx_<id>.c.ctrl.data.*.data) merged into the rendering
          # capture_map so identifier resolution sees the alias.
          seg_overrides = segment_list.alias_overrides_for(seg.index)
          eff_capture_map = seg_overrides ?
                              capture_map.merge(seg_overrides) : capture_map
          lowered_mir = lowering_api.with_fsm_segment_lowering_context(
            pointer_captures: pointer_captures || Set.new,
            inherited_alloc_names: inherited_capture_names,
            inherited_guard_names: inherited_capture_names,
            owned_result_guards: owned_result_guards,
          ) do
            lowering_api.with_fiber_capture_map(eff_capture_map, rt_override: bg_rt) do
              if want_result
                lowering_api.lower_finalized_fsm_step_mir(
                  ast_stmts, no_result: false, ctx_id: id,
                )
              else
                lowering_api.lower_finalized_fsm_step_mir(ast_stmts, no_result: true)
              end
            end
          end
          facts = lowering_api.last_fsm_result_transfer_facts
          seg_result_facts[seg.index] = facts
          return nil if lowered_mir.nil?
          all_promoted = fsm_promoted_names + captured.keys.map(&:to_s)
          if all_promoted.any?
            promoted_names = all_promoted.uniq
            lowered_mir = promote_fsm_mir_to_ctx_fields(lowered_mir, promoted_names, id)
            lowered_mir = lift_ctx_cleanups_to_destroy!(lowered_mir, promoted_names, "__ctx_#{id}", ctx, lowering)
          end
          seg_mir_codes[i] = lowered_mir
          lowered = lowering_api.with_fiber_capture_map({}, rt_override: bg_rt) do
            lowering_api.render_mir_list(lowered_mir)
          end
          [lowered, *raw_stmts].reject { |s| s.is_a?(String) && s.strip.empty? }
        end
      end

      # FSM cleanup invariant: no `defer NAME.<method>(...)` may
      # appear in any segment fn where NAME is a cross-segment ctx
      # field (captured value, recursively-promoted local, or
      # liveness cross-segment var). Such a defer would fire when
      # that segment's runFn returns -- before the BG body as a
      # whole has finished -- causing a use-after-free on the
      # remaining segments. The cleanup must be lifted to
      # destroyTask via ctx[:fsm_destroy_lines]. This sweep is the
      # checker that closes the historical hole where Pass 3 (which
      # validates cleanups assuming a single-fn body) couldn't see
      # Pass 4's segment splitting.
      check_fsm_cleanup_invariant!(seg_mir_codes, segments,
                                   liveness, captured,
                                   conservative_promoted)

      # Build segment_specs. seg 0 gets the prologue (arena_init).
      # Suspends get descriptors. Void BG bodies
      # get an explicit `__ctx.inner.result = {};` on their success
      # Done segment so the promise resolves to a void value (the
      # legacy emitters do this via explicit_void_assign on the
      # final runPostStmts).
      void_assign_zig = is_void ? "__ctx_#{id}.inner.result = {};" : nil
      # Stable sp_<N> index allocation: walk segments in dispatch
      # order (0 → tail.next_index → ...) and assign sp_1, sp_2, ...
      # to each NEXT/IO suspend. Decouples sp_N labels from arbitrary
      # segment-graph indices so a single-NEXT body always emits
      # sp_1 (matching the legacy NEXT-CHAIN naming).
      sp_indices = compute_sp_indices(segments)
      segment_specs = segments.each_with_index.map do |seg, i|
        descriptor = build_segment_descriptor(seg, ctx, lowering, capture_map,
                                              sp_idx: sp_indices[seg.index])
        return nil if Segments.suspend_tail?(seg.tail) && descriptor.nil?

        prologue =
          if i == 0
            parts = []
            parts << arena_init_zig unless arena_init_zig.empty?
            # Capture cleanups deliberately do NOT live in the
            # prologue: a Zig defer here fires when seg 0's runFn
            # returns -- before the BG body has finished running.
            # See ctx[:fsm_destroy_lines] / destroyTask above.
            parts.empty? ? nil : parts
          end

        body_stmts = Array(seg_codes[i])
        if void_assign_zig && seg.tail.is_a?(Segments::Done)
          body_stmts = body_stmts + [void_assign_zig]
        end

        rt_used = (body_stmts.join("\n") +
                   (prologue || []).join("\n") +
                   (descriptor && descriptor.setup_stmts || []).join("\n")).include?(bg_rt)
        rt_suppress = rt_used ? "" : "_ = &#{bg_rt};"

        {
          index:           seg.index,
          prologue_stmts:  prologue,
          body_stmts:      body_stmts,
          structure_stmts: seg_mir_codes[i] || [],
          tail:            seg.tail,
          descriptor:      descriptor,
          fsm_result_transfer_facts: seg_result_facts[seg.index] || [],
          fn_name:         "runSeg#{seg.index}",
          rt_suppress:     rt_suppress,
        }
      end

      register_owned_suspend_result_cleanups!(segment_specs, ctx, id)

      # Expand any Segments::LockSuspend specs into the 5-segment
      # lock fan-out (FsmTailLockTry / FsmTailWokenCheck /
      # FsmTailRetryOrError + error arm + CS body). Lock-acquire is
      # the only suspend kind that needs multiple dispatch arms; the
      # expansion concentrates that complexity here so the splitter
      # stays purely structural.
      lock_extra_fields = []
      next_extra_idx = segment_specs.length
      expanded_specs = []
      segment_specs.each do |spec|
        if spec[:tail].is_a?(Segments::LockSuspend)
          out = expand_lock_segment(spec, ctx, capture_map,
                                    lowering, next_extra_idx)
          return nil if out.nil?
          expanded_specs << out[:lock_try_spec]
          expanded_specs.concat(out[:appended_specs])
          lock_extra_fields.concat(out[:extra_fields])
          next_extra_idx += out[:appended_specs].length
        else
          expanded_specs << spec
        end
      end
      segment_specs = expanded_specs

      synthetic = segment_list.synthetic_fields
      all_fields = extra_ctx_fields + synthetic + lock_extra_fields
      # Dedupe by field name (before the colon). Conservative
      # promotion (collect_body_locals) and splitter-synthesized
      # iteration vars can both name the same field; first wins.
      seen_names = {}
      deduped = all_fields.reject do |decl|
        name = decl.to_s.split(":").first&.strip
        next false if name.nil? || name.empty?
        if seen_names[name]
          true
        else
          seen_names[name] = true
          false
        end
      end
      ctx_with_extras =
        if deduped != extra_ctx_fields
          ctx.merge(extra_ctx_fields: deduped)
        else
          ctx
        end
      build_fsm_unified(ctx_with_extras, segment_specs, promoted_field_decls, lowering)
    end

    sig { params(stmt: T.any(String, Segments::SyntheticZig), ctx_token: String).returns(String) }
    def render_segment_stmt(stmt, ctx_token)
      case stmt
      when Segments::SyntheticZig
        stmt.render(ctx_token)
      else
        stmt
      end
    end

    sig { params(body: T::Array[MIR::Node], promoted_names: T::Array[String], id: Integer).returns(T::Array[MIR::Node]) }
    def promote_fsm_mir_to_ctx_fields(body, promoted_names, id)
      body.map do |node|
        T.cast(rewrite_promoted_fsm_node(node, promoted_names, id), MIR::Node)
      end
    end

    sig { params(node: PromotableFsmValue, promoted_names: T::Array[String], id: Integer).returns(PromotableFsmValue) }
    def rewrite_promoted_fsm_node(node, promoted_names, id)
      case node
      when Array
        return node.map { |child| rewrite_promoted_fsm_node(child, promoted_names, id) }
      when MIR::Let
        promoted_name = promoted_fsm_field_name(node.name.to_s, promoted_names)
        rewritten_init = T.cast(rewrite_promoted_fsm_node(T.cast(node.init, MIR::Node), promoted_names, id), MIR::Node)
        if promoted_name
          return MIR::Set.new(fsm_ctx_field(id, promoted_name), rewritten_init, false)
        end
        node.init = rewritten_init
        return node
      when MIR::Ident
        promoted_name = promoted_fsm_field_name(node.name.to_s, promoted_names)
        return fsm_ctx_field(id, promoted_name) if promoted_name
        return node
      end

      if node.is_a?(MIR::Emittable)
        rewrite_promoted_fsm_struct_fields!(node, promoted_names, id)
      end
      node
    end

    sig { params(node: MIR::Emittable, promoted_names: T::Array[String], id: Integer).void }
    def rewrite_promoted_fsm_struct_fields!(node, promoted_names, id)
      return unless node.is_a?(Struct)
      node.members.each do |field|
        value = node[field]
        next unless value.is_a?(MIR::Emittable) || value.is_a?(Array)
        node[field] = rewrite_promoted_fsm_node(value, promoted_names, id)
      end
      nil
    end

    sig { params(id: Integer, name: String).returns(MIR::FieldGet) }
    def fsm_ctx_field(id, name)
      MIR::FieldGet.new(MIR::Ident.new("__ctx_#{id}"), name)
    end

    sig { params(name: String, promoted_names: T::Array[String]).returns(T.nilable(String)) }
    def promoted_fsm_field_name(name, promoted_names)
      return name if promoted_names.include?(name)
      promoted_names.each do |candidate|
        local_prefix = "#{candidate}_L"
        if name.start_with?(local_prefix)
          suffix = name.delete_prefix(local_prefix)
          return candidate if decimal_digits?(suffix)
        end
        moved = "#{candidate}_moved"
        return moved if name == moved
        moved_local_prefix = "#{candidate}_L"
        if name.start_with?(moved_local_prefix) && name.end_with?("_moved")
          middle = name.delete_prefix(moved_local_prefix).delete_suffix("_moved")
          return moved if decimal_digits?(middle)
        end
      end
      nil
    end

    sig { params(body: T::Array[MIR::Node], promoted_names: T::Array[String], ctx_ref: String, ctx: FsmContext, lowering: Object).returns(T::Array[MIR::Node]) }
    def lift_ctx_cleanups_to_destroy!(body, promoted_names, ctx_ref, ctx, lowering)
      lowering_api = T.unsafe(lowering)
      body.filter_map do |node|
        if node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
          promoted_name = promoted_fsm_field_name(node.name.to_s, promoted_names)
          if promoted_name
            zig = lowering_api.with_fiber_capture_map({}, rt_override: "#{ctx_ref}.rt") do
              lowering_api.render_fsm_destroy_cleanup("#{ctx_ref}.#{promoted_name}", node.cleanup_entry)
            end
            T.cast(ctx[:fsm_destroy_lines], T::Array[DestroyLine]) << DestroyLine.new(
              kind: :body,
              name: promoted_name,
              zig: zig,
            )
            next nil
          end
        end
        node
      end
    end

    sig { params(segments: T::Enumerable[Segments::Segment], lowering: Object).returns(T::Hash[String, String]) }
    def fsm_owned_result_guards(segments, lowering)
      T.bind(self, T.untyped) rescue nil
      guards = {}
      segments.each do |seg|
        tail = seg.tail
        next unless Segments.suspend_tail?(tail)
        result_var = tail.result_var
        next unless result_var && result_var != "_"
        result_type = tail.result_type
        next unless SuspendResolvers.ownership_bearing_result_type?(result_type, lowering)
        guards[result_var.to_s] = SuspendResolvers.fsm_owned_guard_name(result_var.to_s)
      end
      guards
    end

    sig { params(segment_specs: T.untyped, ctx: T.untyped, id: Integer).void }
    def register_owned_suspend_result_cleanups!(segment_specs, ctx, id)
      T.bind(self, T.untyped) rescue nil
      seen = Set.new
      segment_specs.each do |spec|
        desc = spec[:descriptor]
        next unless desc && desc.result_needs_cleanup && desc.result_var
        name = desc.result_var.to_s
        next unless seen.add?(name)
        guard = SuspendResolvers.fsm_owned_guard_name(name)
        ctx[:fsm_destroy_lines] ||= T.let([], T::Array[DestroyLine])
        T.cast(ctx[:fsm_destroy_lines], T::Array[DestroyLine]) << DestroyLine.new(
          kind: :body,
          name: name,
          zig: "if (__ctx_#{id}.#{guard}) CheatLib.cleanup(@TypeOf(__ctx_#{id}.#{name}), __ctx_#{id}.rt.heapAlloc(), &__ctx_#{id}.#{name});",
        )
      end
    end

    # FSM cleanup invariant checker. Walks each segment's lowered
    # Zig and asserts that no `defer NAME.<method>(...)` line
    # references a cross-segment ctx field. Such a defer would fire
    # when its runSegN returns -- before the BG body completes --
    # so it must be lifted to destroyTask via fsm_destroy_lines.
    #
    # Whitelist: defers whose receiver is itself qualified with the
    # ctx (`__ctx_<id>.X`) are user-written destroy-side stmts,
    # not Pass-4 emit defers; we don't see those in segment Zig
    # today, but the regex below requires the receiver to be a
    # bare identifier so it's robust against that case.
    sig { params(seg_codes: T::Array[T::Array[MIR::Node]], segments: T::Array[Segments::Segment], liveness: Liveness::Result, captured: T::Hash[String, Object], conservative_promoted: T::Array[String]).void }
    def check_fsm_cleanup_invariant!(seg_codes, segments, liveness,
                                     captured, conservative_promoted)
      T.bind(self, T.untyped) rescue nil
      forbidden = liveness.cross_segment_vars.keys.dup
      forbidden.concat((captured || {}).keys)
      forbidden.concat(conservative_promoted || [])
      forbidden_set = forbidden.compact.uniq.to_set
      return if forbidden_set.empty?

      seg_codes.each_with_index do |code, i|
        MIR.each_node(code) do |node|
          next unless node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
          name = node.name.to_s
          next unless forbidden_set.include?(name)
          segment = T.must(segments[i])
          seg_idx = segment.respond_to?(:index) ? segment.index : i
          raise "FSM cleanup invariant violated: seg #{seg_idx} emits " \
                "cleanup for '#{name}', a cross-segment ctx " \
                "field. The defer would fire when this runSegN returns, " \
                "before the BG body completes. Lift the cleanup to " \
                "destroyTask via ctx[:fsm_destroy_lines]."
        end
      end
    end

    # Expand ONE LockSuspend spec into the per-cap fan-out.
    #
    # Per cap: 5 segments -- LockTry / WokenCheck / RetryOrError /
    # fail / held_set. The held_set stub flips this cap's
    # __lock_held_<i> flag to true and Gotos to post_acquire_idx
    # (the next cap or the recursively-split CS body the splitter
    # produced). Both LockTry's .Acquired branch and WokenCheck's
    # .None (woke without error) branch route through held_set.
    #
    # The fail body releases any prior caps already held earlier in
    # this WITH chain (stored on the tail as prior_caps) before
    # running the user's lock_error_clause -- locks held in earlier
    # runFn frames cannot be released by Zig defer because each
    # runFn is its own stack frame.
    #
    # The CS body itself is now produced entirely by the splitter
    # (recursively split, may contain suspends). Lock release at
    # end of CS is also splitter-emitted (an explicit-unlock
    # release segment); destroyTask reads __lock_held_<i> flags to
    # release any locks still held on err paths.
    #
    # Returns nil on metadata / error-arm failure (caller falls
    # back to stackful).
    sig { params(spec: T.untyped, ctx: T.untyped, capture_map: T.untyped, lowering: T.untyped, base_idx: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def expand_lock_segment(spec, ctx, capture_map, lowering, base_idx)
      T.bind(self, T.untyped) rescue nil
      tail      = spec[:tail]
      with_node = tail.with_node
      cap       = tail.cap
      prior     = tail.prior_caps || []
      after_idx = tail.next_index
      bg_rt = ctx[:bg_rt]
      id    = ctx[:id]
      captured = ctx[:captured] || {}

      meta = lowering.fsm_cap_metadata(cap, with_node, id, captured)
      return nil if meta.nil?

      cap_idx = prior.length

      woken_idx    = base_idx
      retry_idx    = base_idx + 1
      fail_idx     = base_idx + 2
      held_set_idx = base_idx + 3

      # LockTry / WokenCheck both route through the held_set stub
      # before reaching post_acquire_idx so destroyTask can know
      # which locks are still held.
      try_success_idx = held_set_idx

      prior_meta = prior.map { |c|
        m = lowering.fsm_cap_metadata(c, with_node, id, captured)
        return nil if m.nil?
        m
      }

      pointer_captures = ctx[:pointer_captures]
      err =
        if with_node.lock_error_clause
          lowering.emit_fsm_lock_error_arm_split(
            clause:           with_node.lock_error_clause,
            ctx_id:           id,
            with_node:        with_node,
            capture_map:      capture_map,
            pointer_captures: pointer_captures,
            bg_rt:            bg_rt,
            rt_name:          ctx[:rt_name],
          )
        else
          lowering.default_fsm_lock_error_arm_split(id)
        end
      return nil if err.nil?

      # Fail body: clear + unlock any prior caps in reverse, then
      # user clause. The held flag for THIS cap stays false (we
      # never set it because acquire failed).
      prior_release_lines = prior_meta.each_with_index.map { |m, i|
        ["__ctx_#{id}.__lock_held_#{i} = false;",
         "#{m[:lock_field_ref]}.#{m[:unlock_method]}();"]
      }.reverse.flatten
      fail_body_pieces = []
      fail_body_pieces.concat(prior_release_lines)
      fail_body_pieces << err.body_zig unless err.body_zig.strip.empty?
      fail_pre_body = fail_body_pieces.empty? ? nil : fail_body_pieces.join("\n")

      fail_tail = err.exit_kind == :done ?
                    Segments::Done.new(nil) :
                    Segments::Goto.new(after_idx)

      has_step_work = !(spec[:prologue_stmts].nil? || spec[:prologue_stmts].empty?) ||
                      !(spec[:body_stmts].nil? || spec[:body_stmts].empty?)
      lock_try_spec = {
        index:          spec[:index],
        prologue_stmts: spec[:prologue_stmts],
        body_stmts:     spec[:body_stmts] || [],
        tail:           MIR::FsmTailLockTry.new(
                           meta[:try_method], meta[:lock_field_ref],
                           try_success_idx, woken_idx, retry_idx,
                         ),
        descriptor:     nil,
        fn_name:        has_step_work ? spec[:fn_name] : nil,
        rt_suppress:    spec[:rt_suppress],
      }
      woken_spec = {
        index:        woken_idx, body_stmts: [],
        tail:         MIR::FsmTailWokenCheck.new(try_success_idx, retry_idx),
        descriptor:   nil, fn_name: nil,
        rt_suppress:  "_ = &#{bg_rt};",
      }
      retry_spec = {
        index:        retry_idx, body_stmts: [],
        tail:         MIR::FsmTailRetryOrError.new(meta[:retries], spec[:index], fail_idx),
        descriptor:   nil, fn_name: nil,
        rt_suppress:  "_ = &#{bg_rt};",
      }
      fail_spec = {
        index:        fail_idx,
        body_stmts:   [],
        pre_body_zig: fail_pre_body,
        tail:         fail_tail,
        descriptor:   nil, fn_name: nil,
        rt_suppress:  "_ = &#{bg_rt};",
      }
      held_set_spec = {
        index:        held_set_idx,
        body_stmts:   [],
        pre_body_zig: "__ctx_#{id}.__lock_held_#{cap_idx} = true;",
        tail:         Segments::Goto.new(tail.post_acquire_idx),
        descriptor:   nil, fn_name: nil,
        rt_suppress:  "_ = &#{bg_rt};",
      }

      extra_fields = [
        "lock_waiter: CheatHeader.WaiterNode = undefined,",
        "__lock_held_#{cap_idx}: bool = false,",
      ]
      extra_fields << "retry_count: u32 = 0," if meta[:retries] > 0

      # Per-cap destroyTask cleanup: if this cap's flag is still
      # set when the task dies, release the lock. Pushed onto the
      # unified fsm_destroy_lines pipeline as a :lock entry; the
      # final destroy_extra_zig orders locks LIFO of acquisition.
      ctx[:fsm_destroy_lines] ||= T.let([], T::Array[DestroyLine])
      T.cast(ctx[:fsm_destroy_lines], T::Array[DestroyLine]) << DestroyLine.new(
        kind: :lock,
        name: meta[:lock_field_ref].to_s,
        zig:  "if (__ctx_#{id}.__lock_held_#{cap_idx}) #{meta[:lock_field_ref]}.#{meta[:unlock_method]}();",
      )

      {
        lock_try_spec:  lock_try_spec,
        appended_specs: [woken_spec, retry_spec, fail_spec, held_set_spec],
        extra_fields:   extra_fields,
      }
    end

    # Resolve a SuspendDescriptor for a segment's suspend tail. Uses
    # SuspendResolvers (which lowers under the surrounding fiber
    # capture-map).
    sig { params(seg: T.untyped, ctx: T.untyped, lowering: T.untyped, capture_map: T.untyped, sp_idx: T.untyped).returns(T.untyped) }
    def build_segment_descriptor(seg, ctx, lowering, capture_map, sp_idx: nil)
      T.bind(self, T.untyped) rescue nil
      tail = seg.tail
      return nil unless Segments.suspend_tail?(tail)

      bg_rt = ctx[:bg_rt]
      pointer_captures = ctx[:pointer_captures]
      result = lowering.with_bg_fiber_body_context(pointer_captures || Set.new) do
        lowering.with_fiber_capture_map(capture_map, rt_override: bg_rt) do
          # Caller-supplied sp_idx (allocated by compute_sp_indices in
          # dispatch order) takes precedence so sp_<N> labels track
          # 1-based suspend position, not segment-graph index.
          eff_sp = sp_idx || (seg.index + 1)
          SuspendResolvers.resolve(seg, ctx, lowering, susp_idx: eff_sp)
        end
      end
      result
    end

    # Walk the segment graph from index 0 in dispatch order (Goto /
    # tail.next_index / CondBranch.then|else_index) and assign
    # sp_1, sp_2, ... to each NEXT/IO suspend in the order
    # encountered. Returns { seg.index => sp_N }. Suspends that are
    # unreachable from index 0 fall back to a follow-up scan
    # (rare).
    sig { params(segments: T.untyped).returns(T::Hash[Integer, Integer]) }
    def compute_sp_indices(segments)
      T.bind(self, T.untyped) rescue nil
      out = {}
      counter = 1
      visited = {}
      stack = [0]
      while (idx = stack.pop)
        next if visited[idx]
        visited[idx] = true
        seg = segments[idx]
        next unless seg
        if Segments.suspend_tail?(seg.tail)
          out[seg.index] = counter
          counter += 1
        end
        case seg.tail
        when Segments::Goto, Segments::LoopBack
          stack.push(seg.tail.target_index)
        when Segments::CondBranch
          stack.push(seg.tail.then_index)
          stack.push(seg.tail.else_index)
        when Segments::LockSuspend
          stack.push(seg.tail.next_index) if seg.tail.next_index
        else
          stack.push(seg.tail.next_index) if Segments.suspend_tail?(seg.tail) && seg.tail.next_index
        end
      end
      # Pick up any unreachable suspends.
      segments.each do |seg|
        next if out.key?(seg.index)
        next unless Segments.suspend_tail?(seg.tail)
        out[seg.index] = counter
        counter += 1
      end
      out
    end

    # Shared spawn/init/break setup. Identical across all FSM
    # body shapes.
    sig { params(ctx: T.untyped, lowering: T.untyped).returns(MIR::FsmSpawnSetup) }
    def build_spawn_setup(ctx, lowering)
      T.bind(self, T.untyped) rescue nil
      is_local_pin = (ctx[:pin_mode] == true || ctx[:pin_mode] == :local)
      is_default_local = (ctx[:pin_mode].nil? || ctx[:pin_mode] == false) && !ctx[:parallel]
      is_local_dispatch = is_local_pin || is_default_local
      dispatch = is_local_dispatch ? :local : :parallel
      spawn_call_zig =
        if is_local_dispatch
          "try #{ctx[:rt_name]}.getSched().submitFsmSpawn(#{ctx[:ctx_var]}.task);"
        else
          "try CheatHeader.spawnFsmBest(#{ctx[:ctx_var]}.task);"
        end
      alloc_expr_zig = is_local_dispatch ?
        "#{ctx[:rt_name]}.getSched().allocator" : "#{ctx[:rt_name]}.heapAlloc()"

      # `.task = undefined` and `.rt = undefined` here are rebound by
      # render_spawn_setup AFTER allocFsmTask + allocFsmTaskRuntime.
      # The FsmTask is allocated from the scheduler's fsm_task_slab
      # (so detectCycleFsm can pin it during chain walks); ctx.task
      # is a *FsmTask pointer to the slab slot.
      ctx_init_zig = [
        ".task = undefined,",
        ".rt = undefined,",
        ".inner = #{ctx[:promise_var]}.inner,",
        ".alloc = #{ctx[:alloc_var]},",
        lowering.capture_inits_fsm(ctx[:capture_inits]),
      ].reject { |l| l.nil? || l.strip.empty? }.join("\n")

      MIR::FsmSpawnSetup.new(
        ctx[:alloc_var], alloc_expr_zig,
        ctx[:promise_var], ctx[:promise_zig],
        ctx[:promoted_decls],
        ctx[:ctx_var], ctx[:ctx_type],
        ctx_init_zig,
        spawn_call_zig,
        ctx[:rt_name],
        ctx[:profile_site_id],
        profile_dispatch_id(dispatch),
        bg_profile_site_comment(ctx, dispatch, :fsm),
      )
    end

    sig { params(dispatch: T.untyped).returns(Integer) }
    def profile_dispatch_id(dispatch)
      T.bind(self, T.untyped) rescue nil
      case dispatch
      when :local, true then 1
      when :parallel then 2
      when :shared then 3
      else 1
      end
    end

    sig { params(ctx: T.untyped, dispatch: T.untyped, form: T.untyped).returns(String) }
    def bg_profile_site_comment(ctx, dispatch, form)
      T.bind(self, T.untyped) rescue nil
      "// CLEAR_PROFILE_TASK_SITE id=#{ctx[:profile_site_id]} kind=BG line=#{ctx[:profile_line]} column=#{ctx[:profile_column]} dispatch=#{dispatch} form=#{form}"
    end
  end
end
