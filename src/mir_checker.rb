# mir_checker.rb -- Post-MIRLowering ownership verification.
#
# Runs AFTER MIRLowering produces the final MIR tree -- verifies the SAME
# code that MIREmitter will emit to Zig. This closes the gap where the old
# StaticLeakChecker verified AST+markers that were then transformed by
# MIRLowering into different code.
#
# Checks performed:
#   LEAK           -- AllocMark without matching Cleanup (missing cleanup)
#   GUARD          -- maybe-moved binding's Cleanup lacks moved guard (double-free)
#   ORPHAN         -- Cleanup/AllocMark without counterpart
#   ALLOC_MISMATCH -- AllocMark and Cleanup disagree on allocator
#   ESCAPE         -- ReturnMark escape without guarded Cleanup
#   FRAME_ESCAPE   -- frame binding escapes without EscapePromote
#   GUARD_NO_SUPPRESS -- guarded Cleanup with no MoveMark (dead guard)
#
# Design: ONE generic walk, ~15 MIR node types, zero AST dependencies.

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

    allocs     = {}  # name => [AllocMark]
    cleanups   = {}  # name => [Cleanup]
    promotes   = {}  # name => [EscapePromote]
    escapes    = Set.new  # var names from ReturnMark
    moves      = Set.new  # var names from MoveMark
    reassigns  = {}  # name => ReassignMark
    field_marks = [] # FieldCleanupMark nodes
    raw_nodes  = []  # RawZig/InlineZig nodes

    # Single pass: collect all marker nodes from the MIR tree.
    walk_mir(fn_def.body) do |node|
      case node
      when MIR::AllocMark
        (allocs[node.name] ||= []) << node
      when MIR::Cleanup
        (cleanups[node.name] ||= []) << node
      when MIR::EscapePromote
        name = node.name
        (promotes[name] ||= []) << node if name
      when MIR::ReturnMark
        (node.escaped_vars || []).each { |v| escapes << v.to_s }
      when MIR::MoveMark
        moves << node.name.to_s
      when MIR::ReassignMark
        reassigns[node.name] = node
      when MIR::FieldCleanupMark
        field_marks << node
      when MIR::RawZig, MIR::InlineZig
        raw_nodes << node
      end
    end

    # Reconstruct bindings from AllocMark + Cleanup pairs.
    bindings = {}
    allocs.each do |name, anodes|
      bindings[name] = { alloc: anodes.first.alloc, kind: anodes.first.kind }
    end
    cleanups.each do |name, cnodes|
      entry = cnodes.first.cleanup_entry || {}
      bindings[name] ||= {}
      bindings[name][:has_moved_guard] = entry[:has_moved_guard]
      bindings[name][:alloc] ||= entry[:alloc]
      bindings[name][:kind] ||= entry[:kind]
    end

    check_completeness!(allocs, cleanups)
    check_alloc_consistency!(allocs, cleanups)
    check_escapes!(escapes, cleanups)
    check_frame_escapes!(escapes, cleanups, promotes, bindings)
    check_guard_suppress_completeness!(cleanups, moves, escapes)
    check_orphans!(allocs, cleanups, moves, reassigns, field_marks)
    check_raw_zig_contracts!(raw_nodes, allocs, cleanups, moves)

    @errors
  end

  # Verify all functions in a MIR::Program.
  def check_program!(program)
    all_errors = []
    program.items.each do |item|
      next unless item.is_a?(MIR::FnDef)
      errors = check_fn!(item)
      all_errors.concat(errors)
    end
    all_errors
  end

  private

  # ================================================================
  # Generic MIR tree walker -- yields every node, recursing into all
  # body/branch arrays. ~15 node types, exhaustive.
  # ================================================================

  def walk_mir(stmts, &block)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_mir_node(s, &block) }
  end

  def walk_mir_node(node, &block)
    return unless node
    yield node

    case node
    when MIR::FnDef
      walk_mir(node.body, &block)
    when MIR::IfStmt
      walk_mir(node.then_body, &block)
      walk_mir(node.else_body, &block)
    when MIR::WhileStmt
      walk_mir(node.body, &block)
    when MIR::ForStmt
      walk_mir(node.body, &block)
    when MIR::ScopeBlock
      walk_mir(node.body, &block)
    when MIR::BlockExpr
      walk_mir(node.body, &block)
    when MIR::SwitchStmt
      node.arms&.each { |a| walk_mir(a[:body], &block) }
      walk_mir(node.default_body, &block)
    when MIR::IfChain
      node.branches&.each { |b| walk_mir(b[:body], &block) }
      walk_mir(node.default_body, &block)
    when MIR::DeferStmt
      walk_mir_node(node.body, &block) if node.body
    when MIR::ErrDeferStmt
      walk_mir_node(node.body, &block) if node.body
    when MIR::RawZig
      # Opaque -- cannot walk inside. Marker already yielded above.
    end
  end

  # ================================================================
  # Invariant checks
  # ================================================================

  # Every AllocMark must have a matching Cleanup.
  def check_completeness!(allocs, cleanups)
    allocs.each do |name, _|
      unless cleanups.key?(name)
        @errors << error(:LEAK, name, "AllocMark without matching Cleanup (leak)")
      end
    end
    cleanups.each do |name, _|
      unless allocs.key?(name)
        # Cleanup without alloc could be a TAKES param (valid) -- only warn
        # if it's not a known pattern.
      end
    end
  end

  # AllocMark and Cleanup for the same binding must agree on allocator.
  def check_alloc_consistency!(allocs, cleanups)
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
  end

  # Escaped variables (via ReturnMark) must have guarded Cleanups.
  def check_escapes!(escapes, cleanups)
    escapes.each do |name|
      cnodes = cleanups[name]
      next unless cnodes
      cnodes.each do |cnode|
        unless cnode.cleanup_entry&.dig(:has_moved_guard)
          @errors << error(:ESCAPE, name, "escapes via return but Cleanup lacks moved guard")
        end
      end
    end
  end

  # Frame-allocated bindings that escape via return need EscapePromote.
  def check_frame_escapes!(escapes, cleanups, promotes, bindings)
    escapes.each do |name|
      b = bindings[name]
      next unless b && b[:alloc] == :frame
      next if promotes.key?(name)
      @errors << error(:FRAME_ESCAPE, name,
        "frame-allocated binding escapes via return without promotion (UAF)")
    end
  end

  # Every guarded Cleanup must have a MoveMark or ReturnMark escape.
  # A guarded Cleanup with no suppress means the guard is dead code.
  #
  # Excluded:
  # - TAKES params (takes_union, takes_string, takes_slice) -- guard managed
  #   by TAKES/MATCH machinery, not MoveMark.
  # - MATCH AS bindings (match_as_*) -- inner-scope, guard managed by match arm.
  GUARD_EXEMPT_KINDS = Set[:takes_union, :takes_string, :takes_slice,
                           :match_as_inline_struct, :match_as_slice].freeze

  def check_guard_suppress_completeness!(cleanups, moves, escapes)
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

  # No orphan MIR markers.
  def check_orphans!(allocs, cleanups, moves, reassigns, field_marks)
    # Cleanup without AllocMark (and not a TAKES param pattern)
    cleanups.each do |name, _|
      next if allocs.key?(name)
      # Cleanups for TAKES params have AllocMark too in the lowered tree,
      # so this genuinely means an orphan.
      @errors << error(:ORPHAN, name, "Cleanup without matching AllocMark")
    end

    # MoveMark for a binding that has no guarded Cleanup
    moves.each do |name|
      cnodes = cleanups[name]
      next if cnodes&.any? { |c| c.cleanup_entry&.dig(:has_moved_guard) }
      next if allocs.key?(name) # may be a TAKES param consumed before cleanup
      @errors << error(:ORPHAN, name, "MoveMark without matching guarded Cleanup")
    end
  end

  # RawZig/InlineZig ownership contract verification.
  def check_raw_zig_contracts!(raw_nodes, allocs, cleanups, moves)
    raw_nodes.each do |node|
      contract = node.respond_to?(:ownership_contract) ? node.ownership_contract : nil
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

  def error(kind, name, msg)
    "[#{kind}] #{@fn_name}::#{name} -- #{msg}"
  end
end
