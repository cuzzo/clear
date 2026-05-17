# typed: strict
# mir_checker.rb -- Post-lowering MIR verification.
#
# THE INVARIANTS THIS CHECKER ENFORCES (and nothing else):
#
#   INV-ALLOC-CLEANUP: Every MIR::AllocMark has at least one matching
#     MIR::Cleanup or MIR::ErrCleanup for the same binding name, and
#     the allocators match, unless a MIR::TransferMark records that
#     ownership left the current scope. (HPT_LEAK is the leak-without-alloc
#     case.)
#
#   INV-CLEANUP-ALLOC: Every MIR::Cleanup or MIR::ErrCleanup has a
#     matching MIR::AllocMark. A cleanup with no alloc is a compiler bug.
#
#   INV-ALLOCATOR-MATCH: The allocator in AllocMark (:heap/:frame) must
#     match the allocator in the cleanup_entry of the corresponding
#     Cleanup/ErrCleanup. Mismatch = freeing heap memory with the frame
#     allocator or vice versa -> runtime crash.
#
#   INV-HPT-LEAK: A heap-returning call result used in statement position
#     (not bound to a variable) is an unconditional leak.
#
#   INV-INLINE-CONTRACT: InlineZig/RawZig nodes that call CheatLib.*
#     functions with ownership effects must declare stdlib_def so the
#     checker can see those effects. Without it, the node is opaque.
#
#   INV-INLINE-ALLOC-MATCH: When an InlineZig operation uses an allocator
#     (:alloc/:key_alloc/:val_alloc), that allocator must match the
#     container binding's AllocMark allocator. Frame data stored in a
#     heap container becomes a dangling pointer after frame rewind.
#
#   INV-FRAME-REWIND: Every loop body that frame-allocates must contain
#     a restoreLoopMark defer to prevent unbounded frame arena growth.
#
#   INV-COPY-CLEANUP: A Cleanup paired with an AllocMark whose type_info is
#     a primitive or Id<T> (with no sync/rc capability) is a compiler bug:
#     value types that never own heap memory must not receive cleanup nodes.
#
#   INV-CROSS-FRAME-PARAM-ALLOC: When an InlineZig op targets a parameter
#     that was pointer-passed into this function (MUTABLE collection param
#     or any param whose Zig type is `*T`), its resolved allocator must
#     NOT be `:frame`. Frame allocations are bounded by THIS function's
#     mark/restore; the parameter's lifetime extends past that mark, so
#     a frame alloc for it produces a buffer that dies before its owner.
#     Cross-frame UAF — caught here even if mir_lowering's allocator-
#     routing in `resolve_alloc_sym` regresses. Defense in depth on top
#     of escape_analysis.rb's Condition 9 promotion. See test 380.
#
# THE MOMENT this checker adds logic outside these invariants, it is no
# longer a gatekeeper -- it is ad-hoc patch code that gives false confidence.
# Every new check must be justified by one of these invariants.
#
# Structural encoding (no flag inspection):
#   MIR::Cleanup    -> always-defer cleanup (freed on both success and error)
#   MIR::ErrCleanup -> errdefer-only cleanup (freed only on error; success
#                      path transfers ownership to caller/container/callee)
#   MIR::TransferMark -> no local cleanup because ownership was moved out of
#                        this scope on every successful path. Must pair with
#                        a matching AllocMark.
#
# Which type is emitted is determined by the lowering pass, not the checker.
# The checker does NOT inspect flags or tags -- it reads the node type.
#
# Other ownership checks run pre-lowering:
#   UseAfterMoveChecker  -- use-after-move (Rule 1)
#   BorrowChecker        -- MOVE_WHILE_BORROWED, ALIAS_VIOLATION

require "sorbet-runtime"

require_relative "../ast/type"
require_relative "../ast/diagnostic_registry"

