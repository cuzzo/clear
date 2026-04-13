# mir_checker.rb -- Post-lowering MIR verification.
#
# THE INVARIANTS THIS CHECKER ENFORCES (and nothing else):
#
#   INV-ALLOC-CLEANUP: Every MIR::AllocMark has at least one matching
#     MIR::Cleanup or MIR::ErrCleanup for the same binding name, and
#     the allocators match. (HPT_LEAK is the leak-without-alloc case.)
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
# THE MOMENT this checker adds logic outside these invariants, it is no
# longer a gatekeeper -- it is ad-hoc patch code that gives false confidence.
# Every new check must be justified by one of these invariants.
#
# Structural encoding (no flag inspection):
#   MIR::Cleanup    -> always-defer cleanup (freed on both success and error)
#   MIR::ErrCleanup -> errdefer-only cleanup (freed only on error; success
#                      path transfers ownership to caller/container/callee)
#
# Which type is emitted is determined by the lowering pass, not the checker.
# The checker does NOT inspect flags or tags -- it reads the node type.
#
# All other ownership checks run pre-lowering:
#   FlowChecker          -- LEAK, ORPHAN_DROP, ORPHAN_GUARD, FRAME_OVERFLOW
#   UseAfterMoveChecker  -- use-after-move (Rule 1)
#   BorrowChecker        -- MOVE_WHILE_BORROWED, ALIAS_VIOLATION

require_relative "type"

