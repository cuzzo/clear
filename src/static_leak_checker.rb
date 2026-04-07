# static_leak_checker.rb — Post-MIR ownership verification.
#
# Runs after MIRPass inserts Alloc/Drop/Return nodes into the AST and
# verifies that the MIR correctly implements the ownership dataflow
# requirements. Catches MIRPass bugs before code reaches the transpiler.
#
# Checks performed:
#   LEAK    — binding needs cleanup but lacks MIR::Alloc or MIR::Drop
#   GUARD   — maybe-moved binding's Drop lacks moved guard (double-free risk)
#   ESCAPE  — variable escapes via return but Drop is unguarded
#   ORPHAN  — MIR node without matching cleanup binding
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
    escapes = Set.new
    collect_mir_nodes(@fn.body, allocs, drops, escapes)

    takes = takes_param_names
    has_bindings = !@bindings.empty? || !takes.empty?

    if has_bindings
      # Independent path-sensitive move analysis.
      df = OwnershipDataflow.analyze(@fn, can_fail_fns: @can_fail_fns)
      df_summary = df.cleanup_summary

      check_completeness!(allocs, drops, takes)
      check_guards!(drops, df_summary)
      check_escapes!(escapes, drops)
    end

    # Orphan checks always run (catch rogue MIR nodes).
    check_orphans!(allocs, drops, takes)

    @errors
  end

  private

  # Every binding with needs_cleanup must have MIR::Alloc + MIR::Drop.
  # Match-as bindings are excluded: their cleanup is handled by
  # stamp_match_as_cleanup! on the MatchStatement case hash, not MIR::Drop.
  def check_completeness!(allocs, drops, takes)
    @bindings.each do |name, entry|
      next unless entry[:needs_cleanup]
      next if entry[:match_as]

      unless allocs.key?(name) || takes.include?(name)
        @errors << error(:LEAK, name, "needs cleanup but no MIR::Alloc")
      end

      unless drops.key?(name)
        @errors << error(:LEAK, name, "needs cleanup but no MIR::Drop")
      end
    end
  end

  # Dataflow says maybe-moved → Drop must be guarded.
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

  # No orphan MIR nodes — every Alloc/Drop should correspond to a binding
  # with needs_cleanup or a TAKES parameter.
  def check_orphans!(allocs, drops, takes)
    drops.each do |name, _|
      next if @bindings.dig(name, :needs_cleanup) || takes.include?(name)
      @errors << error(:ORPHAN, name, "MIR::Drop without matching cleanup binding")
    end

    allocs.each do |name, _|
      next if @bindings.dig(name, :needs_cleanup) || takes.include?(name)
      @errors << error(:ORPHAN, name, "MIR::Alloc without matching cleanup binding")
    end
  end

  def collect_mir_nodes(stmts, allocs, drops, escapes)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::Alloc  then allocs[stmt.name] = stmt
      when MIR::Drop   then drops[stmt.name] = stmt
      when MIR::Return then (stmt.escaped_vars || []).each { |v| escapes << v }
      when AST::IfStatement
        collect_mir_nodes(stmt.then_branch, allocs, drops, escapes)
        collect_mir_nodes(stmt.else_branch, allocs, drops, escapes)
      when AST::WhileLoop
        collect_mir_nodes(stmt.do_branch, allocs, drops, escapes)
      when AST::ForRange, AST::ForEach
        collect_mir_nodes(stmt.body, allocs, drops, escapes)
      when AST::MatchStatement
        stmt.cases&.each { |c| collect_mir_nodes(c[:body], allocs, drops, escapes) }
        collect_mir_nodes(stmt.default_case, allocs, drops, escapes)
      when AST::WithBlock
        collect_mir_nodes(stmt.body, allocs, drops, escapes)
      when AST::DoBlock
        stmt.branches&.each { |b| collect_mir_nodes(b[:body], allocs, drops, escapes) }
      when AST::BgBlock, AST::BgStreamBlock
        collect_mir_nodes(stmt.body, allocs, drops, escapes)
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
    "[#{kind}] #{@fn.name}::#{name} (line #{line}) — #{msg}"
  end
end
