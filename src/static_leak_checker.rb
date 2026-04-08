# static_leak_checker.rb -- Post-MIR ownership verification.
#
# Runs after MIRPass inserts Alloc/Drop/Return/Promote nodes into the AST
# and verifies that the MIR correctly implements the ownership dataflow
# requirements. Catches MIRPass bugs before code reaches the transpiler.
#
# Checks performed:
#   LEAK           -- binding needs cleanup but lacks MIR::Alloc or MIR::Drop
#   GUARD          -- maybe-moved binding's Drop lacks moved guard (double-free)
#   ESCAPE         -- variable escapes via return but Drop is unguarded
#   ORPHAN         -- MIR node without matching cleanup binding
#   FRAME_ESCAPE   -- frame-allocated binding escapes via return without promotion
#   FRAME_OVERFLOW -- loop body allocates from frame arena without per-iteration rewind
#   ALLOC_MISMATCH -- MIR::Alloc and MIR::Drop disagree on allocator (leak or UAF)
#   REASSIGN_LEAK  -- mutable reassignment without pre-cleanup (old value leaks)
#
# Path sensitivity comes from OwnershipDataflow (run independently on the
# pre-MIR CFG). The checker cross-references the dataflow results with
# the MIR events to verify consistency.

class StaticLeakChecker
  attr_reader :errors

  def initialize(fn_node, bindings:, can_fail_fns: nil)
    @fn = fn_node
    @bindings = bindings || {}
    @can_fail_fns = can_fail_fns
    @errors = []
  end

  # Verify the post-MIR function body. Returns array of error strings.
  def check!
    @errors = []

    # Collect MIR events from the post-MIR body.
    allocs = {}
    drops  = {}
    promotes = {}
    escapes = Set.new
    suppresses = Set.new
    reassign_cleanups = {}
    field_cleanups = []
    collect_mir_nodes(@fn.body, allocs, drops, promotes, escapes, suppresses,
                      reassign_cleanups, field_cleanups)

    takes = takes_param_names
    has_bindings = !@bindings.empty? || !takes.empty?

    if has_bindings
      # Independent path-sensitive move analysis.
      df = OwnershipDataflow.analyze(@fn, can_fail_fns: @can_fail_fns)
      df_summary = df.cleanup_summary

      check_completeness!(allocs, drops, takes)
      check_alloc_consistency!(allocs, drops)
      check_promote_alloc_consistency!(promotes, drops)
      check_guards!(drops, df_summary)
      check_escapes!(escapes, drops)
      check_frame_escapes!(escapes, promotes)
      check_reassign_completeness!(reassign_cleanups)
    end

    # Orphan checks always run (catch rogue MIR nodes).
    check_orphans!(allocs, drops, suppresses, reassign_cleanups, field_cleanups, takes)

    # Frame overflow checks always run (catch missing loop marks).
    check_frame_overflow!(@fn.body)

    # BG capture promotion checks always run (catch missing escape promotions).
    check_bg_capture_promotes!(@fn.body, promotes)

    @errors
  end

  private

  # Every binding with needs_cleanup must have MIR::Alloc + MIR::Drop.
  def check_completeness!(allocs, drops, takes)
    @bindings.each do |name, entry|
      next unless entry[:needs_cleanup]

      unless allocs.key?(name) || takes.include?(name)
        @errors << error(:LEAK, name, "needs cleanup but no MIR::Alloc")
      end

      unless drops.key?(name)
        @errors << error(:LEAK, name, "needs cleanup but no MIR::Drop")
      end
    end
  end

  # MIR::Alloc and MIR::Drop for the same binding must agree on allocator.
  # Mismatch means init uses one arena but cleanup frees from another --
  # either a leak (freed from wrong arena) or UAF (wrong arena reclaimed).
  def check_alloc_consistency!(allocs, drops)
    allocs.each do |name, alloc_node|
      drop_node = drops[name]
      next unless drop_node
      if alloc_node.alloc != drop_node.alloc
        @errors << error(:ALLOC_MISMATCH, name,
          "Alloc uses :#{alloc_node.alloc} but Drop uses :#{drop_node.alloc}")
      end
    end
  end

  # MIR::Promote that converts frame->heap requires the matching Drop to be
  # guarded. Without a guard, the defer fires unconditionally after promotion,
  # freeing from the original (frame) allocator while data is now on heap.
  def check_promote_alloc_consistency!(promotes, drops)
    promotes.each do |name, promote|
      next unless name.is_a?(String) # skip synthetic names (:__ret, :__catch_ret, etc.)
      next unless [:list, :string_map, :generic].include?(promote.strategy)
      drop = drops[name]
      next unless drop
      # Promote converts to heap; if Drop would still fire (no guard), allocator is wrong.
      if !drop.has_moved_guard && drop.alloc == :frame
        @errors << error(:ALLOC_MISMATCH, name,
          "MIR::Promote converts to heap but unguarded Drop uses :frame (UAF after promotion)")
      end
    end
  end

  # Dataflow says maybe-moved -> Drop must be guarded.
  def check_guards!(drops, df_summary)
    drops.each do |name, drop|
      df_entry = df_summary[name]
      next unless df_entry

      if df_entry[:has_moved_guard] && !drop.has_moved_guard
        @errors << error(:GUARD, name, "dataflow says maybe-moved but Drop lacks guard")
      end
    end
  end

  # Escaped variables (via MIR::Return) must have guarded Drops so the
  # defer doesn't fire when ownership transfers to the caller.
  def check_escapes!(escapes, drops)
    escapes.each do |name|
      drop = drops[name]
      if drop && !drop.has_moved_guard
        @errors << error(:ESCAPE, name, "escapes via return but Drop is unguarded")
      end
    end
  end

  # Frame-allocated bindings that escape via return must be promoted to heap
  # first. Without promotion the caller receives a pointer into the callee's
  # frame arena which is freed on return -- use-after-free.
  def check_frame_escapes!(escapes, promotes)
    escapes.each do |name|
      entry = @bindings[name]
      next unless entry && entry[:alloc] == :frame && entry[:needs_cleanup]
      next if promotes.key?(name)
      @errors << error(:FRAME_ESCAPE, name,
        "frame-allocated binding escapes via return without promotion (use-after-free)")
    end
  end

  # Every reassignment of a needs_cleanup binding must have a
  # MIR::ReassignCleanup so the old value is freed before overwrite.
  def check_reassign_completeness!(reassign_cleanups)
    reassign_sites = Set.new
    collect_reassign_sites(@fn.body, reassign_sites)

    reassign_sites.each do |name|
      entry = @bindings[name]
      next unless entry && entry[:needs_cleanup] && entry[:kind] != :resource
      unless reassign_cleanups.key?(name)
        @errors << error(:REASSIGN_LEAK, name,
          "reassignment without pre-cleanup (old value leaks)")
      end
    end
  end

  # Loops that allocate from the frame arena must have mark_per_iter set
  # so the transpiler emits saveLoopMark/restoreLoopMark. Without it,
  # each iteration grows the arena unboundedly -- eventual overflow.
  def check_frame_overflow!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::WhileLoop
        if !stmt.mark_per_iter && !stmt.tight && body_has_frame_alloc?(stmt.do_branch)
          @errors << loop_error(:FRAME_OVERFLOW, stmt,
            "loop body allocates from frame arena without per-iteration rewind")
        end
        check_frame_overflow!(stmt.do_branch)
      when AST::ForRange
        if !stmt.mark_per_iter && !stmt.tight && body_has_frame_alloc?(stmt.body)
          @errors << loop_error(:FRAME_OVERFLOW, stmt,
            "loop body allocates from frame arena without per-iteration rewind")
        end
        check_frame_overflow!(stmt.body)
      when AST::IfStatement
        check_frame_overflow!(stmt.then_branch)
        check_frame_overflow!(stmt.else_branch)
      when AST::MatchStatement
        stmt.cases&.each { |c| check_frame_overflow!(c[:body]) }
        check_frame_overflow!(stmt.default_case)
      when AST::WithBlock
        check_frame_overflow!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| check_frame_overflow!(b[:body]) }
      when AST::BgBlock, AST::BgStreamBlock
        check_frame_overflow!(stmt.body)
      end
    end
  end

  # No orphan MIR nodes -- every Alloc/Drop/SuppressCleanup/ReassignCleanup/FieldCleanup
  # should correspond to a binding with needs_cleanup or a TAKES parameter.
  def check_orphans!(allocs, drops, suppresses, reassign_cleanups, field_cleanups, takes)
    drops.each do |name, _|
      next if @bindings.dig(name, :needs_cleanup) || takes.include?(name)
      @errors << error(:ORPHAN, name, "MIR::Drop without matching cleanup binding")
    end

    allocs.each do |name, _|
      next if @bindings.dig(name, :needs_cleanup) || takes.include?(name)
      @errors << error(:ORPHAN, name, "MIR::Alloc without matching cleanup binding")
    end

    suppresses.each do |name|
      next if @bindings.dig(name, :has_moved_guard) || takes.include?(name)
      @errors << error(:ORPHAN, name, "MIR::SuppressCleanup without matching guarded binding")
    end

    reassign_cleanups.each do |name, _|
      next if @bindings.dig(name, :needs_cleanup) || takes.include?(name)
      @errors << error(:ORPHAN, name, "MIR::ReassignCleanup without matching cleanup binding")
    end

    field_cleanups.each do |fc|
      next unless fc.target_name
      next if @bindings.key?(fc.target_name) || takes.include?(fc.target_name)
      @errors << error(:ORPHAN, fc.target_name,
        "MIR::FieldCleanup for #{fc.field} without matching binding")
    end
  end

  # Check if a loop body contains any MIR::Alloc with frame allocation.
  def body_has_frame_alloc?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |stmt|
      case stmt
      when MIR::Alloc then stmt.alloc == :frame
      when AST::IfStatement
        body_has_frame_alloc?(stmt.then_branch) || body_has_frame_alloc?(stmt.else_branch)
      when AST::MatchStatement
        (stmt.cases || []).any? { |c| body_has_frame_alloc?(c[:body]) } ||
          body_has_frame_alloc?(stmt.default_case)
      when AST::WhileLoop then body_has_frame_alloc?(stmt.do_branch)
      when AST::ForRange, AST::ForEach then body_has_frame_alloc?(stmt.body)
      when AST::WithBlock then body_has_frame_alloc?(stmt.body)
      when AST::DoBlock
        (stmt.branches || []).any? { |b| body_has_frame_alloc?(b[:body]) }
      when AST::BgBlock, AST::BgStreamBlock then body_has_frame_alloc?(stmt.body)
      else false
      end
    end
  end

  def collect_mir_nodes(stmts, allocs, drops, promotes, escapes, suppresses,
                        reassign_cleanups, field_cleanups)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::Alloc  then allocs[stmt.name] = stmt
      when MIR::Drop   then drops[stmt.name] = stmt
      when MIR::Promote then promotes[stmt.name || :"__container_promote_#{promotes.size}"] = stmt
      when MIR::Return then (stmt.escaped_vars || []).each { |v| escapes << v }
      when MIR::SuppressCleanup then suppresses << stmt.name
      when MIR::ReassignCleanup then reassign_cleanups[stmt.name] = stmt
      when MIR::FieldCleanup then field_cleanups << stmt
      when AST::IfStatement
        collect_mir_nodes(stmt.then_branch, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
        collect_mir_nodes(stmt.else_branch, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
      when AST::WhileLoop
        collect_mir_nodes(stmt.do_branch, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
      when AST::ForRange, AST::ForEach
        collect_mir_nodes(stmt.body, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
      when AST::MatchStatement
        stmt.cases&.each { |c| collect_mir_nodes(c[:body], allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups) }
        collect_mir_nodes(stmt.default_case, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
      when AST::WithBlock
        collect_mir_nodes(stmt.body, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
      when AST::DoBlock
        stmt.branches&.each { |b| collect_mir_nodes(b[:body], allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups) }
      when AST::BgBlock, AST::BgStreamBlock
        collect_mir_nodes(stmt.body, allocs, drops, promotes, escapes, suppresses, reassign_cleanups, field_cleanups)
      end
    end
  end

  # Walk the function body for BindExpr :assign nodes to find reassignment sites.
  def collect_reassign_sites(stmts, sites)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::BindExpr
        sites << stmt.name.to_s if stmt.mode == :assign
      when AST::IfStatement
        collect_reassign_sites(stmt.then_branch, sites)
        collect_reassign_sites(stmt.else_branch, sites)
      when AST::WhileLoop
        collect_reassign_sites(stmt.do_branch, sites)
      when AST::ForRange, AST::ForEach
        collect_reassign_sites(stmt.body, sites)
      when AST::MatchStatement
        stmt.cases&.each { |c| collect_reassign_sites(c[:body], sites) }
        collect_reassign_sites(stmt.default_case, sites)
      when AST::WithBlock
        collect_reassign_sites(stmt.body, sites)
      when AST::DoBlock
        stmt.branches&.each { |b| collect_reassign_sites(b[:body], sites) }
      when AST::BgBlock, AST::BgStreamBlock
        collect_reassign_sites(stmt.body, sites)
      end
    end
  end

  def takes_param_names
    Set.new((@fn.deferred_drops || [])
      .select { |dd| @fn.params&.any? { |p| p[:name] == dd[:name] && p[:takes] } }
      .map { |dd| dd[:name].to_s })
  end

  def error(kind, name, msg)
    line = @fn.token&.line || "?"
    "[#{kind}] #{@fn.name}::#{name} (line #{line}) -- #{msg}"
  end

  # BG blocks that capture frame-allocated variables needing escape promotion
  # must have a corresponding MIR::Promote. Without promotion the fiber
  # outlives the parent frame -- use-after-free.
  def check_bg_capture_promotes!(stmts, promotes)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      bg = case stmt
           when AST::BgBlock, AST::BgStreamBlock then stmt
           when AST::VarDecl, AST::BindExpr, AST::Assignment
             v = stmt.respond_to?(:value) ? stmt.value : nil
             (v.is_a?(AST::BgBlock) || v.is_a?(AST::BgStreamBlock)) ? v : nil
           else nil
           end
      if bg
        captures = bg.capture_analysis&.captures
        captures&.each do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          next unless t && t.needs_escape_promotion? && !t.needs_pointer_passing?
          unless promotes.key?(name) || promotes.key?(name.to_s) || promotes.key?(name.to_sym)
            @errors << error(:FRAME_ESCAPE, name,
              "BG capture needs escape promotion but no MIR::Promote found (use-after-free)")
          end
        end
      end
      # Recurse into nested control flow.
      case stmt
      when AST::IfStatement
        check_bg_capture_promotes!(stmt.then_branch, promotes)
        check_bg_capture_promotes!(stmt.else_branch, promotes)
      when AST::WhileLoop then check_bg_capture_promotes!(stmt.do_branch, promotes)
      when AST::ForRange, AST::ForEach then check_bg_capture_promotes!(stmt.body, promotes)
      when AST::MatchStatement
        stmt.cases&.each { |c| check_bg_capture_promotes!(c[:body], promotes) }
        check_bg_capture_promotes!(stmt.default_case, promotes)
      when AST::WithBlock then check_bg_capture_promotes!(stmt.body, promotes)
      when AST::DoBlock
        stmt.branches&.each { |b| check_bg_capture_promotes!(b[:body], promotes) }
      end
    end
  end

  def loop_error(kind, loop_node, msg)
    line = loop_node.token&.line || "?"
    "[#{kind}] #{@fn.name} (line #{line}) -- #{msg}"
  end
end