class MIRChecker
  attr_reader :errors

  def initialize(fn_name: nil)
    @fn_name = fn_name
    @errors = []
  end

  # strict: true enables the UNHOISTED_ALLOC check.
  # Disabled by default until Phase 1-3 hoisting is complete -- enabling it
  # on the current codebase would flag every string return, @indirect field,
  # and list literal that hasn't been hoisted yet.  Each phase task fixes a
  # category and re-enables the check for that category.  Once all violations
  # are resolved this parameter will be removed and the check always runs.
  def check_fn!(fn_def, strict: false)
    @fn_name = fn_def.name
    @errors = []

    allocs = {}
    cleanups = {}
    hpt_leaks = []
    inline_alloc_nodes = []
    all_zig_nodes = []  # InlineZig + RawZig -- both scanned for CheatLib contracts

    walk_mir(fn_def.body) do |node|
      case node
      when MIR::AllocMark
        (allocs[node.name] ||= []) << node
      when MIR::Cleanup, MIR::ErrCleanup
        (cleanups[node.name] ||= []) << node
      when MIR::Let
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
    verify_inline_alloc_contracts!(inline_alloc_nodes, allocs)
    verify_alloc_cleanup_match!(allocs, cleanups)
    verify_zig_contracts!(all_zig_nodes)
    verify_frame_rewind!(fn_def.body)
    verify_unhoisted_allocs!(fn_def.body) if strict

    @errors
  end

  def check_program!(program)
    all_errors = []
    program.items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      all_errors.concat(check_fn!(item))
    end
    all_errors
  end

  private

  # Tree walker -- yields every node in the MIR tree.
  def walk_mir(stmts, &block)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_mir_node(s, &block) }
  end

  def walk_mir_node(node, &block)
    return unless node
    yield node

    case node
    when MIR::FnDef       then walk_mir(node.body, &block)
    when MIR::IfStmt
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
    when MIR::Let          then yield node.init, {} if node.init.is_a?(MIR::LambdaExpr)
    when MIR::BgBlock      then walk_mir(node.run_body, &block)
    when MIR::DoBlock      then node.branch_bodies&.each { |b| walk_mir(b, &block) }
    when MIR::CatchWrapper then node.clause_bodies&.each { |b| walk_mir(b, &block) }
    when MIR::Pipeline     then walk_mir_node(node.inner, &block)
    end
  end

  # HPT_LEAK: heap-returning call result discarded.
  def scan_expr_for_hpt_leak!(node, leaks)
    return unless node
    if node.is_a?(MIR::Call) && node.heap_provenance
      leaks << error(:HPT_LEAK, node.callee,
        "heap-returning call result not bound to variable (leak)")
    end
    if (node.is_a?(MIR::InlineZig) || node.is_a?(MIR::RawZig)) && node.stdlib_def&.dig(:allocates)
      ret = node.stdlib_def[:return]
      unless ret == :Void || ret.nil?
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
  def verify_inline_alloc_contracts!(inline_nodes, allocs)
    inline_nodes.each do |iz|
      next unless iz.allocs
      target = iz.target_var
      next unless target && allocs.key?(target)

      container_alloc = allocs[target].first.alloc

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

  # ALLOC_CLEANUP_MISMATCH: allocator at AllocMark must match allocator in Cleanup.
  #
  # Every binding has a single allocator for its entire lifetime (INV-1). If the
  # allocator used to create a value (:heap/:frame on AllocMark) differs from the
  # allocator used to free it (:alloc in cleanup_entry), the generated Zig will
  # call heapAlloc().free() on frame memory or vice versa -> runtime crash.
  #
  # Only checks bindings that have BOTH an AllocMark and a Cleanup. Bindings with
  # only an AllocMark were moved/escaped (no local free needed). Bindings with only
  # a Cleanup indicate a missing AllocMark -- every locally-allocated binding
  # (including TAKES params via insert_takes_drops! and heap carry vars via
  # insert_drop!) must have a corresponding AllocMark. A Cleanup with no AllocMark
  # is a compiler bug: the allocation event is invisible to the checker, so
  # ALLOC_CLEANUP_MISMATCH cannot fire even if the allocators diverge.
  def verify_alloc_cleanup_match!(allocs, cleanups)
    allocs.each do |name, alloc_marks|
      next unless cleanups.key?(name)

      alloc_sym   = alloc_marks.first.alloc
      cleanup_sym = cleanups[name].first.cleanup_entry[:alloc]

      if alloc_sym != cleanup_sym
        @errors << error(:ALLOC_CLEANUP_MISMATCH, name,
          "allocated with :#{alloc_sym} but cleanup uses :#{cleanup_sym}")
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

  # FRAME_NO_REWIND: every loop that frame-allocates must rewind per iteration.
  #
  # Post-lowering check: walks the MIR tree looking for loops that contain
  # frame AllocMarks or InlineZig with frame allocs but lack mark_per_iter.
  # Without per-iteration rewind, frame arena grows unboundedly across iterations.
  def verify_frame_rewind!(body)
    return unless body.is_a?(Array)
    check_loop_rewind!(body)
  end

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
      end
    end
  end

  # Does this statement list contain a per-iteration loop restore?
  # Looks for DeferStmt(MethodCall("restoreLoopMark")) -- the actual structure
  # emitted by the lowerer when mark_per_iter is true.
  # Uses the same traversal rules as body_has_frame_alloc? and check_loop_rewind!:
  # recurse into branches/blocks, stop at nested loops (they have their own restore).
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
  def expr_has_frame_alloc?(expr)
    return false unless expr
    case expr
    when MIR::InlineZig
      return false if expr.stdlib_def&.dig(:mutates_receiver)
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

  def error(kind, name, msg)
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
  #   DeepCopy (strategy != :passthrough), ContainerInit (alloc != nil)
  #
  # Called only when strict: true because the codebase still has open
  # violations that are fixed progressively in Phase 1-3 tasks.

  def verify_unhoisted_allocs!(body)
    check_stmts_for_unhoisted(body)
  end

  def check_stmts_for_unhoisted(stmts)
    return unless stmts.is_a?(Array)
    stmts.each { |s| check_stmt_for_unhoisted(s) }
  end

  def check_stmt_for_unhoisted(node)
    return unless node
    case node
    when MIR::Let
      # init is the one allowed position for an allocating expression.
      # Recurse into sub-expressions of init (nested allocs still flagged).
      check_expr_for_unhoisted(node.init, allow_top: true)
    when MIR::Set
      check_expr_for_unhoisted(node.target, allow_top: false)
      check_expr_for_unhoisted(node.value, allow_top: false)
    when MIR::ReassignWithCleanup
      check_expr_for_unhoisted(node.value, allow_top: false)
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
    when MIR::FnDef
      check_stmts_for_unhoisted(node.body)
    end
  end

  # Check expr for allocating nodes in non-Let-init position.
  # allow_top: true  => expr itself may be an allocating node (it IS the Let.init)
  # allow_top: false => flag expr if it is an allocating node
  # In both cases, recurse into sub-expressions with allow_top: false.
  def check_expr_for_unhoisted(expr, allow_top:)
    return unless expr
    if !allow_top && allocating_expr?(expr)
      kind = expr.class.name.split("::").last
      @errors << error(:UNHOISTED_ALLOC, @fn_name,
        "#{kind} in non-Let-init position (must be hoisted to a named variable)")
      return  # one error per site -- don't recurse into nested allocs
    end
    each_sub_expr(expr) { |sub| check_expr_for_unhoisted(sub, allow_top: false) }
  end

  def allocating_expr?(expr)
    case expr
    when MIR::DupeSlice, MIR::HeapCreate, MIR::ConcatStr,
         MIR::AllocSlice, MIR::MakeList, MIR::CapWrap
      true
    when MIR::ContainerInit
      !expr.alloc.nil?
    when MIR::DeepCopy
      expr.strategy != :passthrough
    else
      false
    end
  end

  # Yield each immediate sub-expression of expr.
  # Stops at opaque boundaries (RawZig, InlineZig, BgBlock).
  # BlockExpr bodies are walked separately by check_stmts_for_unhoisted.
  def each_sub_expr(expr)
    return unless expr
    case expr
    when MIR::HeapCreate    then yield expr.init    if expr.init
    when MIR::DupeSlice     then yield expr.source  if expr.source
    when MIR::AllocSlice    then yield expr.len     if expr.len
    when MIR::FreeSlice     then yield expr.slice   if expr.slice
    when MIR::DestroyPtr    then yield expr.ptr     if expr.ptr
    when MIR::DeepCopy      then yield expr.source  if expr.source
    when MIR::CapWrap       then yield expr.inner   if expr.inner
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
