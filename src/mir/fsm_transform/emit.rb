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
require_relative "context"
require_relative "segments"
require_relative "recursive_splitter"
require_relative "liveness"
require_relative "suspend_resolvers"

module FsmTransform
  module Emit
    extend T::Sig
    module_function

    PromotableFsmValue = T.type_alias { T.any(MIR::Node, Object) }
    FsmBodyEmission = T.type_alias { MIR::Node }
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

    class FsmBodyItem < T::Struct
      extend T::Sig

      const :emission, FsmBodyEmission
      const :fact_node_value, T.nilable(MIR::Node)

      sig { params(node: MIR::Node).returns(FsmBodyItem) }
      def self.mir(node)
        FsmBodyItem.new(
          emission: node,
          fact_node_value: node,
        )
      end

      sig { returns(FsmBodyEmission) }
      def emit_value
        emission
      end

      sig { returns(T.nilable(MIR::Node)) }
      def fact_node
        fact_node_value
      end

      sig { returns(T::Boolean) }
      def blank?
        false
      end
    end

    class FsmSegmentFacts < T::Struct
      extend T::Sig

      const :ctx_reads, T::Array[String], default: []
      const :required_move_guards, T::Array[String], default: []
      const :move_guard_writes, T::Array[String], default: []
      const :result_names, T::Array[String], default: []
      const :ownership_facts, T::Array[MIR::FsmOwnershipFact], default: []

      sig { returns(FsmSegmentFacts) }
      def self.empty
        FsmSegmentFacts.new
      end
    end

    class FsmSegmentSpec < T::Struct
      extend T::Sig

      const :index, Integer
      const :prologue_stmts, T::Array[FsmBodyItem], default: []
      const :body_stmts, T::Array[FsmBodyItem], default: []
      const :structure_stmts, T::Array[MIR::Node], default: []
      const :tail, SegmentTail
      const :descriptor, T.nilable(MIR::SuspendDescriptor), default: nil
      const :fsm_result_transfer_facts, T::Array[MIR::FsmResultTransferFact], default: []
      const :fn_name, T.nilable(String), default: nil
      const :suppress_runtime_ref, T::Boolean, default: false
      const :err_cleanups, T::Array[MIR::Node], default: []
      const :pre_body_skip, T.nilable(MIR::FsmTailCondSkip), default: nil
      const :pre_body_stmts, T::Array[MIR::Node], default: []
      const :extra_prologue_stmts, T::Array[MIR::Node], default: []
      const :facts, FsmSegmentFacts, default: FsmSegmentFacts.empty

      sig { params(facts: FsmSegmentFacts).returns(FsmSegmentSpec) }
      def with_facts(facts)
        FsmSegmentSpec.new(
          index: index,
          prologue_stmts: prologue_stmts,
          body_stmts: body_stmts,
          structure_stmts: structure_stmts,
          tail: tail,
          descriptor: descriptor,
          fsm_result_transfer_facts: fsm_result_transfer_facts,
          fn_name: fn_name,
          suppress_runtime_ref: suppress_runtime_ref,
          err_cleanups: err_cleanups,
          pre_body_skip: pre_body_skip,
          pre_body_stmts: pre_body_stmts,
          extra_prologue_stmts: extra_prologue_stmts,
          facts: facts,
        )
      end
    end

    class ExpandedLockSegment < T::Struct
      const :lock_try_spec, FsmSegmentSpec
      const :appended_specs, T::Array[FsmSegmentSpec]
      const :extra_fields, T::Array[MIR::ContextFieldDecl]
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
    #                            body_stmts:      [MIR::Stmt],
    #                            tail:            Segments::*,
    #                            descriptor:      MIR::SuspendDescriptor | nil,
    #                            fn_name:         String,    # "runStep0",
    #                                                          "runSeg0",
    #                                                          "runPre", ...
    #                            suppress_runtime_ref: Boolean,
    #                            err_cleanups:    [MIR::Stmt] | nil,
    #                            pre_body_skip:   MIR::FsmTailCondSkip | nil,
    #                            pre_body_stmts:  [MIR::Node],
    #                          }
    #
    # `prologue_stmts` runs FIRST in the runStepK fn, BEFORE the
    # prior descriptor's bind_stmts. Used for entries like
    # arena_init (seg 0) and capture_frees_defer (the segment
    # whose runStep is the FSM's last entry) -- these must
    # register defers before any potentially-erroring bind block.
    #
    # `suppress_runtime_ref` asks the wrapper to emit `_ = &<bg_rt>;`
    # top of runStepK when the rendered body doesn't reference
    # bg_rt (avoiding the unused-binding diagnostic). The caller
    # computes this from the rendered body text -- the unified
    # emit can't reliably introspect MIR nodes for the check.
    #
    # `err_cleanups` are direct (non-defer) stmts injected into
    # the dispatch arm's catch handler before the standard
    # store-err / wg.done / destroy / Done sequence. Used by
    # B2-IO step-0 for capture frees on setup error.
    #   promoted_field_decls -- [MIR::ContextFieldDecl] from Liveness.
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
    sig { params(ctx: FsmEmitContext, segment_specs: T::Array[FsmSegmentSpec], promoted_field_decls: T::Array[MIR::ContextFieldDecl], lowering: Object).returns(T.nilable(MIR::FsmLoweringResult)) }
    def build_fsm_unified(ctx, segment_specs, promoted_field_decls, lowering)
      return nil if segment_specs.empty?

      id = ctx.id
      bg_rt = ctx.bg_rt
      destroy_actions = ordered_fsm_destroy_actions(ctx)
      segment_specs = materialize_fsm_segment_facts(
        segment_specs, id, fsm_destroy_cleanup_names(destroy_actions)
      )

      # 1. Compose member fn body_stmts: segment body + setup at end
      #    + bind from the suspend whose next_index points HERE at
      #    start. Bind targeting via next_index (not array adjacency)
      #    matters once the recursive splitter produces non-linear
      #    segment graphs -- a suspend at position K can resume to
      #    any position M, and M's body must run K's bind.
      bind_for_index = T.let({}, T::Hash[Integer, T::Array[FsmBodyItem]])
      segment_specs.each do |s|
        d = s.descriptor
        next unless d && d.bind_stmts && !d.bind_stmts.empty?
        target = tail_resume_target(s.tail) || (segment_specs.index(s) || 0) + 1
        bind_for_index[target] = fsm_body_mir_items(d.bind_stmts)
      end

      body_fn_names_by_index = T.let({}, T::Hash[Integer, String])
      member_fns = segment_specs.filter_map do |spec|
        body = T.let([], T::Array[FsmBodyItem])
        body.concat(spec.prologue_stmts)
        incoming_bind = bind_for_index[spec.index]
        fn_name = spec.fn_name
        if incoming_bind
          fn_name ||= "runSeg#{spec.index}"
          body.concat(incoming_bind)
        end
        next nil if fn_name.nil?
        body_fn_names_by_index[spec.index] = fn_name
        body.concat(spec.body_stmts)
        if (d = spec.descriptor)
          body.concat(fsm_body_mir_items(d.setup_stmts || []))
        end
        body.compact!
        body.reject!(&:blank?)

        MIR::FsmMemberFn.new(
          fn_name, id, bg_rt, spec.suppress_runtime_ref, fsm_body_emit_values(body),
          spec.extra_prologue_stmts,
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
          spec.index,
          spec.pre_body_skip,
          spec.pre_body_stmts,
          body_fn_names_by_index[spec.index],
          spec.err_cleanups,
          tail,
        )
      end
      dispatch = MIR::FsmDispatch.new(id, arms, true)

      # 3. Extra ctx fields: step counter + each descriptor's
      #    suspend-protocol fields + caller-supplied extras (used by
      #    WITH for lock_waiter + retry_count, since those don't
      #    correspond to a generic suspend descriptor today).
      extra_field_decls = [ctx_field_decl("step", "u8", MIR::Lit.new("0"))]
      segment_specs.each do |spec|
        d = spec.descriptor
        next unless d
        extra_field_decls.concat(d.ctx_field_decls || [])
      end
      extra_field_decls.concat(ctx.extra_ctx_fields)
      seen_extra_names = T.let({}, T::Hash[String, T::Boolean])
      extra_field_decls = extra_field_decls.reject do |decl|
        name = decl.name
        duplicate = seen_extra_names[name] == true
        seen_extra_names[name] = true
        duplicate
      end
      capture_field_names = ctx.capture_fields.each_with_object({}) do |field, names|
        names[field.name] = true
      end
      extra_field_decls = extra_field_decls.reject do |decl|
        capture_field_names[decl.name]
      end
      extra_field_names = extra_field_decls.each_with_object(capture_field_names.dup) do |decl, names|
        names[decl.name] = true unless decl.name.empty?
      end
      promoted_field_decls = promoted_field_decls.reject do |decl|
        extra_field_names[decl.name]
      end

      # 4. Wrap in FsmGenericCtxStruct + spawn_setup + FsmGenericBody.
      # Assemble structural destroy actions. Locks run first (so other
      # tasks can acquire) in reverse acquisition order, then captures,
      # then lifted body / owned-result cleanups.
      ctx_struct = MIR::FsmGenericCtxStruct.new(
        ctx.ctx_type, ctx.promise_zig, ctx.capture_fields,
        extra_field_decls, promoted_field_decls,
        member_fns, dispatch, destroy_actions,
      )
      spawn_setup = build_spawn_setup(ctx, lowering)
      fsm_body = MIR::FsmGenericBody.new(ctx.blk_label, ctx_struct, spawn_setup)
      MIR::FsmLoweringResult.new(
        body: fsm_body,
        structure: build_fsm_structure(ctx, segment_specs, destroy_actions, id),
      )
    end

    sig { params(ctx: FsmEmitContext, segment_specs: T::Array[FsmSegmentSpec], destroy_actions: T::Array[MIR::FsmDestroyAction], id: Integer).returns(MIR::FsmStructure) }
    def build_fsm_structure(ctx, segment_specs, destroy_actions, id)
      cleanup_names = fsm_destroy_cleanup_names(destroy_actions)
      captured = ctx.captured
      capture_names = captured.keys.map(&:to_s)
      captures = capture_names.filter_map do |name|
        next nil unless cleanup_names.include?(name)
        MIR::FsmCaptureFact.new(name: name, cleanup_at: :finalize)
      end
      steps = segment_specs.map do |spec|
        MIR::FsmStepFact.new(
          index: spec.index,
          reads: spec.facts.ctx_reads,
          cleanups: [],
        )
      end
      structure = MIR::FsmStructure.new(captures, [], steps, cleanup_names, id, nil)
      structure.required_move_guards = segment_specs.flat_map { |spec| spec.facts.required_move_guards }.uniq
      structure.move_guard_writes = segment_specs.flat_map { |spec| spec.facts.move_guard_writes }.uniq
      structure.ownership_facts = unique_fsm_ownership_facts(
        segment_specs.flat_map { |spec| spec.facts.ownership_facts }
      )
      structure.destroy_actions = destroy_actions
      structure
    end

    sig { params(ctx: FsmEmitContext).returns(T::Array[MIR::FsmDestroyAction]) }
    def fsm_destroy_actions(ctx)
      ctx.destroy_actions
    end

    sig { params(ctx: FsmEmitContext).returns(T::Array[MIR::FsmDestroyAction]) }
    def ordered_fsm_destroy_actions(ctx)
      fsm_destroy_actions(ctx).each_with_index.sort_by do |action, index|
        [action.destroy_order_bucket, action.destroy_order_index(index)]
      end.map(&:first)
    end

    sig { params(actions: T::Array[MIR::FsmDestroyAction]).returns(T::Array[String]) }
    def fsm_destroy_cleanup_names(actions)
      actions.filter_map(&:cleanup_name).uniq
    end

    sig { params(tail: SegmentTail).returns(T.nilable(Integer)) }
    def tail_resume_target(tail)
      case tail
      when Segments::IoSuspend, Segments::NextSuspend, Segments::LockSuspend
        tail.next_index
      when MIR::FsmTailJump, MIR::FsmTailYield, MIR::FsmTailRegisterYield
        tail.next_step
      else
        nil
      end
    end

    sig { params(segment_specs: T::Array[FsmSegmentSpec], id: Integer, cleanup_names: T::Array[String]).returns(T::Array[FsmSegmentSpec]) }
    def materialize_fsm_segment_facts(segment_specs, id, cleanup_names)
      segment_specs.map do |spec|
        spec.with_facts(build_fsm_segment_facts(spec, id, cleanup_names))
      end
    end

    sig { params(spec: FsmSegmentSpec, id: Integer, cleanup_names: T::Array[String]).returns(FsmSegmentFacts) }
    def build_fsm_segment_facts(spec, id, cleanup_names)
      nodes = collect_fsm_nodes(fsm_segment_fact_roots(spec))
      result_names = collect_result_names(nodes, id)
      result_facts = result_names.map do |name|
        MIR::FsmOwnershipFact.new(name: name, target: :result, target_alloc: :heap, move_guarded: true)
      end
      structured_facts = spec.fsm_result_transfer_facts.filter_map do |fact|
        guard_name = fsm_fact_guard_name(fact.name)
        next nil if guard_name.empty?

        MIR::FsmOwnershipFact.new(
          name: guard_name,
          target: :result,
          target_alloc: fact.target_alloc,
          move_guarded: fact.move_guarded,
        )
      end

      FsmSegmentFacts.new(
        ctx_reads: collect_ctx_field_reads(nodes, id),
        required_move_guards: collect_required_move_guards(nodes, id, cleanup_names),
        move_guard_writes: collect_move_guard_writes(nodes, id),
        result_names: result_names,
        ownership_facts: unique_fsm_ownership_facts(structured_facts + result_facts),
      )
    end

    sig { params(spec: FsmSegmentSpec).returns(T::Array[MIR::Node]) }
    def fsm_segment_fact_roots(spec)
      roots = T.let([], T::Array[MIR::Node])
      roots.concat(fsm_body_mir_nodes(spec.prologue_stmts))
      roots.concat(spec.structure_stmts.empty? ? fsm_body_mir_nodes(spec.body_stmts) : spec.structure_stmts)
      descriptor = spec.descriptor
      if descriptor
        roots.concat(descriptor.setup_stmts)
        roots.concat(descriptor.bind_stmts)
      end
      roots
    end

    sig { params(stmts: T::Array[FsmBodyItem]).returns(T::Array[MIR::Node]) }
    def fsm_body_mir_nodes(stmts)
      stmts.filter_map(&:fact_node)
    end

    sig { params(node: MIR::Node).returns(FsmBodyItem) }
    def fsm_body_mir_item(node)
      FsmBodyItem.mir(node)
    end

    sig { params(nodes: T::Array[MIR::Node]).returns(T::Array[FsmBodyItem]) }
    def fsm_body_mir_items(nodes)
      nodes.map { |node| fsm_body_mir_item(node) }
    end

    sig { params(items: T::Array[FsmBodyItem]).returns(T::Array[FsmBodyEmission]) }
    def fsm_body_emit_values(items)
      items.map(&:emit_value)
    end

    sig { params(items: T::Array[FsmBodyItem]).returns(String) }
    def fsm_body_joined_text(items)
      fsm_body_emit_values(items).join("\n")
    end

    sig { params(ctx_id: Integer, lock_index: Integer, lock_ref: String, unlock_method: String).returns(T::Array[MIR::Node]) }
    def prior_lock_release_stmts(ctx_id, lock_index, lock_ref, unlock_method)
      [
        MIR::Set.new(
          MIR::Ident.new("__ctx_#{ctx_id}.__lock_held_#{lock_index}"),
          MIR::Lit.new("false"),
          false,
        ),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(MIR::Ident.new(lock_ref), unlock_method, [], false),
          false,
        ),
      ]
    end

    sig { params(facts: T::Array[MIR::FsmOwnershipFact]).returns(T::Array[MIR::FsmOwnershipFact]) }
    def unique_fsm_ownership_facts(facts)
      facts.uniq do |fact|
        [fact.name, fact.target, fact.target_alloc, fact.move_guarded]
      end
    end

    sig { params(nodes: T::Array[MIR::Node], id: Integer, cleanup_names: T::Array[String]).returns(T::Array[String]) }
    def collect_required_move_guards(nodes, id, cleanup_names)
      nodes.filter_map do |node|
        next nil unless node.is_a?(MIR::TransferMark)
        next nil unless node.target == :owned_sink || node.target == :return
        name = normalized_ctx_field_name(node.name.to_s, id)
        cleanup_names.include?(name) ? name : nil
      end.uniq
    end

    sig { params(nodes: T::Array[MIR::Node], id: Integer).returns(T::Array[String]) }
    def collect_move_guard_writes(nodes, id)
      nodes.filter_map do |node|
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

    sig { params(nodes: T::Array[MIR::Node], id: Integer).returns(T::Array[String]) }
    def collect_result_names(nodes, id)
      nodes.filter_map do |node|
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

    sig { params(nodes: T::Array[MIR::Node], id: Integer).returns(T::Array[String]) }
    def collect_ctx_field_reads(nodes, id)
      nodes.filter_map do |node|
        ctx_field_name(node, id)
      end.uniq
    end

    sig { params(roots: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
    def collect_fsm_nodes(roots)
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
    sig { params(spec: FsmSegmentSpec, k: Integer, all_specs: T::Array[FsmSegmentSpec], id: Integer).returns(FsmTail) }
    def build_dispatch_tail(spec, k, all_specs, id)
      _ = k
      _ = all_specs
      tail = spec.tail
      desc = spec.descriptor
      index = spec.index
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
        condition = tail.cond_ast
        unless condition.is_a?(MIR::Emittable)
          Kernel.raise ArgumentError,
            "CondBranch tail condition must be structural MIR, got #{condition.class}"
        end
        MIR::FsmTailCondJump.new(condition, tail.then_index, tail.else_index)
      when Segments::IoSuspend, Segments::NextSuspend
        # Descriptor produced an FsmTailYield(nil, ...) or
        # FsmTailRegisterYield(nil, ..., ...) -- fill in the next
        # step index. Honor explicit next_index on the suspend tail
        # (the recursive splitter sets it to target arbitrary
        # segments, e.g. for loop-back semantics); otherwise fall
        # back to the linear seg.index + 1 default.
        Kernel.raise ArgumentError,
          "Suspend tail in segment #{index} has no descriptor" if desc.nil?
        explicit_next = tail.respond_to?(:next_index) ? tail.next_index : nil
        target_step = explicit_next || next_step
        desc_tail = desc.tail
        case desc_tail
        when MIR::FsmTailYield
          MIR::FsmTailYield.new(target_step, desc_tail.yield_reason)
        when MIR::FsmTailRegisterYield
          MIR::FsmTailRegisterYield.new(
            target_step, desc_tail.register_expr, desc_tail.yield_reason,
          )
        else
          Kernel.raise ArgumentError,
            "Unsupported descriptor tail #{desc_tail.class} in segment #{index}"
        end
      else
        Kernel.raise ArgumentError,
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
    # capture_inits, captured, capture_close_plans, pointer_captures,
    # arena_init_flag, is_void).
    #
    # `lowering` is the MIRLowering instance; we use it for
    # capture-map context (with_fiber_capture_map) and AST -> MIR
    # lowering. Rendering stays at the final wrapper emitter edge.
    #
    # `liveness` is the Liveness analysis result; promoted_field_decls
    # are derived from cross_segment_vars.
    sig { params(ctx: FsmEmitContext, segments: RecursiveSplitter::SegmentList, liveness: Liveness::Result, lowering: Object).returns(T.nilable(MIR::FsmLoweringResult)) }
    def build_recursive(ctx, segments, liveness, lowering)
      T.bind(self, T.untyped) rescue nil
      return nil if segments.segments.empty?

      id = ctx.id
      bg_rt = ctx.bg_rt
      captured = ctx.captured
      capture_close_plans = ctx.capture_close_plans
      pointer_captures = ctx.pointer_captures
      arena_init_flag = ctx.arena_init_flag
      recursive_promoted_names = ctx.recursive_promoted_names
      extra_ctx_fields = ctx.extra_ctx_fields
      fresh_heap_cleanup_names = ctx.fresh_heap_cleanup_names
      is_void = ctx.is_void
      lowering_api = T.unsafe(lowering)

      segment_list = segments
      segments = segment_list.segments

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
            ctx_field_decl(name.to_s, t ? t.zig_type : "anyopaque", MIR::Undef.new(nil))
          end
      promoted_guard_decls = fsm_promoted_names.map { |name| ctx_field_decl("#{name}_moved", "bool", MIR::Lit.new("false")) }
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

      arena_init_stmt = if arena_init_flag
        MIR::Set.new(MIR::FieldGet.new(MIR::Ident.new(bg_rt), "arena_mode"), MIR::Lit.new("true"), false)
      end
      # FSM destroy pipeline: ONE source of truth for cleanups that
      # must fire when the FSM task ends, regardless of whether the
      # body completes successfully or errors out. Zig `defer` is
      # not safe for these: each runSegN fn is its own stack frame,
      # so a defer placed in any one runFn fires when THAT fn
      # returns -- before the BG body as a whole has finished.
      #
      # Three categories converge here as structural destroy actions:
      # locks, capture cleanups, and lifted body/owned-result cleanups.
      ctx.destroy_actions = []
      captured.each do |name, _|
        close_plan = capture_close_plans[name]
        next unless close_plan

        fsm_destroy_actions(ctx) << MIR::FsmDestroyCleanup.new(
          source_kind: :capture,
          name: name.to_s,
          target: fsm_ctx_field(id, name.to_s),
          cleanup_entry: CleanupEntry.build(
            :resource,
            alloc: :heap,
            has_moved_guard: false,
            resource_close_plan: close_plan,
          ),
        )
      end
      # FreshHeapCopy captures are fiber-owned ctx fields. Register the
      # cleanup from the capture names and a CleanupEntry instead of
      # stripping `defer` from a previously rendered Zig line.
      fresh_heap_cleanup_names.each do |name|
        fsm_destroy_actions(ctx) << MIR::FsmDestroyCleanup.new(
          source_kind: :fresh_heap,
          name: name,
          target: fsm_ctx_field(id, name),
          cleanup_entry: CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: true),
          allocator: fsm_ctx_field(id, "alloc"),
        )
      end

      # Per-segment lowering. Stmts may be user AST nodes or MIR
      # nodes synthesized by the splitter. MIR nodes pass through
      # structurally; user AST nodes go through lower_step_stmts.
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
      seg_result_facts = T.let({}, T::Hash[Integer, T::Array[MIR::FsmResultTransferFact]])
      seg_mir_codes = T.let([], T::Array[T::Array[MIR::Node]])
      seg_codes = segments.each_with_index.map do |seg, i|
        mir_stmts = T.let([], T::Array[MIR::Node])
        ast_stmts = T.let([], T::Array[AST::Node])
        seg.stmts.each do |stmt|
          if stmt.is_a?(MIR::Emittable)
            mir_stmts << stmt
          else
            ast_stmts << T.cast(stmt, AST::Node)
          end
        end
        if ast_stmts.empty?
          seg_mir_codes[i] = mir_stmts
          fsm_body_mir_items(mir_stmts)
        else
          want_result = !is_void && result_seg_indices.include?(seg.index)
          inherited_capture_names = T.let(
            fsm_destroy_actions(ctx).filter_map(&:ctx_cleanup_target_name).to_set,
            T::Set[String],
          )
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
          facts = T.cast(
            lowering_api.last_fsm_result_transfer_facts,
            T::Array[MIR::FsmResultTransferFact],
          )
          seg_result_facts[seg.index] = facts
          return nil if lowered_mir.nil?
          lowered_mir = mir_stmts + lowered_mir
          all_promoted = fsm_promoted_names + captured.keys.map(&:to_s)
          if all_promoted.any?
            promoted_names = all_promoted.uniq
            lowered_mir = promote_fsm_mir_to_ctx_fields(lowered_mir, promoted_names, id)
            lowered_mir = lift_ctx_cleanups_to_destroy!(lowered_mir, promoted_names, "__ctx_#{id}", ctx)
          end
          seg_mir_codes[i] = lowered_mir
          fsm_body_mir_items(lowered_mir)
        end
      end

      # FSM cleanup invariant: no `defer NAME.<method>(...)` may
      # appear in any segment fn where NAME is a cross-segment ctx
      # field (captured value, recursively-promoted local, or
      # liveness cross-segment var). Such a defer would fire when
      # that segment's runFn returns -- before the BG body as a
      # whole has finished -- causing a use-after-free on the
      # remaining segments. The cleanup must be lifted to
      # destroyTask via ctx[:fsm_destroy_actions]. This sweep is the
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
      void_assign_stmt = if is_void
        MIR::Set.new(
          MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new("__ctx_#{id}"), "inner"), "result"),
          MIR::VoidLiteral.new,
          false,
        )
      end
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
            parts = T.let([], T::Array[FsmBodyItem])
            parts << fsm_body_mir_item(arena_init_stmt) if arena_init_stmt
            # Capture cleanups deliberately do NOT live in the
            # prologue: a Zig defer here fires when seg 0's runFn
            # returns -- before the BG body has finished running.
            # See ctx[:fsm_destroy_actions] / destroyTask above.
            parts.empty? ? nil : parts
          end

        body_stmts = Array(seg_codes[i])
        if void_assign_stmt && seg.tail.is_a?(Segments::Done)
          body_stmts = body_stmts + [fsm_body_mir_item(void_assign_stmt)]
        end

        prologue_stmts = prologue || []
        rt_used = (fsm_body_joined_text(body_stmts) +
                   fsm_body_joined_text(prologue_stmts) +
                   (descriptor && descriptor.setup_stmts || []).join("\n")).include?(bg_rt)
        suppress_runtime_ref = !rt_used

        FsmSegmentSpec.new(
          index:           seg.index,
          prologue_stmts:  prologue_stmts,
          body_stmts:      body_stmts,
          structure_stmts: seg_mir_codes[i] || [],
          tail:            seg.tail,
          descriptor:      descriptor,
          fsm_result_transfer_facts: seg_result_facts[seg.index] || [],
          fn_name:         "runSeg#{seg.index}",
          suppress_runtime_ref: suppress_runtime_ref,
        )
      end

      register_owned_suspend_result_cleanups!(segment_specs, ctx, id)

      # Expand any Segments::LockSuspend specs into the 5-segment
      # lock fan-out (FsmTailLockTry / FsmTailWokenCheck /
      # FsmTailRetryOrError + error arm + CS body). Lock-acquire is
      # the only suspend kind that needs multiple dispatch arms; the
      # expansion concentrates that complexity here so the splitter
      # stays purely structural.
      lock_extra_fields = T.let([], T::Array[MIR::ContextFieldDecl])
      next_extra_idx = segment_specs.length
      expanded_specs = []
      segment_specs.each do |spec|
        if spec.tail.is_a?(Segments::LockSuspend)
          out = expand_lock_segment(spec, ctx, capture_map,
                                    lowering, next_extra_idx)
          return nil if out.nil?
          expanded_specs << out.lock_try_spec
          expanded_specs.concat(out.appended_specs)
          lock_extra_fields.concat(out.extra_fields)
          next_extra_idx += out.appended_specs.length
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
        name = decl.name.to_s
        next false if name.nil? || name.empty?
        if seen_names[name]
          true
        else
          seen_names[name] = true
          false
        end
      end
      ctx_with_extras = ctx.with_extra_ctx_fields(deduped)
      build_fsm_unified(ctx_with_extras, segment_specs, promoted_field_decls, lowering)
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

    sig { params(body: T::Array[MIR::Node], promoted_names: T::Array[String], ctx_ref: String, ctx: FsmEmitContext).returns(T::Array[MIR::Node]) }
    def lift_ctx_cleanups_to_destroy!(body, promoted_names, ctx_ref, ctx)
      body.filter_map do |node|
        if node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
          promoted_name = promoted_fsm_field_name(node.name.to_s, promoted_names)
          if promoted_name
            fsm_destroy_actions(ctx) << MIR::FsmDestroyCleanup.new(
              source_kind: :body,
              name: promoted_name,
              target: MIR::FieldGet.new(MIR::Ident.new(ctx_ref), promoted_name),
              cleanup_entry: node.cleanup_entry,
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

    sig { params(segment_specs: T::Array[FsmSegmentSpec], ctx: FsmEmitContext, id: Integer).void }
    def register_owned_suspend_result_cleanups!(segment_specs, ctx, id)
      seen = Set.new
      segment_specs.each do |spec|
        desc = spec.descriptor
        next unless desc && desc.result_needs_cleanup && desc.result_var
        name = desc.result_var.to_s
        next unless seen.add?(name)
        guard = SuspendResolvers.fsm_owned_guard_name(name)
        fsm_destroy_actions(ctx) << MIR::FsmDestroyCleanup.new(
          source_kind: :owned_result,
          name: name,
          target: fsm_ctx_field(id, name),
          cleanup_entry: CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false),
          guard: fsm_ctx_field(id, guard),
        )
      end
    end

    # FSM cleanup invariant checker. Walks each segment's lowered
    # Zig and asserts that no `defer NAME.<method>(...)` line
    # references a cross-segment ctx field. Such a defer would fire
    # when its runSegN returns -- before the BG body completes --
    # so it must be lifted to destroyTask via fsm_destroy_actions.
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
                "destroyTask via ctx[:fsm_destroy_actions]."
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
    sig { params(spec: FsmSegmentSpec, ctx: FsmEmitContext, capture_map: T::Hash[String, String], lowering: Object, base_idx: Integer).returns(T.nilable(ExpandedLockSegment)) }
    def expand_lock_segment(spec, ctx, capture_map, lowering, base_idx)
      lowering_api = T.unsafe(lowering)
      tail      = T.cast(spec.tail, Segments::LockSuspend)
      with_node = tail.with_node
      cap       = tail.cap
      prior     = tail.prior_caps || []
      after_idx = tail.next_index
      bg_rt = ctx.bg_rt
      id    = ctx.id
      captured = ctx.captured

      meta = lowering_api.fsm_cap_metadata(cap, with_node, id, captured)
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
        m = lowering_api.fsm_cap_metadata(c, with_node, id, captured)
        return nil if m.nil?
        m
      }

      pointer_captures = ctx.pointer_captures
      err =
        if with_node.lock_error_clause
          lowering_api.emit_fsm_lock_error_arm_split(
            clause:           with_node.lock_error_clause,
            ctx_id:           id,
            with_node:        with_node,
            capture_map:      capture_map,
            pointer_captures: pointer_captures,
            bg_rt:            bg_rt,
          )
        else
          lowering_api.default_fsm_lock_error_arm_split(id)
        end
      return nil if err.nil?

      # Fail body: clear + unlock any prior caps in reverse, then
      # user clause. The held flag for THIS cap stays false (we
      # never set it because acquire failed).
      prior_release_stmts = prior_meta.each_with_index.map do |m, i|
        prior_lock_release_stmts(
          id,
          i,
          m[:lock_field_ref].to_s,
          m[:unlock_method].to_s,
        )
      end.reverse.flatten
      fail_body_stmts = prior_release_stmts + err.body_stmts

      fail_tail = err.exit_kind == :done ?
                    Segments::Done.new(nil) :
                    Segments::Goto.new(after_idx)

      has_step_work = !spec.prologue_stmts.empty? || !spec.body_stmts.empty?
      lock_try_spec = FsmSegmentSpec.new(
        index:          spec.index,
        prologue_stmts: spec.prologue_stmts,
        body_stmts:     spec.body_stmts,
        structure_stmts: spec.structure_stmts,
        tail:           MIR::FsmTailLockTry.new(
                           meta[:try_method], meta[:lock_field_ref],
                           try_success_idx, woken_idx, retry_idx,
                         ),
        descriptor:     nil,
        fsm_result_transfer_facts: spec.fsm_result_transfer_facts,
        fn_name:        has_step_work ? spec.fn_name : nil,
        suppress_runtime_ref: spec.suppress_runtime_ref,
      )
      woken_spec = FsmSegmentSpec.new(
        index:        woken_idx, body_stmts: [],
        tail:         MIR::FsmTailWokenCheck.new(try_success_idx, retry_idx),
        descriptor:   nil, fn_name: nil,
        suppress_runtime_ref: true,
      )
      retry_spec = FsmSegmentSpec.new(
        index:        retry_idx, body_stmts: [],
        tail:         MIR::FsmTailRetryOrError.new(meta[:retries], spec.index, fail_idx),
        descriptor:   nil, fn_name: nil,
        suppress_runtime_ref: true,
      )
      fail_spec = FsmSegmentSpec.new(
        index:        fail_idx,
        body_stmts:   [],
        pre_body_stmts: fail_body_stmts,
        tail:         fail_tail,
        descriptor:   nil, fn_name: nil,
        suppress_runtime_ref: true,
      )
      held_set_stmt = MIR::Set.new(
        MIR::FieldGet.new(MIR::Ident.new("__ctx_#{id}"), "__lock_held_#{cap_idx}"),
        MIR::Lit.new("true"),
        false,
      )
      held_set_spec = FsmSegmentSpec.new(
        index:        held_set_idx,
        body_stmts:   [],
        pre_body_stmts: [held_set_stmt],
        tail:         Segments::Goto.new(tail.post_acquire_idx),
        descriptor:   nil, fn_name: nil,
        suppress_runtime_ref: true,
      )

      extra_fields = [
        ctx_field_decl("lock_waiter", "CheatHeader.WaiterNode", MIR::Undef.new(nil)),
        ctx_field_decl("__lock_held_#{cap_idx}", "bool", MIR::Lit.new("false")),
      ]
      extra_fields << ctx_field_decl("retry_count", "u32", MIR::Lit.new("0")) if meta[:retries] > 0

      # Per-cap destroyTask cleanup: if this cap's flag is still set
      # when the task dies, release the lock. The finalizer orders lock
      # releases LIFO of acquisition.
      fsm_destroy_actions(ctx) << MIR::FsmDestroyLockRelease.new(
        name: meta[:lock_field_ref].to_s,
        guard_field: "__lock_held_#{cap_idx}",
        lock_ref: MIR::Ident.new(meta[:lock_field_ref].to_s),
        unlock_method: meta[:unlock_method].to_s,
      )

      ExpandedLockSegment.new(
        lock_try_spec:  lock_try_spec,
        appended_specs: [woken_spec, retry_spec, fail_spec, held_set_spec],
        extra_fields:   extra_fields,
      )
    end

    # Resolve a SuspendDescriptor for a segment's suspend tail. Uses
    # SuspendResolvers (which lowers under the surrounding fiber
    # capture-map).
    sig { params(seg: Segments::Segment, ctx: FsmEmitContext, lowering: Object, capture_map: T::Hash[String, String], sp_idx: T.nilable(Integer)).returns(T.nilable(MIR::SuspendDescriptor)) }
    def build_segment_descriptor(seg, ctx, lowering, capture_map, sp_idx: nil)
      lowering_api = T.unsafe(lowering)
      tail = seg.tail
      return nil unless Segments.suspend_tail?(tail)

      bg_rt = ctx.bg_rt
      pointer_captures = ctx.pointer_captures
      result = lowering_api.with_bg_fiber_body_context(pointer_captures || Set.new) do
        lowering_api.with_fiber_capture_map(capture_map, rt_override: bg_rt) do
          # Caller-supplied sp_idx (allocated by compute_sp_indices in
          # dispatch order) takes precedence so sp_<N> labels track
          # 1-based suspend position, not segment-graph index.
          eff_sp = sp_idx || (seg.index + 1)
          SuspendResolvers.resolve(seg, ctx, lowering_api, susp_idx: eff_sp)
        end
      end
      T.cast(result, T.nilable(MIR::SuspendDescriptor))
    end

    # Walk the segment graph from index 0 in dispatch order (Goto /
    # tail.next_index / CondBranch.then|else_index) and assign
    # sp_1, sp_2, ... to each NEXT/IO suspend in the order
    # encountered. Returns { seg.index => sp_N }. Suspends that are
    # unreachable from index 0 fall back to a follow-up scan
    # (rare).
    sig { params(segments: T::Array[Segments::Segment]).returns(T::Hash[Integer, Integer]) }
    def compute_sp_indices(segments)
      out = T.let({}, T::Hash[Integer, Integer])
      counter = T.let(1, Integer)
      visited = T.let({}, T::Hash[Integer, T::Boolean])
      stack = T.let([0], T::Array[Integer])
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
    sig { params(ctx: FsmEmitContext, lowering: Object).returns(MIR::FsmSpawnSetup) }
    def build_spawn_setup(ctx, lowering)
      is_local_pin = (ctx.pin_mode == true || ctx.pin_mode == :local)
      is_default_local = (ctx.pin_mode.nil? || ctx.pin_mode == false) && !ctx.parallel
      is_local_dispatch = is_local_pin || is_default_local
      dispatch = is_local_dispatch ? :local : :parallel
      spawn_call = MIR::FsmSpawnCall.new(
        target: is_local_dispatch ? :runtime_submit : :best,
        runtime_name: is_local_dispatch ? ctx.rt_name : nil,
        ctx_var: ctx.ctx_var,
      )
      alloc_expr = if is_local_dispatch
                     sched = MIR::MethodCall.new(
                       MIR::Ident.new(ctx.rt_name),
                       "getSched",
                       [],
                       false,
                       MIR::CallableContract.no_ownership(0),
                     )
                     MIR::FieldGet.new(sched, "allocator")
                   else
                     MIR::MethodCall.new(
                       MIR::Ident.new(ctx.rt_name),
                       "heapAlloc",
                       [],
                       false,
                       MIR::CallableContract.no_ownership(0),
                     )
                   end

      # `.task = undefined` and `.rt = undefined` here are rebound by
      # render_spawn_setup AFTER allocFsmTask + allocFsmTaskRuntime.
      # The FsmTask is allocated from the scheduler's fsm_task_slab
      # (so detectCycleFsm can pin it during chain walks); ctx.task
      # is a *FsmTask pointer to the slab slot.
      capture_inits = ctx.capture_inits.reject do |field|
        field.name.to_s == "inner" || field.name.to_s == "alloc"
      end
      ctx_init_fields = [
        MIR::StructInitField.new(name: :task, value: MIR::Undef.new(nil)),
        MIR::StructInitField.new(name: :rt, value: MIR::Undef.new(nil)),
        MIR::StructInitField.new(name: :inner, value: MIR::FieldGet.new(MIR::Ident.new(ctx.promise_var), "inner")),
        MIR::StructInitField.new(name: :alloc, value: MIR::Ident.new(ctx.alloc_var)),
      ] + capture_inits
      profile_site = if ctx.profile_site_id
                       MIR::ProfileTaskSite.new(
                         site_id: T.must(ctx.profile_site_id),
                         line: ctx.profile_line || 0,
                         column: ctx.profile_column || 0,
                         dispatch: dispatch,
                         form: :fsm,
                       )
                     end

      MIR::FsmSpawnSetup.new(
        ctx.alloc_var, alloc_expr,
        ctx.promise_var, ctx.promise_zig,
        ctx.promoted_decls,
        ctx.ctx_var, ctx.ctx_type,
        ctx_init_fields,
        spawn_call,
        ctx.rt_name,
        ctx.profile_site_id,
        profile_dispatch_id(dispatch),
        profile_site,
      )
    end

    sig { params(name: String, type_zig: String, default_value: T.nilable(MIR::Emittable)).returns(MIR::ContextFieldDecl) }
    def ctx_field_decl(name, type_zig, default_value)
      MIR::ContextFieldDecl.new(name: name, type_zig: type_zig, default_value: default_value)
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

    sig { params(ctx: FsmEmitContext, dispatch: T.any(Symbol, T::Boolean), form: Symbol).returns(String) }
    def bg_profile_site_comment(ctx, dispatch, form)
      "// CLEAR_PROFILE_TASK_SITE id=#{ctx.profile_site_id} kind=BG line=#{ctx.profile_line} column=#{ctx.profile_column} dispatch=#{dispatch} form=#{form}"
    end
  end
end
