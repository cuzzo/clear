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
    # Walk catch clause bodies for MIR nodes (e.g., MIR::Promote for catch_string_dupe).
    (@fn.catch_clauses || []).each do |clause|
      collect_mir_nodes(clause[:body], allocs, drops, promotes, escapes, suppresses,
                        reassign_cleanups, field_cleanups) if clause[:body]
    end
    if @fn.default_catch.is_a?(Array)
      collect_mir_nodes(@fn.default_catch, allocs, drops, promotes, escapes, suppresses,
                        reassign_cleanups, field_cleanups)
    end

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

    # Universal invariant: every guarded Drop must have a SuppressCleanup or
    # Return escape that sets the guard. A guarded Drop with no suppress means
    # the guard is always false (cleanup always fires = potential double-free
    # if the variable IS moved by a path the MIR forgot to cover).
    check_guard_suppress_completeness!(drops, suppresses, escapes)

    # Orphan checks always run (catch rogue MIR nodes).
    check_orphans!(allocs, drops, suppresses, reassign_cleanups, field_cleanups, takes)

    # Frame overflow checks always run (catch missing loop marks).
    check_frame_overflow!(@fn.body)

    # BG capture promotion checks always run (catch missing escape promotions).
    check_bg_capture_promotes!(@fn.body, promotes)

    # Safety net: catch heap-returning calls that HPT hoisting missed.
    check_unhoisted_heap_calls!(@fn.body)

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
    allocs.each do |name, alloc_nodes|
      drop_nodes = drops[name]
      next unless drop_nodes
      alloc_nodes.each do |alloc_node|
        drop_nodes.each do |drop_node|
          if alloc_node.alloc != drop_node.alloc
            @errors << error(:ALLOC_MISMATCH, name,
              "Alloc uses :#{alloc_node.alloc} but Drop uses :#{drop_node.alloc}")
            return # one error per name is enough
          end
        end
      end
    end
  end

  # MIR::Promote that converts frame->heap requires the matching Drop to be
  # guarded. Without a guard, the defer fires unconditionally after promotion,
  # freeing from the original (frame) allocator while data is now on heap.
  def check_promote_alloc_consistency!(promotes, drops)
    promotes.each do |name, promote_nodes|
      next unless name.is_a?(String) # skip synthetic names (:__ret, :__catch_ret, etc.)
      promote_nodes.each do |promote|
        next unless [:list, :string_map, :generic].include?(promote.strategy)
        drop_nodes = drops[name]
        next unless drop_nodes
        # Promote converts to heap; Drop allocator must match.
        drop_nodes.each do |drop|
          if drop.alloc == :frame
            @errors << error(:ALLOC_MISMATCH, name,
              "MIR::Promote converts to heap but Drop uses :frame (alloc mismatch after promotion)")
          end
        end
      end
    end
  end

  # Dataflow says maybe-moved -> Drop must be guarded.
  def check_guards!(drops, df_summary)
    drops.each do |name, drop_nodes|
      df_entry = df_summary[name]
      next unless df_entry

      drop_nodes.each do |drop|
        if df_entry[:has_moved_guard] && !drop.has_moved_guard
          @errors << error(:GUARD, name, "dataflow says maybe-moved but Drop lacks guard")
        end
      end
    end
  end

  # Escaped variables (via MIR::Return) must have guarded Drops so the
  # defer doesn't fire when ownership transfers to the caller.
  def check_escapes!(escapes, drops)
    escapes.each do |name|
      drop_nodes = drops[name]
      next unless drop_nodes
      drop_nodes.each do |drop|
        if !drop.has_moved_guard
          @errors << error(:ESCAPE, name, "escapes via return but Drop is unguarded")
        end
      end
    end
  end

  # Every guarded Drop must have a SuppressCleanup or Return escape that
  # sets the guard variable. Without one, the guard is dead code and the
  # cleanup fires unconditionally - if the variable IS moved on some path,
  # that's a double-free.
  #
  # Excluded from this check:
  # - TAKES parameters (guard is set by TAKES machinery, not MIR::SuppressCleanup)
  # - MATCH TAKES source variables (guard is set by transpiler's match handling)
  # - MATCH AS bindings (inner-scope, guard is harmless default)
  def check_guard_suppress_completeness!(drops, suppresses, escapes)
    takes = takes_param_names
    match_takes_sources = collect_match_takes_sources(@fn.body)
    match_as_bindings = collect_match_as_bindings(@fn.body)

    drops.each do |name, drop_nodes|
      drop_nodes.each do |drop|
        next unless drop.has_moved_guard
        next if suppresses.include?(name) || escapes.include?(name)
        next if takes.include?(name)
        next if match_takes_sources.include?(name)
        next if match_as_bindings.include?(name)
        @errors << error(:GUARD_NO_SUPPRESS, name,
          "guarded Drop but no SuppressCleanup or Return escape sets the guard")
      end
    end
  end

  def collect_match_takes_sources(stmts)
    sources = Set.new
    return sources unless stmts.is_a?(Array)
    stmts.each do |stmt|
      if stmt.is_a?(AST::MatchStatement) && stmt.takes &&
         stmt.expr.is_a?(AST::Identifier)
        sources << stmt.expr.name.to_s
      end
      case stmt
      when AST::IfStatement
        sources.merge(collect_match_takes_sources(stmt.then_branch))
        sources.merge(collect_match_takes_sources(stmt.else_branch))
      when AST::WhileLoop then sources.merge(collect_match_takes_sources(stmt.do_branch))
      when AST::ForRange, AST::ForEach then sources.merge(collect_match_takes_sources(stmt.body))
      when AST::MatchStatement
        stmt.cases&.each { |c| sources.merge(collect_match_takes_sources(c[:body])) }
        sources.merge(collect_match_takes_sources(stmt.default_case))
      when AST::WithBlock then sources.merge(collect_match_takes_sources(stmt.body))
      when AST::DoBlock
        stmt.branches&.each { |b| sources.merge(collect_match_takes_sources(b[:body])) }
      end
    end
    sources
  end

  def collect_match_as_bindings(stmts)
    bindings = Set.new
    return bindings unless stmts.is_a?(Array)
    stmts.each do |stmt|
      if stmt.is_a?(AST::MatchStatement)
        stmt.cases&.each do |c|
          bindings << c[:binding].to_s if c[:binding]
        end
      end
      case stmt
      when AST::IfStatement
        bindings.merge(collect_match_as_bindings(stmt.then_branch))
        bindings.merge(collect_match_as_bindings(stmt.else_branch))
      when AST::WhileLoop then bindings.merge(collect_match_as_bindings(stmt.do_branch))
      when AST::ForRange, AST::ForEach then bindings.merge(collect_match_as_bindings(stmt.body))
      when AST::MatchStatement
        stmt.cases&.each { |c| bindings.merge(collect_match_as_bindings(c[:body])) }
        bindings.merge(collect_match_as_bindings(stmt.default_case))
      when AST::WithBlock then bindings.merge(collect_match_as_bindings(stmt.body))
      when AST::DoBlock
        stmt.branches&.each { |b| bindings.merge(collect_match_as_bindings(b[:body])) }
      end
    end
    bindings
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

  # Check if a loop body contains any frame allocation.
  # Checks both MIR::Alloc nodes AND AST-level indicators (stdlib_allocates,
  # string concat BinaryOp) to catch cases where the transpiler emits
  # rt.frameAlloc() without a corresponding MIR::Alloc node.
  def body_has_frame_alloc?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |stmt|
      case stmt
      when MIR::Alloc then stmt.alloc == :frame
      when AST::VarDecl, AST::BindExpr
        stmt.storage == :frame || expr_has_frame_alloc?(stmt.value)
      when AST::FuncCall, AST::MethodCall
        expr_has_frame_alloc?(stmt)
      when AST::Assignment
        expr_has_frame_alloc?(stmt.value)
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

  # Check if an expression tree contains implicit frame allocations
  # (stdlib_allocates calls, string concat BinaryOps).
  # mutates_receiver calls (append, etc.) allocate into the container's
  # backing, not per-iteration frame scope -- skip their own stdlib_allocates
  # but still check value args.
  def expr_has_frame_alloc?(node)
    return false unless node
    case node
    when AST::FuncCall
      if node.respond_to?(:mutates_receiver) && node.mutates_receiver
        return node.args&.drop(1)&.any? { |a| expr_has_frame_alloc?(a) } || false
      end
      return true if node.respond_to?(:stdlib_allocates) && node.stdlib_allocates
      node.args&.any? { |a| expr_has_frame_alloc?(a) } || false
    when AST::MethodCall
      if node.respond_to?(:mutates_receiver) && node.mutates_receiver
        return node.args&.any? { |a| expr_has_frame_alloc?(a) } || false
      end
      return true if node.respond_to?(:stdlib_allocates) && node.stdlib_allocates
      expr_has_frame_alloc?(node.object) ||
        (node.args&.any? { |a| expr_has_frame_alloc?(a) } || false)
    when AST::BinaryOp
      if node.op == :ADD
        lt = node.left.type_info rescue nil
        rt = node.right.type_info rescue nil
        return true if (lt.is_a?(Type) ? lt.string? : lt == :String) ||
                       (rt.is_a?(Type) ? rt.string? : rt == :String)
      end
      expr_has_frame_alloc?(node.left) || expr_has_frame_alloc?(node.right)
    else
      false
    end
  end

  def collect_mir_nodes(stmts, allocs, drops, promotes, escapes, suppresses,
                        reassign_cleanups, field_cleanups)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::Alloc  then (allocs[stmt.name] ||= []) << stmt
      when MIR::Drop   then (drops[stmt.name] ||= []) << stmt
      when MIR::Promote then (promotes[stmt.name || :"__container_promote_#{promotes.size}"] ||= []) << stmt
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
      # Walk into all expression positions where BG blocks can appear.
      each_bg_in_stmt(stmt) do |bg|
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

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values, MethodCall args, FuncCall args.
  def each_bg_in_stmt(stmt, &block)
    case stmt
    when AST::BgBlock, AST::BgStreamBlock
      yield stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      _walk_expr_for_bg(stmt.respond_to?(:value) ? stmt.value : nil, &block)
    when AST::FuncCall
      stmt.args&.each { |a| _walk_expr_for_bg(a, &block) }
    when AST::MethodCall
      stmt.args&.each { |a| _walk_expr_for_bg(a, &block) }
    end
  end

  def _walk_expr_for_bg(expr, &block)
    return unless expr
    case expr
    when AST::BgBlock, AST::BgStreamBlock
      yield expr
    when AST::FuncCall
      expr.args&.each { |a| _walk_expr_for_bg(a, &block) }
    when AST::MethodCall
      _walk_expr_for_bg(expr.object, &block)
      expr.args&.each { |a| _walk_expr_for_bg(a, &block) }
    end
  end

  # Safety net: walk the post-MIR AST looking for FuncCall/MethodCall nodes
  # with heap_provenance that are NOT inside a VarDecl/BindExpr value (i.e.,
  # not hoisted by hoist_heap_temps!). Catches gaps if new AST positions are
  # added without corresponding HPT hoisting support.
  def check_unhoisted_heap_calls!(stmts, inside_bind_value: false)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::VarDecl, AST::BindExpr
        # The value of a VarDecl/BindExpr is a "bind position" -- HPT calls
        # here are either the bind target itself or already hoisted.
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.value
      when AST::ReturnNode
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.value
      when AST::Assignment
        scan_expr_for_unhoisted_heap!(stmt.value, inside_bind_value: true) if stmt.value
      when AST::FuncCall, AST::MethodCall
        scan_expr_for_unhoisted_heap!(stmt, inside_bind_value: false)
      when AST::IfStatement
        scan_expr_for_unhoisted_heap!(stmt.condition, inside_bind_value: false) if stmt.condition
        check_unhoisted_heap_calls!(stmt.then_branch)
        check_unhoisted_heap_calls!(stmt.else_branch)
      when AST::WhileLoop
        # WHILE conditions are rejected by check_no_heap_call_in_while_condition! in MIRPass.
        check_unhoisted_heap_calls!(stmt.do_branch)
      when AST::ForRange
        check_unhoisted_heap_calls!(stmt.body)
      when AST::ForEach
        scan_expr_for_unhoisted_heap!(stmt.collection, inside_bind_value: false) if stmt.collection
        check_unhoisted_heap_calls!(stmt.body)
      when AST::MatchStatement
        scan_expr_for_unhoisted_heap!(stmt.expr, inside_bind_value: false) if stmt.expr
        stmt.cases&.each { |c| check_unhoisted_heap_calls!(c[:body]) }
        check_unhoisted_heap_calls!(stmt.default_case)
      when AST::Assert
        scan_expr_for_unhoisted_heap!(stmt.condition, inside_bind_value: false) if stmt.condition
        scan_expr_for_unhoisted_heap!(stmt.message, inside_bind_value: false) if stmt.message
      when AST::WithBlock
        check_unhoisted_heap_calls!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| check_unhoisted_heap_calls!(b[:body]) }
      when AST::BgBlock, AST::BgStreamBlock
        check_unhoisted_heap_calls!(stmt.body)
      end
    end
  end

  # Walk an expression tree looking for unhoisted heap-returning calls.
  def scan_expr_for_unhoisted_heap!(node, inside_bind_value: false)
    return unless node
    case node
    when AST::FuncCall, AST::MethodCall
      ti = node.type_info rescue nil
      ti = ti.is_a?(Type) ? ti : nil
      if ti&.heap_provenance? && !inside_bind_value && !node.was_moved
        line = node.token&.line || "?"
        call_name = node.is_a?(AST::MethodCall) ? node.method_name : node.name
        @errors << "[UNHOISTED_HEAP_CALL] #{@fn.name} (line #{line}) -- " \
                   "heap-returning call '#{call_name}' not hoisted to a VarDecl (leak)"
      end
      # Recurse into args.
      node.args.each { |a| scan_expr_for_unhoisted_heap!(a, inside_bind_value: false) }
      if node.is_a?(AST::MethodCall)
        scan_expr_for_unhoisted_heap!(node.object, inside_bind_value: false)
      end
    when AST::BinaryOp
      scan_expr_for_unhoisted_heap!(node.left, inside_bind_value: inside_bind_value)
      scan_expr_for_unhoisted_heap!(node.right, inside_bind_value: inside_bind_value)
    when AST::GetField
      scan_expr_for_unhoisted_heap!(node.target, inside_bind_value: false)
    when AST::GetIndex
      scan_expr_for_unhoisted_heap!(node.target, inside_bind_value: false)
      scan_expr_for_unhoisted_heap!(node.index, inside_bind_value: false)
    when AST::MoveNode
      scan_expr_for_unhoisted_heap!(node.value, inside_bind_value: inside_bind_value)
    when AST::StructLit, AST::UnionVariantLit
      node.fields&.each_value { |v| scan_expr_for_unhoisted_heap!(v, inside_bind_value: inside_bind_value) }
    when AST::ListLit
      node.items&.each { |v| scan_expr_for_unhoisted_heap!(v, inside_bind_value: inside_bind_value) }
    end
  end

  def loop_error(kind, loop_node, msg)
    line = loop_node.token&.line || "?"
    "[#{kind}] #{@fn.name} (line #{line}) -- #{msg}"
  end
end