class MIRChecker
    extend T::Sig

  attr_reader :errors

  sig { params(fn_name: T.untyped).void }
  def initialize(fn_name: nil)
    @fn_name = fn_name
    @errors = T.let([], T::Array[T.untyped])
  end

  # strict: true enables the UNHOISTED_ALLOC check.
  # Disabled by default until Phase 1-3 hoisting is complete -- enabling it
  # on the current codebase would flag every string return, @indirect field,
  # and list literal that hasn't been hoisted yet.  Each phase task fixes a
  # category and re-enables the check for that category.  Once all violations
  # are resolved this parameter will be removed and the check always runs.
  sig { params(fn_def: MIR::FnDef, strict: T::Boolean).returns(T::Array[String]) }
  def check_fn!(fn_def, strict: false)
    @fn_name = fn_def.name
    @errors = []

    allocs = {}
    cleanups = {}
    transfers = Set.new
    errdefer_destroy_names = Set.new
    hpt_leaks = []
    owned_return_lets = []
    inline_alloc_nodes = []
    all_zig_nodes = []  # InlineZig + RawZig -- both scanned for CheatLib contracts

    walk_mir(fn_def.body) do |node|
      case node
      when MIR::AllocMark
        (allocs[node.name] ||= []) << node
      when MIR::Cleanup, MIR::ErrCleanup
        (cleanups[node.name] ||= []) << node
      when MIR::TransferMark
        transfers << node.name
      when MIR::ErrDeferStmt
        # @indirect field temps use ErrDeferStmt(DestroyPtr) instead of ErrCleanup.
        # Track their names so ALLOC_WITHOUT_CLEANUP does not false-positive on them.
        if node.body.is_a?(MIR::DestroyPtr) && node.body.ptr.is_a?(MIR::Ident)
          errdefer_destroy_names << node.body.ptr.name
        end
      when MIR::Let
        owned_return_lets << node if owned_return_init?(node.init)
        all_zig_nodes << node.init if node.init.is_a?(MIR::InlineZig)
      when MIR::ExprStmt
        scan_expr_for_hpt_leak!(node.expr, hpt_leaks)
        if node.expr.is_a?(MIR::InlineZig) && node.expr.allocs
          inline_alloc_nodes << node.expr
        end
        all_zig_nodes << node.expr if node.expr.is_a?(MIR::InlineZig)
      when MIR::InlineZig
        if node.allocs && !inline_alloc_nodes.include?(node)
          inline_alloc_nodes << node
        end
        all_zig_nodes << node unless all_zig_nodes.include?(node)
      when MIR::RawZig
        all_zig_nodes << node unless all_zig_nodes.include?(node)
      when MIR::LambdaExpr
        if node.fn_def
          sub = MIRChecker.new
          @errors.concat(sub.check_fn!(node.fn_def, strict: strict))
        end
      end
    end

    hpt_leaks.each { |e| @errors << e }
    verify_owned_return_alloc_marks!(owned_return_lets, allocs)
    verify_inline_alloc_contracts!(inline_alloc_nodes, allocs)
    verify_cross_frame_param_alloc!(inline_alloc_nodes, fn_def)
    verify_alloc_cleanup_match!(allocs, cleanups, errdefer_destroy_names, transfers)
    verify_zig_contracts!(all_zig_nodes)
    verify_raw_justified!(all_zig_nodes)
    verify_frame_rewind!(fn_def.body)
    verify_unhoisted_allocs!(fn_def.body) if strict

    @errors
  end

  sig { params(program: MIR::Program, strict: T::Boolean).returns(T::Array[String]) }
  def check_program!(program, strict: false)
    all_errors = []
    program.items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      all_errors.concat(check_fn!(item, strict: strict))
    end
    all_errors
  end

  sig { params(init: T.untyped).returns(T::Boolean) }
  def owned_return_init?(init)
    return true if init.is_a?(MIR::Call) && init.heap_provenance
    return true if init.is_a?(MIR::TryCatch) && init.heap_provenance
    if init.is_a?(MIR::InlineZig) || init.is_a?(MIR::RawZig)
      return false unless stdlib_owned_return?(init)
      # Receiver-dependent (Proc-resolved) returns -- collection
      # intrinsics like pool.insert/get -- are not a static owned-
      # return declaration; their ownership is governed by
      # allocates/borrows, handled elsewhere. Only a static return
      # type counts here (matches pre-FS behavior, which read only
      # the static `:return` key).
      return false unless init.stdlib_def.fixed_return?
      ret = init.stdlib_def.return_type
      return !ret.void?
    end
    false
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def stdlib_owned_return?(node)
    return false unless node.stdlib_def&.emit&.allocates
    return true if node.stdlib_def.emit&.return_alloc == :heap
    return false unless node.is_a?(MIR::InlineZig)

    allocs = node.allocs
    !!(allocs.is_a?(Hash) && allocs.values.any? { |v| v == :heap })
  end

  sig { params(lets: T::Array[MIR::Let], allocs: T::Hash[String, T::Array[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_owned_return_alloc_marks!(lets, allocs)
    lets.each do |let|
      marks = allocs[let.name]
      unless marks
        @errors << error(:OWNED_RETURN_WITHOUT_ALLOC, let.name,
          "owned-return initializer is bound without MIR::AllocMark; cleanup cannot be verified")
        next
      end

      if marks.any? { |m| m.alloc == :frame }
        @errors << error(:OWNED_RETURN_ALLOC_NOT_HEAP, let.name,
          "owned-return initializer is heap-provenance but MIR::AllocMark uses :frame")
      end
    end
  end

  # ===================================================================
  # FSM structural validation
  # ===================================================================
  #
  # Verifies the cleanup-placement decisions baked into a stackless
  # FSM body before its rendered Zig text reaches the emitter. The
  # FSM lowering produces a `MIR::FsmStructure` alongside the Zig
  # text; this method runs over the structure and raises on any
  # violation of the FSM-specific invariants below. Called from
  # `mir_lowering.rb` immediately after `emit_fsm_io_bg_code` returns,
  # so a violation aborts the whole compile rather than producing
  # silently-incorrect Zig output.
  #
  # INV-FSM-CAPTURE-FINALIZE
  #   Every entry in `structure.captures` must have
  #   `cleanup_at == :finalize`. Captures (heap-dupe'd into the FSM
  #   ctx at spawn) may be read by ANY step; placing their `defer
  #   free()` inside an earlier step fires the cleanup before later
  #   steps run, leaving freed pointers in ctx fields. This is
  #   exactly the UAF that shipped in the readFile/writeFile commit.
  #
  # INV-FSM-CAPTURE-CLEANUP-PRESENT
  #   Every capture must appear in `structure.finalize_cleanups`. A
  #   capture with NO cleanup leaks the heap-dupe.
  #
  # INV-FSM-STEP-READS-LIVE
  #   For each step S and each name read in S, the name must either
  #   (a) be in `finalize_cleanups` (lives until FSM end), or
  #   (b) have its cleanup in a step >= S (still alive when S reads).
  #   A name read in step S whose cleanup lives in step T < S is a
  #   cross-step UAF.
  #
  # INV-FSM-RESULT-NO-FINALIZED-ALIAS
  #   The BG body's terminal result expression must not alias a
  #   state field that is freed at FSM finalize. Aliasing happens
  #   when (a) bind_line declares a local whose RHS references a
  #   finalized field, AND (b) post_result_line assigns that local
  #   directly into inner.result. The slice escapes the FSM but its
  #   backing memory dies when the finalize defer fires — the
  #   consumer reads a dangling pointer. Detected by the lowering
  #   (see emit_fsm_io_bg_code) and recorded as
  #   `structure.result_aliases_finalized`.
  #
  # Raises FsmStructureError on the first violation, with a message
  # naming the binding and the bad step index. Future invariants get
  # added here, NOT in the rendering code.
  class FsmStructureError < StandardError; end

  sig { params(structure: T.nilable(MIR::FsmStructure), source: T.untyped).returns(NilClass) }
  def self.check_fsm_structure!(structure, source: nil)
    return unless structure
    captures = structure.captures || []
    finalize_cleanups = structure.finalize_cleanups || []
    steps = structure.steps || []

    # INV-FSM-CAPTURE-FINALIZE
    captures.each do |cap|
      unless cap[:cleanup_at] == :finalize
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-CAPTURE-FINALIZE",
          "capture '#{cap[:name]}' has cleanup_at=#{cap[:cleanup_at].inspect}; " \
          "captures may be read by any step and MUST cleanup at FSM finalize. " \
          "Cleanup placed in an earlier step fires before later steps run -> UAF.",
          source,
        )
      end
    end

    # INV-FSM-CAPTURE-CLEANUP-PRESENT
    captures.each do |cap|
      unless finalize_cleanups.include?(cap[:name])
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-CAPTURE-CLEANUP-PRESENT",
          "capture '#{cap[:name]}' has no entry in finalize_cleanups; " \
          "the heap-dupe at spawn would leak.",
          source,
        )
      end
    end

    # INV-FSM-STEP-READS-LIVE
    cleanup_step_index = {}
    steps.each do |step|
      (step[:cleanups] || []).each { |name| cleanup_step_index[name] = step[:index] }
    end
    steps.each do |step|
      (step[:reads] || []).each do |name|
        next if finalize_cleanups.include?(name)  # lives until end
        cleanup_step = cleanup_step_index[name]
        next if cleanup_step.nil?                  # no cleanup recorded -> separate invariant
        next if cleanup_step >= step[:index]
        raise FsmStructureError, format_fsm_error(
          "INV-FSM-STEP-READS-LIVE",
          "step #{step[:index]} reads '#{name}' but its cleanup was placed in " \
          "step #{cleanup_step} (earlier). The defer fires before step #{step[:index]} " \
          "runs -> cross-step UAF.",
          source,
        )
      end
    end

    # INV-FSM-RESULT-NO-FINALIZED-ALIAS
    if structure.respond_to?(:result_aliases_finalized) && structure.result_aliases_finalized
      aliased = structure.result_aliases_finalized
      raise FsmStructureError, format_fsm_error(
        "INV-FSM-RESULT-NO-FINALIZED-ALIAS",
        "BG body's terminal expression aliases finalized state field '#{aliased}' " \
        "via the bound local. The slice would escape the FSM via inner.result, but " \
        "its backing memory is freed when the finalize defer fires at end of last " \
        "step -> consumer reads a dangling pointer. Either compute a fresh value " \
        "from the bound local before returning (e.g. wrap in a function call that " \
        "returns a value type), or drop the FSM templates for this stdlib so the " \
        "stackful escape-promotion path handles ownership.",
        source,
      )
    end

    nil
  end

  sig { params(invariant: String, message: String, source: NilClass).returns(String) }
  def self.format_fsm_error(invariant, message, source)
    loc = source&.line ? " at line #{source.line}" : ""
    "[FSM checker]#{loc} #{invariant}: #{message}"
  end

  private

  # Tree walker -- yields every node in the MIR tree.
  sig { params(stmts: T.nilable(T::Array[T.untyped]), block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def walk_mir(stmts, &block)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_mir_node(s, &block) }
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def walk_mir_node(node, &block)
    return unless node
    yield node

    case node
    when MIR::FnDef       then walk_mir(node.body, &block)
    when MIR::IfStmt
      walk_mir(node.then_body, &block)
      walk_mir(node.else_body, &block)
    when MIR::IfBindStmt
      walk_mir(node.then_body, &block)
      walk_mir(node.else_body, &block)
    when MIR::WhileStmt, MIR::ForStmt
      walk_mir(node.body, &block)
    when MIR::ScopeBlock, MIR::BlockExpr
      walk_mir(node.body, &block)
    when MIR::SwitchStmt
      node.arms&.each { |a| walk_mir(a[:body], &block) }
      walk_mir(node.default_body, &block)
    when MIR::IfChain
      node.branches&.each { |b| walk_mir(b[:body], &block) }
      walk_mir(node.default_body, &block)
    when MIR::DeferStmt   then walk_mir_node(node.body, &block) if node.body
    when MIR::ErrDeferStmt then walk_mir_node(node.body, &block) if node.body
    when MIR::BatchWindowPush
      walk_mir_node(node.item_expr, &block)
      walk_mir_node(node.value_expr, &block)
    when MIR::BatchWindowFlush
      walk_mir_node(node.value_expr, &block)
    when MIR::Let          then yield node.init, {} if node.init.is_a?(MIR::LambdaExpr)
    when MIR::BgBlock      then walk_mir(node.run_body, &block)
    when MIR::DoBlock      then node.branch_bodies&.each { |b| walk_mir(b, &block) }
    when MIR::CatchWrapper then node.clause_bodies&.each { |b| walk_mir(b, &block) }
    when MIR::Pipeline     then walk_mir_node(node.inner, &block)
    when MIR::SnapshotRead         then walk_mir(node.body, &block)
    when MIR::SnapshotTransaction  then walk_mir(node.body, &block)
    when MIR::SnapshotMultiTxn     then walk_mir(node.body, &block)
    when MIR::WithMatchDispatch    then node.arms&.each { |a| walk_mir(a[:body], &block) }
    end
  end

  # HPT_LEAK: heap-returning call result discarded.
  sig { params(node: T.untyped, leaks: T::Array[String]).returns(T.nilable(T::Array[T.untyped])) }
  def scan_expr_for_hpt_leak!(node, leaks)
    return unless node
    if node.is_a?(MIR::Call) && node.heap_provenance
      leaks << error(:HPT_LEAK, node.callee,
        "heap-returning call result not bound to variable (leak)")
    end
    if node.is_a?(MIR::TryCatch) && node.heap_provenance
      leaks << error(:HPT_LEAK, "try-catch",
        "heap-returning try/catch result not bound to variable (leak)")
    end
    if (node.is_a?(MIR::InlineZig) || node.is_a?(MIR::RawZig)) && stdlib_owned_return?(node) &&
       node.stdlib_def.fixed_return?
      ret = node.stdlib_def.return_type
      unless ret.void?
        label = node.is_a?(MIR::RawZig) ? "RawZig block" : "stdlib call"
        leaks << error(:HPT_LEAK, node.reason,
          "#{label} with allocates:true result not bound to variable (leak)")
      end
    end
    if node.is_a?(MIR::Call) && node.args
      node.args.each { |a| scan_expr_for_hpt_leak!(a, leaks) }
    end
  end

  # INLINE_ALLOC_MISMATCH: InlineZig operation allocator must match container.
  #
  # Checks ALL allocator params (:alloc, :key_alloc, :val_alloc) against the
  # container's AllocMark. A frame-allocated key/value stored in a heap
  # container becomes a dangling pointer after frame rewind.
  sig { params(inline_nodes: T::Array[T.untyped], allocs: T::Hash[String, T::Array[T.untyped]]).returns(T::Array[T.untyped]) }
  def verify_inline_alloc_contracts!(inline_nodes, allocs)
    inline_nodes.each do |iz|
      next unless iz.allocs
      target = iz.target_var
      next unless target && allocs.key?(target)

      container_alloc = T.must(allocs[target]).first.alloc

      # Check primary allocator
      if iz.allocs.key?(:alloc)
        op_alloc = iz.allocs[:alloc]
        if op_alloc != container_alloc
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "operation uses :#{op_alloc} but container '#{target}' is :#{container_alloc}")
        end
      end

      # Check key/value allocators: frame-allocated stored data in a heap
      # container = use-after-free when the frame rewinds.
      [:key_alloc, :val_alloc].each do |alloc_key|
        next unless iz.allocs.key?(alloc_key)
        stored_alloc = iz.allocs[alloc_key]
        if stored_alloc == :frame && container_alloc == :heap
          @errors << error(:INLINE_ALLOC_MISMATCH, target,
            "#{alloc_key} is :frame but container '#{target}' is :heap " \
            "(stored data will dangle after frame rewind)")
        end
      end
    end
  end

  # CROSS_FRAME_PARAM_ALLOC: an InlineZig op targeting a pointer-passed
  # parameter must not use the `:frame` allocator. Pointer-passed params
  # (MUTABLE collection / `*T` Zig type) carry a lifetime that extends
  # past the current function's mark/restore -- a frame allocation here
  # would die before the binding it serves, producing a cross-frame UAF.
  #
  # Independently re-derives "is this param pointer-passed?" from the
  # MIR-level Zig type (prefix `*`) so the check is decoupled from
  # mir_lowering's `@current_fn_collection_params` set. Defense in depth:
  # if lowering's `resolve_alloc_sym` or escape_analysis's Condition 9
  # ever regresses, this catches the resulting bad MIR before codegen.
  sig { params(inline_nodes: T::Array[T.untyped], fn_def: MIR::FnDef).returns(T.nilable(T::Array[T.untyped])) }
  def verify_cross_frame_param_alloc!(inline_nodes, fn_def)
    return if fn_def.params.nil? || fn_def.params.empty?

    # `pointer_passed` flag is set on MIR::Param at lowering time. Collection
    # params lower to `anytype` (polymorphic) so we can't read pointer-pass
    # status from the Zig type string alone — the lowering tags it explicitly.
    pointer_passed = fn_def.params.each_with_object(Set.new) do |p, set|
      set << p.name.to_s if p.respond_to?(:pointer_passed) && p.pointer_passed
    end
    return if pointer_passed.empty?

    inline_nodes.each do |iz|
      next unless iz.allocs
      target = iz.target_var.to_s
      next unless pointer_passed.include?(target)

      iz.allocs.each do |alloc_key, alloc_sym|
        next unless alloc_sym == :frame
        @errors << error(:CROSS_FRAME_PARAM_ALLOC, target,
          "operation #{alloc_key} is :frame but '#{target}' is a pointer-passed " \
          "parameter (lifetime extends past this function's frame mark; " \
          "buffer would dangle on return). Use :heap.")
      end
    end
  end

  # ALLOC_CLEANUP_MISMATCH: allocator at AllocMark must match allocator in Cleanup.
  #
  # Every binding has a single allocator for its entire lifetime (INV-1). If the
  # allocator used to create a value (:heap/:frame on AllocMark) differs from the
  # allocator used to free it (:alloc in cleanup_entry), the generated Zig will
  # call heapAlloc().free() on frame memory or vice versa -> runtime crash.
  #
  # Only checks bindings that have BOTH an AllocMark and a Cleanup. Bindings with
  # only a Cleanup indicate a missing AllocMark -- every locally-allocated binding
  # (including TAKES params via insert_takes_drops! and heap carry vars via
  # insert_drop!) must have a corresponding AllocMark. A Cleanup with no AllocMark
  # is a compiler bug: the allocation event is invisible to the checker, so
  # ALLOC_CLEANUP_MISMATCH cannot fire even if the allocators diverge.
  sig { params(allocs: T::Hash[String, T::Array[T.untyped]], cleanups: T::Hash[String, T::Array[T.untyped]], errdefer_destroy_names: T::Set[T.untyped], transfers: T::Set[T.untyped]).returns(T::Hash[String, T::Array[T.untyped]]) }
  def verify_alloc_cleanup_match!(allocs, cleanups, errdefer_destroy_names = Set.new, transfers = Set.new)
    allocs.each do |name, alloc_marks|
      next unless cleanups.key?(name)

      alloc_sym   = alloc_marks.first.alloc
      cleanup_sym = T.must(cleanups[name]).first.cleanup_entry[:alloc]

      if alloc_sym != cleanup_sym
        @errors << error(:ALLOC_CLEANUP_MISMATCH, name,
          "allocated with :#{alloc_sym} but cleanup uses :#{cleanup_sym}")
      end

      # INV-COPY-CLEANUP: primitives and Id<T> (value types that can never own
      # heap memory) must not get a Cleanup node. If they do, needs_explicit_cleanup?
      # or visit_CopyNode missed the gate.
      if (ti = alloc_marks.first.type_info)
        no_caps = !ti.any_sync? && !ti.multiowned? && !ti.shared?
        if no_caps && (ti.primitive? || (ti.generic_instance? && ti.generic_base == :Id))
          @errors << error(:COPY_CLEANUP, name,
            "cleanup emitted for value type #{ti} (primitive or Id<T>) that can never " \
            "own heap memory -- needs_explicit_cleanup? or visit_CopyNode missed the gate")
        end
      end
    end

    # CLEANUP_WITHOUT_ALLOC: every binding with a Cleanup must also have an
    # AllocMark. A missing AllocMark means the allocation event was not emitted
    # (compiler bug in MIRPass/insert_drop!/insert_takes_drops!) -- the checker
    # cannot verify allocator consistency for this binding.
    cleanups.each do |name, _cleanup_nodes|
      next if allocs.key?(name)
      @errors << error(:CLEANUP_WITHOUT_ALLOC, name,
        "MIR::Cleanup present but no MIR::AllocMark (allocation event missing from MIR)")
    end

    # TRANSFER_WITHOUT_ALLOC: a transfer marker is only meaningful if the value
    # it transfers had an allocation event. Otherwise TransferMark can mask an
    # untracked ownership path.
    transfers.each do |name|
      next if allocs.key?(name)
      @errors << error(:TRANSFER_WITHOUT_ALLOC, name,
        "MIR::TransferMark present but no MIR::AllocMark (transfer event missing allocation source)")
    end

    # ALLOC_WITHOUT_CLEANUP: every HEAP AllocMark must have a Cleanup, ErrCleanup,
    # ErrDeferStmt(DestroyPtr), or explicit TransferMark. Frame allocations are
    # freed by the arena rewind and do not require an explicit cleanup node.
    # Exception: @indirect field temps use ErrDeferStmt(DestroyPtr) (errdefer_destroy_names).
    allocs.each do |name, alloc_marks|
      next if cleanups.key?(name)
      next if errdefer_destroy_names.include?(name)
      next if transfers.include?(name)
      next if alloc_marks.all? { |m| m.alloc == :frame }
      @errors << error(:ALLOC_WITHOUT_CLEANUP, name,
        "AllocMark with no Cleanup, ErrCleanup, ErrDeferStmt(DestroyPtr), or TransferMark -- leaked allocation")
    end
  end

  # NO_CONTRACT: InlineZig/RawZig with CheatLib calls must have stdlib_def.
  #
  # CheatLib.* functions allocate, free, or transfer ownership. Without stdlib_def,
  # the checker cannot verify HPT_LEAK or INLINE_ALLOC_MISMATCH. This makes the
  # node opaque -- ownership bugs inside it are invisible.
  #
  # Exempt: CheatLib calls that are pure reads or comparisons (no ownership effect).
  CHEATLIB_EXEMPT = %w[
    CheatLib.timestampMs CheatLib.threadCount CheatLib.assert
    CheatLib.intAdd CheatLib.intSub CheatLib.intMul CheatLib.intDiv
    CheatLib.wrapAdd CheatLib.wrapMul CheatLib.wrapSub
    CheatLib.getAt CheatLib.numericMapGet CheatLib.setAt
    CheatLib.Range CheatLib.Promise CheatLib.BoundedStream
    CheatLib.len CheatLib.countOccurrences CheatLib.intToString
    CheatLib.listDir CheatLib.readFile CheatLib.eql
    CheatLib.needsCleanup
  ].freeze

  sig { params(zig_nodes: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def verify_zig_contracts!(zig_nodes)
    zig_nodes.each do |node|
      next if node.stdlib_def
      next unless node.code.is_a?(String)

      kind = node.is_a?(MIR::RawZig) ? :RAW_NO_CONTRACT : :INLINE_NO_CONTRACT

      # Find CheatLib calls in the code string
      calls = node.code.scan(/CheatLib\.\w+/)
      next if calls.empty?

      # Filter out exempt calls: type references (CheatLib.Pool, CheatLib.Locked, etc.)
      # and pure read/arithmetic functions.
      unaudited = calls.reject { |c| CHEATLIB_EXEMPT.include?(c) || c.match?(/\ACheatLib\.[A-Z]/) }
      next if unaudited.empty?

      label = node.is_a?(MIR::RawZig) ? "RawZig" : "InlineZig"
      @errors << error(kind, node.reason || label.downcase,
        "#{label} calls #{unaudited.uniq.join(', ')} without stdlib_def " \
        "(ownership effects invisible to checker)")
    end
  end

  # RAW_UNJUSTIFIED: every MIR::RawZig must carry a reason: in this whitelist.
  #
  # RawZig is an opaque escape hatch. The checker cannot see inside raw Zig
  # code, so each use must be explicitly justified. New sites added to
  # mir_lowering.rb must either (a) be decomposed into structural MIR, or
  # (b) add the reason here with a commit message explaining why the site
  # cannot be decomposed.
  RAW_JUSTIFIED_REASONS = %w[
    require_local_module_opaque
  ].freeze

  RAW_JUSTIFIED_PREFIXES = T.let([].freeze, T::Array[T.untyped])

  sig { params(zig_nodes: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def verify_raw_justified!(zig_nodes)
    zig_nodes.each do |node|
      next unless node.is_a?(MIR::RawZig)
      reason = node.reason.to_s
      next if RAW_JUSTIFIED_REASONS.include?(reason)
      next if RAW_JUSTIFIED_PREFIXES.any? { |p| reason.start_with?(p) }
      @errors << error(:RAW_UNJUSTIFIED, node.reason || "raw_zig",
        "RawZig with reason '#{node.reason}' is not in RAW_JUSTIFIED_REASONS " \
        "(add to whitelist with justification, or decompose into structural MIR)")
    end
  end

  # FRAME_NO_REWIND: every loop that frame-allocates must rewind per iteration.
  #
  # Post-lowering check: walks the MIR tree looking for loops that contain
  # frame AllocMarks or InlineZig with frame allocs but lack mark_per_iter.
  # Without per-iteration rewind, frame arena grows unboundedly across iterations.
  sig { params(body: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_frame_rewind!(body)
    return unless body.is_a?(Array)
    check_loop_rewind!(body)
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def check_loop_rewind!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::WhileStmt, MIR::ForStmt
        # Structural check: verify the actual DeferStmt(restoreLoopMark) is present,
        # not a flag. This catches lowerer bugs where mark_per_iter is set but the
        # defer was not emitted, and unifies the check with the actual MIR structure.
        unless stmt.tight || body_has_loop_restore?(stmt.body)
          if body_has_frame_alloc?(stmt.body)
            @errors << error(:FRAME_NO_REWIND, @fn_name,
              "loop body frame-allocates but has no restoreLoopMark defer")
          end
        end
        check_loop_rewind!(stmt.body)

      when MIR::IfStmt
        check_loop_rewind!(stmt.then_body)
        check_loop_rewind!(stmt.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        check_loop_rewind!(stmt.body)
      when MIR::SwitchStmt
        stmt.arms&.each { |a| check_loop_rewind!(a[:body]) }
        check_loop_rewind!(stmt.default_body)
      when MIR::IfChain
        stmt.branches&.each { |b| check_loop_rewind!(b[:body]) }
        check_loop_rewind!(stmt.default_body)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        check_loop_rewind!(stmt.body)
      when MIR::WithMatchDispatch
        stmt.arms&.each { |a| check_loop_rewind!(a[:body]) }
      end
    end
  end

  # Does this statement list contain a per-iteration loop restore?
  # Looks for DeferStmt(MethodCall("restoreLoopMark")) -- the actual structure
  # emitted by the lowerer when mark_per_iter is true.
  # Uses the same traversal rules as body_has_frame_alloc? and check_loop_rewind!:
  # recurse into branches/blocks, stop at nested loops (they have their own restore).
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T::Boolean) }
  def body_has_loop_restore?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      case s
      when MIR::DeferStmt
        s.body.is_a?(MIR::MethodCall) && s.body.method == "restoreLoopMark"
      when MIR::IfStmt
        body_has_loop_restore?(s.then_body) || body_has_loop_restore?(s.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        body_has_loop_restore?(s.body)
      when MIR::SwitchStmt
        (s.arms&.any? { |a| body_has_loop_restore?(a[:body]) }) ||
          body_has_loop_restore?(s.default_body)
      when MIR::IfChain
        (s.branches&.any? { |b| body_has_loop_restore?(b[:body]) }) ||
          body_has_loop_restore?(s.default_body)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        body_has_loop_restore?(s.body)
      when MIR::WithMatchDispatch
        s.arms&.any? { |a| body_has_loop_restore?(a[:body]) }
      # MIR::WhileStmt, MIR::ForStmt: stop -- nested loops checked independently
      else
        false
      end
    end
  end

  # Does this statement list contain frame allocations, recursing into all
  # branch/block nodes (IfStmt, SwitchStmt, IfChain, ScopeBlock, BlockExpr)
  # but stopping at nested loop and fiber/lambda boundaries.
  # Mirrors the same traversal used by check_loop_rewind! so both methods
  # see the same nodes -- no special-cased paths.
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T::Boolean) }
  def body_has_frame_alloc?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      case s
      when MIR::AllocMark
        s.alloc == :frame
      when MIR::ExprStmt
        expr_has_frame_alloc?(s.expr)
      when MIR::Let
        expr_has_frame_alloc?(s.init)
      when MIR::BatchWindowPush
        expr_has_frame_alloc?(s.item_expr) || expr_has_frame_alloc?(s.value_expr)
      when MIR::BatchWindowFlush
        expr_has_frame_alloc?(s.value_expr)
      when MIR::IfStmt
        body_has_frame_alloc?(s.then_body) || body_has_frame_alloc?(s.else_body)
      when MIR::ScopeBlock, MIR::BlockExpr
        body_has_frame_alloc?(s.body)
      when MIR::SwitchStmt
        (s.arms&.any? { |a| body_has_frame_alloc?(a[:body]) }) ||
          body_has_frame_alloc?(s.default_body)
      when MIR::IfChain
        (s.branches&.any? { |b| body_has_frame_alloc?(b[:body]) }) ||
          body_has_frame_alloc?(s.default_body)
      when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
        body_has_frame_alloc?(s.body)
      when MIR::WithMatchDispatch
        s.arms&.any? { |a| body_has_frame_alloc?(a[:body]) }
      # MIR::WhileStmt, MIR::ForStmt: stop -- nested loops are checked independently
      # MIR::BgBlock, MIR::LambdaExpr: stop -- separate fiber/function frame scopes
      else
        false
      end
    end
  end

  # Does this MIR expression node perform a frame allocation?
  # Backing-store mutations (mutates_receiver) are excluded: they extend an
  # existing container's backing store under that container's own allocator.
  # The container's outer-scope rewind handles cleanup — per-iteration rewind
  # would corrupt accumulated data. Only NEW ephemeral objects need loop marks.
  sig { params(expr: T.untyped).returns(T.nilable(T::Boolean)) }
  def expr_has_frame_alloc?(expr)
    return false unless expr
    case expr
    when MIR::InlineZig
      return false if expr.stdlib_def&.emit&.mutates_receiver
      expr.allocs&.any? { |_k, v| v == :frame }
    when MIR::DupeSlice, MIR::ConcatStr, MIR::HeapCreate, MIR::AllocSlice,
         MIR::ContainerInit, MIR::MakeList, MIR::DeepCopy, MIR::CapWrap
      expr.alloc == :frame
    when MIR::RawZig
      expr.code.is_a?(String) && expr.code.include?("frameAlloc()")
    else
      false
    end
  end

  # Format an MIR-checker error string. The on-the-wire shape is
  # preserved (`[KIND] fn::name -- msg`) so anyone reading checker
  # output keeps their muscle memory. The kind, however, MUST be
  # registered in DiagnosticRegistry — that's the unification point.
  # Adding a new MIR check now requires adding a registry entry,
  # which means `clear explain <CODE>` documents it for free.
  sig { params(kind: Symbol, name: String, msg: String).returns(String) }
  def error(kind, name, msg)
    unless DiagnosticRegistry.known?(kind)
      raise "Internal Compiler Error: unregistered MIR diagnostic code :#{kind}. " \
            "Add an entry in src/ast/diagnostic_registry.rb (category: :mir)."
    end
    "[#{kind}] #{@fn_name}::#{name} -- #{msg}"
  end

  # ================================================================
  # UNHOISTED_ALLOC -- every allocating expression must be a Let init
  # ================================================================
  #
  # INV-H: every MIR node that allocates memory must appear as the direct
  # init of a MIR::Let.  If an allocating expression appears in argument,
  # return, field-value, or any other sub-expression position it has no
  # AllocMark, so the checker cannot verify its lifetime, allocator
  # consistency, or cleanup.
  #
  # Allocating types:
  #   DupeSlice, HeapCreate, ConcatStr, AllocSlice, MakeList, CapWrap,
  #   SharePromote,
  #   DeepCopy (strategy != :passthrough), ContainerInit (alloc != nil)
  #
  # Called only when strict: true because the codebase still has open
  # violations that are fixed progressively in Phase 1-3 tasks.

  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def verify_unhoisted_allocs!(body)
    T.must(check_stmts_for_unhoisted(body))
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def check_stmts_for_unhoisted(stmts)
    return unless stmts.is_a?(Array)
    stmts.each { |s| check_stmt_for_unhoisted(s) }
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def check_stmt_for_unhoisted(node)
    return unless node
    case node
    when MIR::Let
      # init is the one allowed position for an allocating expression.
      # Recurse into sub-expressions of init (nested allocs still flagged).
      check_expr_for_unhoisted(node.init, allow_top: true)
    when MIR::Set
      check_expr_for_unhoisted(node.target, allow_top: false)
      # Set.value: the receiving variable's Cleanup covers the allocation.
      check_expr_for_unhoisted(node.value, allow_top: true)
    when MIR::ReassignWithCleanup
      # ReassignWithCleanup.value: the emitter wraps this in `const __new_x = value;`
      # inside a block, so it IS in a named binding. The variable's Cleanup covers it.
      check_expr_for_unhoisted(node.value, allow_top: true)
    when MIR::ExprStmt
      check_expr_for_unhoisted(node.expr, allow_top: false)
    when MIR::ReturnStmt
      check_expr_for_unhoisted(node.value, allow_top: false)
    when MIR::BreakStmt
      check_expr_for_unhoisted(node.value, allow_top: false)
    when MIR::IfStmt
      check_expr_for_unhoisted(node.cond, allow_top: false)
      check_stmts_for_unhoisted(node.then_body)
      check_stmts_for_unhoisted(node.else_body)
    when MIR::WhileStmt
      check_expr_for_unhoisted(node.cond, allow_top: false)
      check_stmts_for_unhoisted(node.body)
    when MIR::ForStmt
      check_expr_for_unhoisted(node.iter, allow_top: false)
      check_stmts_for_unhoisted(node.body)
    when MIR::ScopeBlock, MIR::BlockExpr
      check_stmts_for_unhoisted(node.body)
    when MIR::SwitchStmt
      check_expr_for_unhoisted(node.subject, allow_top: false)
      node.arms&.each { |a| check_stmts_for_unhoisted(a[:body]) }
      check_stmts_for_unhoisted(node.default_body)
    when MIR::IfChain
      node.branches&.each do |b|
        check_expr_for_unhoisted(b[:cond], allow_top: false)
        check_stmts_for_unhoisted(b[:body])
      end
      check_stmts_for_unhoisted(node.default_body)
    when MIR::DeferStmt    then check_stmt_for_unhoisted(node.body)
    when MIR::ErrDeferStmt then check_stmt_for_unhoisted(node.body)
    when MIR::BatchWindowPush
      check_expr_for_unhoisted(node.item_expr, allow_top: false)
      check_expr_for_unhoisted(node.value_expr, allow_top: false)
    when MIR::BatchWindowFlush
      check_expr_for_unhoisted(node.value_expr, allow_top: false)
    when MIR::SnapshotRead, MIR::SnapshotTransaction, MIR::SnapshotMultiTxn
      check_stmts_for_unhoisted(node.body)
    when MIR::WithMatchDispatch
      node.arms&.each { |a| check_stmts_for_unhoisted(a[:body]) }
    when MIR::FnDef
      check_stmts_for_unhoisted(node.body)
    end
  end

  # Check expr for allocating nodes in non-Let-init position.
  # allow_top: true  => expr itself may be an allocating node (it IS the Let.init)
  # allow_top: false => flag expr if it is an allocating node
  # In both cases, recurse into sub-expressions with allow_top: false.
  sig { params(expr: T.untyped, allow_top: T::Boolean).returns(T.nilable(T::Array[T.untyped])) }
  def check_expr_for_unhoisted(expr, allow_top:)
    return unless expr
    # Cast is a transparent wrapper (no allocation itself). Propagate allow_top so
    # an allocating expr (e.g. MakeList) inside a Cast in Let-init position is not
    # flagged. lower() wraps MakeList in Cast for element-type coercions.
    if expr.is_a?(MIR::Cast)
      check_expr_for_unhoisted(expr.expr, allow_top: allow_top)
      return
    end
    # CapWrap composes a sync/ownership layer around an inner data-shape
    # allocation. The outer CapWrap is the alloc-tracked node (AllocMark);
    # the inner ContainerInit's lifetime is owned by the wrapper. Treat
    # CapWrap.inner as if it were in Let-init position so the inner
    # ContainerInit is not flagged as unhoisted.
    if expr.is_a?(MIR::CapWrap)
      # Top-level CapWrap is also subject to the allow_top check.
      if !allow_top && allocating_expr?(expr)
        @errors << error(:UNHOISTED_ALLOC, @fn_name,
          "CapWrap in non-Let-init position (must be hoisted to a named variable)")
        return
      end
      check_expr_for_unhoisted(expr.inner, allow_top: true) if expr.inner
      return
    end
    if !allow_top && allocating_expr?(expr)
      kind = expr.class.name.split("::").last
      @errors << error(:UNHOISTED_ALLOC, @fn_name,
        "#{kind} in non-Let-init position (must be hoisted to a named variable)")
      return  # one error per site -- don't recurse into nested allocs
    end
    each_sub_expr(expr) { |sub| check_expr_for_unhoisted(sub, allow_top: false) }
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  def allocating_expr?(expr)
    # Only flag HEAP allocations. Frame allocations are managed by the frame
    # arena and do not need AllocMark/Cleanup tracking. Matching mir_allocates?.
    case expr
    when MIR::HeapCreate   then true              # always heap by definition
    when MIR::DupeSlice    then expr.alloc == :heap
    when MIR::AllocSlice   then expr.alloc == :heap
    when MIR::MakeList     then expr.alloc == :heap
    when MIR::ConcatStr    then expr.alloc == :heap
    when MIR::CapWrap      then expr.alloc == :heap
    when MIR::SharePromote then expr.alloc == :heap
    when MIR::ContainerInit then expr.alloc == :heap
    when MIR::DeepCopy
      expr.strategy != :passthrough && expr.alloc == :heap
    else
      false
    end
  end

  # Yield each immediate sub-expression of expr.
  # Stops at opaque boundaries (RawZig, InlineZig, BgBlock).
  # BlockExpr bodies are walked separately by check_stmts_for_unhoisted.
  sig { params(expr: T.anything, blk: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def each_sub_expr(expr, &blk)
    return unless expr
    case expr
    when MIR::HeapCreate    then yield expr.init    if expr.init
    when MIR::DupeSlice     then yield expr.source  if expr.source
    when MIR::AllocSlice    then yield expr.len     if expr.len
    when MIR::FreeSlice     then yield expr.slice   if expr.slice
    when MIR::DestroyPtr    then yield expr.ptr     if expr.ptr
    when MIR::DeepCopy      then yield expr.source  if expr.source
    when MIR::CapWrap       then yield expr.inner   if expr.inner
    when MIR::SharePromote  then yield expr.source  if expr.source
    when MIR::ContainerInit then yield expr.capacity if expr.capacity
    when MIR::ConcatStr     then expr.parts&.each { |p| yield p }
    when MIR::MakeList      then expr.items&.each  { |i| yield i }
    when MIR::RcRetain      then yield expr.source  if expr.source
    when MIR::Call
      expr.args&.each { |a| yield a }
    when MIR::TailCall
      expr.args&.each { |a| yield a }
    when MIR::MethodCall
      yield expr.receiver if expr.receiver
      expr.args&.each { |a| yield a }
    when MIR::FieldGet      then yield expr.object if expr.object
    when MIR::IndexGet
      yield expr.object if expr.object
      yield expr.index  if expr.index
    when MIR::BinOp
      yield expr.left  if expr.left
      yield expr.right if expr.right
    when MIR::UnaryOp        then yield expr.operand    if expr.operand
    when MIR::Cast           then yield expr.expr       if expr.expr
    when MIR::TryExpr        then yield expr.expr       if expr.expr
    when MIR::TryCatch
      yield expr.expr if expr.expr
      yield expr.catch_body if expr.catch_body.is_a?(MIR::Emittable)
    when MIR::Orelse
      yield expr.expr     if expr.expr
      yield expr.fallback if expr.fallback
    when MIR::Conditional
      yield expr.cond     if expr.cond
      yield expr.then_val if expr.then_val
      yield expr.else_val if expr.else_val
    when MIR::AddressOf      then yield expr.expr if expr.expr
    when MIR::Deref          then yield expr.expr if expr.expr
    when MIR::OptionalUnwrap then yield expr.expr if expr.expr
    when MIR::StructInit
      expr.fields&.each { |f| yield f[:value] if f[:value] }
    when MIR::ArrayInit
      expr.items&.each { |i| yield i }
    when MIR::SliceExpr
      yield expr.target   if expr.target
      yield expr.start    if expr.start
      yield expr.end_expr if expr.end_expr
    when MIR::ItemsAccess    then yield expr.expr if expr.expr
    when MIR::RangeLit
      yield expr.start   if expr.start
      yield expr.end_val if expr.end_val
    # Opaque: RawZig, InlineZig, BgBlock, CatchWrapper
    # Leaf: Lit, Ident, FnRef, RcDowngrade, WeakUpgrade, HasField
    # BlockExpr: body is statements, walked by check_stmts_for_unhoisted
    end
  end
end
