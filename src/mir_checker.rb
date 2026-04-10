# mir_checker.rb -- Post-MIRLowering ownership verification.
#
# Enforces the same invariants as Rust's ownership model:
#   1. Every heap allocation has exactly one owner (binding with cleanup).
#   2. At scope exit, cleanup all owned bindings.
#   3. Moves transfer ownership; source cleanup is suppressed via guard.
#   4. Frame-allocated values cannot escape their scope without promotion.
#
# Error codes:
#   LEAK             -- allocation without matching cleanup
#   ORPHAN           -- cleanup/move without matching allocation
#   ALLOC_MISMATCH   -- allocation and cleanup disagree on allocator
#   ESCAPE           -- value escapes via return without guarded cleanup
#   FRAME_ESCAPE     -- frame value escapes without promotion (use-after-free)
#   BG_ESCAPE        -- BG capture needs promotion but none found (use-after-free)
#   GUARD_NO_SUPPRESS -- guarded cleanup with no move/return to trigger it
#   REASSIGN_LEAK    -- reassignment without pre-cleanup of old value
#   FIELD_LEAK       -- field assignment without pre-cleanup of old value
#   HPT_LEAK         -- heap-returning call result discarded
#   FRAME_OVERFLOW   -- loop allocates from frame arena without per-iteration rewind
#   RAW_CONTRACT     -- RawZig ownership contract violation (deprecated)
#
# Design: single tree walk collects all data; simple set comparisons verify.

require_relative "type"

class MIRChecker
  attr_reader :errors

  def initialize(fn_name: nil)
    @fn_name = fn_name
    @errors = []
  end

  # Verify a single MIR::FnDef. Returns array of error strings.
  def check_fn!(fn_def)
    @fn_name = fn_def.name
    @errors = []

    # Collection bins -- populated by single tree walk.
    allocs     = {}       # name => [AllocMark]
    cleanups   = {}       # name => [Cleanup]
    promotes   = {}       # name => [EscapePromote]
    escapes    = Set.new  # var names from ReturnMark
    moves      = Set.new  # var names from MoveMark
    reassigns  = {}       # name => ReassignMark
    raw_nodes  = []       # RawZig/InlineZig with ownership_contract
    bg_blocks  = []       # BgBlock nodes
    catch_wrappers = []   # CatchWrapper nodes
    lambdas    = []       # LambdaExpr fn_defs (checked as separate scopes)

    # Inline detections -- collected during the same walk.
    reassign_targets = Set.new  # names targeted by MIR::Set
    field_leaks      = []       # MIR::Set with needs_field_cleanup
    hpt_leaks        = []       # ExprStmt with discarded heap calls
    loop_stack       = []       # tracks current loop nesting for frame overflow

    # Single pass: collect all markers and detect inline issues.
    walk_mir(fn_def.body) do |node, context|
      case node
      when MIR::AllocMark
        (allocs[node.name] ||= []) << node
        # Track frame allocs inside loops for FRAME_OVERFLOW
        if context[:in_loop] && node.alloc == :frame
          context[:in_loop][:has_frame_alloc] = true
        end
      when MIR::Cleanup
        (cleanups[node.name] ||= []) << node
      when MIR::EscapePromote
        (promotes[node.name] ||= []) << node if node.name
      when MIR::ReturnMark
        (node.escaped_vars || []).each { |v| escapes << v.to_s }
      when MIR::MoveMark
        moves << node.name.to_s
      when MIR::ReassignMark
        reassigns[node.name] = node
      when MIR::Set
        # Collect reassignment targets
        reassign_targets << node.target.name.to_s if node.target.is_a?(MIR::Ident)
        # Detect field leaks inline
        if node.needs_field_cleanup
          field_leaks << extract_field_path(node.target)
        end
      when MIR::ExprStmt
        # Detect discarded heap-returning calls inline
        scan_expr_for_hpt_leak!(node.expr, hpt_leaks)
      when MIR::RawZig, MIR::InlineZig
        contract = node.respond_to?(:ownership_contract) ? node.ownership_contract : nil
        raw_nodes << node if contract
      when MIR::BgBlock
        bg_blocks << node
      when MIR::CatchWrapper
        catch_wrappers << node
      when MIR::LambdaExpr
        lambdas << node.fn_def if node.fn_def
      end
    end

    # --- Verify ownership invariants ---

    # Rule 1: Every allocation has exactly one cleanup (and vice versa).
    verify_alloc_cleanup_pairs!(allocs, cleanups, moves)

    # Rule 2: Allocation and cleanup agree on allocator identity.
    verify_allocator_consistency!(allocs, cleanups, promotes, catch_wrappers)

    # Rule 3: Moves/returns have correct guard setup.
    verify_move_guards!(cleanups, moves, escapes, promotes, allocs)

    # Rule 4: Frame values cannot escape without promotion.
    verify_frame_safety!(escapes, allocs, cleanups, promotes, bg_blocks)

    # Rule 5: Reassignments and field assignments clean up old values.
    verify_reassign_cleanup!(allocs, reassigns, reassign_targets)
    field_leaks.each { |path| @errors << error(:FIELD_LEAK, path, "field assignment without pre-cleanup (old value leaks)") }

    # Rule 6: Heap-returning calls must be bound to a variable.
    hpt_leaks.each { |e| @errors << e }

    # Rule 7: Loops with frame allocations have per-iteration rewind.
    check_frame_overflow!(fn_def.body)

    # Deprecated: RawZig ownership contracts. Remove when RawZig is eliminated.
    verify_raw_zig_contracts!(raw_nodes, allocs, cleanups, moves)

    # Verify nested lambda scopes independently.
    lambdas.each do |lambda_fn|
      sub = MIRChecker.new
      @errors.concat(sub.check_fn!(lambda_fn))
    end

    @errors
  end

  # Verify all functions in a MIR::Program.
  def check_program!(program)
    all_errors = []
    program.items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      all_errors.concat(check_fn!(item))
    end
    all_errors
  end

  private

  # ================================================================
  # Tree walker -- single pass, yields (node, context) for every node.
  # Context tracks loop nesting for frame overflow detection.
  # ================================================================

  def walk_mir(stmts, context = {}, &block)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_mir_node(s, context, &block) }
  end

  def walk_mir_node(node, context, &block)
    return unless node
    yield node, context

    case node
    when MIR::FnDef
      walk_mir(node.body, context, &block)
    when MIR::IfStmt
      walk_mir(node.then_body, context, &block)
      walk_mir(node.else_body, context, &block)
    when MIR::WhileStmt, MIR::ForStmt
      loop_ctx = { has_frame_alloc: false, node: node }
      inner = context.merge(in_loop: loop_ctx)
      walk_mir(node.body, inner, &block)
      # After walking body, check frame overflow for this loop
      if !node.tight && !node.mark_per_iter && loop_ctx[:has_frame_alloc]
        @errors << "[FRAME_OVERFLOW] #{@fn_name} -- loop body allocates from frame arena without per-iteration rewind"
      end
    when MIR::ScopeBlock
      walk_mir(node.body, context, &block)
    when MIR::BlockExpr
      walk_mir(node.body, context, &block)
    when MIR::SwitchStmt
      node.arms&.each { |a| walk_mir(a[:body], context, &block) }
      walk_mir(node.default_body, context, &block)
    when MIR::IfChain
      node.branches&.each { |b| walk_mir(b[:body], context, &block) }
      walk_mir(node.default_body, context, &block)
    when MIR::Let
      yield node.init, context if node.init.is_a?(MIR::LambdaExpr)
    when MIR::DeferStmt
      walk_mir_node(node.body, context, &block) if node.body
    when MIR::ErrDeferStmt
      walk_mir_node(node.body, context, &block) if node.body
    end
  end

  # ================================================================
  # Verification rules
  # ================================================================

  # Rule 1: Every AllocMark has a Cleanup. Every Cleanup has an AllocMark.
  def verify_alloc_cleanup_pairs!(allocs, cleanups, moves)
    allocs.each do |name, _|
      unless cleanups.key?(name)
        @errors << error(:LEAK, name, "AllocMark without matching Cleanup (leak)")
      end
    end
    cleanups.each do |name, _|
      next if allocs.key?(name)
      @errors << error(:ORPHAN, name, "Cleanup without matching AllocMark")
    end
    moves.each do |name|
      cnodes = cleanups[name]
      next if cnodes&.any? { |c| c.cleanup_entry&.dig(:has_moved_guard) }
      next if allocs.key?(name)
      @errors << error(:ORPHAN, name, "MoveMark without matching guarded Cleanup")
    end
  end

  # Rule 2: Allocator identity is consistent across alloc/cleanup/promote/catch.
  def verify_allocator_consistency!(allocs, cleanups, promotes, catch_wrappers)
    # AllocMark vs Cleanup
    allocs.each do |name, anodes|
      cnodes = cleanups[name]
      next unless cnodes
      anodes.each do |anode|
        cnodes.each do |cnode|
          calloc = cnode.cleanup_entry&.dig(:alloc)
          next unless calloc
          if anode.alloc != calloc
            @errors << error(:ALLOC_MISMATCH, name,
              "AllocMark uses :#{anode.alloc} but Cleanup uses :#{calloc}")
            return
          end
        end
      end
    end

    # EscapePromote: frame cleanup after promote must be guarded
    promotes.each do |name, promote_nodes|
      promote_nodes.each do |promote|
        next unless [:list, :string_map, :generic].include?(promote.strategy)
        cnodes = cleanups[name]
        next unless cnodes
        cnodes.each do |cnode|
          entry = cnode.cleanup_entry || {}
          next unless entry[:alloc] == :frame
          unless entry[:has_moved_guard]
            @errors << error(:ALLOC_MISMATCH, name,
              "EscapePromote converts to heap but Cleanup uses :frame without moved guard")
          end
        end
      end
    end

    # INV-9: catch paths must not change allocator identity
    catch_wrappers.each do |cw|
      (cw.error_reassigns || []).each do |reassign|
        name = reassign[:name]
        alloc_nodes = allocs[name]
        next unless alloc_nodes
        alloc_nodes.each do |alloc_node|
          if alloc_node.alloc != reassign[:alloc]
            @errors << error(:ALLOC_MISMATCH, name,
              "catch reassigns with :#{reassign[:alloc]} but original alloc is :#{alloc_node.alloc} (INV-9)")
          end
        end
      end
    end
  end

  # Rule 3: Moved/returned values have correct guard setup.
  GUARD_EXEMPT_KINDS = Set[:takes_union, :takes_string, :takes_slice,
                           :match_as_inline_struct, :match_as_slice].freeze

  def verify_move_guards!(cleanups, moves, escapes, promotes, allocs)
    # Escaped vars must have guarded cleanup
    escapes.each do |name|
      cnodes = cleanups[name]
      next unless cnodes
      cnodes.each do |cnode|
        unless cnode.cleanup_entry&.dig(:has_moved_guard)
          @errors << error(:ESCAPE, name, "escapes via return but Cleanup lacks moved guard")
        end
      end
    end

    # Every guarded cleanup must have a MoveMark or ReturnMark to trigger it
    cleanups.each do |name, cnodes|
      cnodes.each do |cnode|
        entry = cnode.cleanup_entry || {}
        next unless entry[:has_moved_guard]
        next if GUARD_EXEMPT_KINDS.include?(entry[:kind])
        unless moves.include?(name) || escapes.include?(name)
          @errors << error(:GUARD_NO_SUPPRESS, name,
            "Cleanup has moved guard but no MoveMark or ReturnMark escape")
        end
      end
    end
  end

  # Rule 4: Frame-allocated values cannot escape their scope.
  def verify_frame_safety!(escapes, allocs, cleanups, promotes, bg_blocks)
    # Frame bindings that escape via return need EscapePromote
    escapes.each do |name|
      anodes = allocs[name]
      next unless anodes&.any? { |a| a.alloc == :frame }
      next if promotes.key?(name)
      @errors << error(:FRAME_ESCAPE, name,
        "frame-allocated binding escapes via return without promotion (UAF)")
    end

    # BG blocks capturing frame variables need EscapePromote
    bg_blocks.each do |bg|
      (bg.captures || {}).each do |name, type_obj|
        t = type_obj ? Type.new(type_obj) : nil
        next unless t && t.needs_escape_promotion? && !t.needs_pointer_passing?
        name_s = name.to_s
        unless promotes.key?(name_s) || promotes.key?(name.to_sym)
          @errors << error(:BG_ESCAPE, name_s,
            "BG capture needs escape promotion but no EscapePromote found (use-after-free)")
        end
      end
    end
  end

  # Rule 5: Reassignment of owned bindings must pre-cleanup old value.
  def verify_reassign_cleanup!(allocs, reassigns, reassign_targets)
    reassign_targets.each do |name|
      next unless allocs.key?(name)
      unless reassigns.key?(name)
        @errors << error(:REASSIGN_LEAK, name,
          "reassignment without pre-cleanup (old value leaks)")
      end
    end
  end

  # FRAME_OVERFLOW: loops with frame allocations need per-iteration rewind.
  # This is detected inline during the walk (via loop context tracking).
  # This method handles recursive checking into nested control flow that
  # contains loops -- the walk already handles the top-level detection.
  def check_frame_overflow!(stmts)
    # Frame overflow is now detected during the single walk pass.
    # This method is a no-op kept for structural clarity.
  end

  # Deprecated: RawZig ownership contract verification.
  # To be removed when all RawZig nodes are eliminated from the pipeline.
  def verify_raw_zig_contracts!(raw_nodes, allocs, cleanups, moves)
    raw_nodes.each do |node|
      contract = node.ownership_contract
      next unless contract

      (contract[:consumes] || []).each do |name|
        unless moves.include?(name)
          @errors << error(:RAW_CONTRACT, name,
            "RawZig(#{node.reason}) consumes '#{name}' but no MoveMark found")
        end
      end

      (contract[:produces] || []).each do |name|
        unless allocs.key?(name)
          @errors << error(:RAW_CONTRACT, name,
            "RawZig(#{node.reason}) produces '#{name}' but no AllocMark found")
        end
        unless cleanups.key?(name)
          @errors << error(:RAW_CONTRACT, name,
            "RawZig(#{node.reason}) produces '#{name}' but no Cleanup found")
        end
      end
    end
  end

  # ================================================================
  # Helpers
  # ================================================================

  def extract_field_path(node)
    case node
    when MIR::FieldGet then "#{extract_field_path(node.object)}.#{node.field}"
    when MIR::Ident    then node.name.to_s
    else "?"
    end
  end

  def scan_expr_for_hpt_leak!(node, leaks)
    return unless node
    if node.is_a?(MIR::Call) && node.heap_provenance
      leaks << error(:HPT_LEAK, node.callee,
        "heap-returning call result not bound to variable (leak)")
    end
    if node.is_a?(MIR::InlineZig) && node.stdlib_def&.dig(:allocates)
      ret = node.stdlib_def[:return]
      unless ret == :Void || ret.nil?
        leaks << error(:HPT_LEAK, node.reason,
          "stdlib call with allocates:true result not bound to variable (leak)")
      end
    end
    if node.is_a?(MIR::Call) && node.args
      node.args.each { |a| scan_expr_for_hpt_leak!(a, leaks) }
    end
  end

  def error(kind, name, msg)
    "[#{kind}] #{@fn_name}::#{name} -- #{msg}"
  end
end
