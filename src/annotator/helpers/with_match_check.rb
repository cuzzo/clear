# typed: strict
require "sorbet-runtime"
require_relative "../../semantic/capability_plan"
# Validation of REQUIRES + WITH MATCH at the function level and call-site
# family check.
#
# Two structural rules, enforced once per function after annotation:
#
#   WITH-on-param ⇒ REQUIRES-on-param
#      A WITH (any form) that binds a parameter requires the function to
#      name that parameter in REQUIRES. Capability flow stops at the WITH
#      boundary; the constraint must be authored.
#
#   REQUIRES↔WHEN exhaustiveness
#      For a WITH MATCH form, the set of WHEN-arm families must exactly
#      equal the family disjunction in REQUIRES for the bound parameters.
#      No missing arm; no extra arm; no default.
#
# The check runs after the annotator's body walk so all nodes are stamped
# with `symbol` references, and runs before any MIR-stage pass.
module WithMatchCheck
    extend T::Sig

  # Each REQUIRES family expands to storage axes. A disjunction is
  # polymorphic when its union admits more than one axis, which requires
  # comptime dispatch in the WITH body.
  FAMILY_AXES = T.let({
    LOCKED:      Set[:locked, :write_locked].freeze,
    SNAPSHOTTED: Set[:versioned, :atomic].freeze,
    VERSIONED:   Set[:versioned].freeze,
    ATOMIC:      Set[:atomic].freeze,
    # Non-sync bindings split into @local, @multiowned, and plain T axes.
    # All three lower to direct field access; the axis split exists
    # so the polymorphic-iff-rule sees LOCAL as poly (3 > 1) and the
    # body must use WITH POLYMORPHIC. Concrete-binding callers are
    # accepted via family_of_arg's `:LOCAL` return for non-sync syncs.
    LOCAL:       Set[:local, :multiowned, :plain].freeze,
    ACTOR:       Set[:actor].freeze,
    LOCK_FREE:   Set[:lock_free].freeze,
  }.freeze, T::Hash[Symbol, T::Set[Symbol]])

  sig { params(family_set: T.nilable(T::Set[Symbol])).returns(T::Set[Symbol]) }
  def self.admissible_axes(family_set)
    (family_set || []).flat_map { |f| (FAMILY_AXES[f] || Set.new).to_a }.to_set
  end

  sig { params(family_set: T.nilable(T::Set[Symbol])).returns(T::Boolean) }
  def self.poly_requires?(family_set)
    admissible_axes(family_set).size > 1
  end

  sig { params(fn: AST::FunctionDef, with_blocks: T::Array[AST::WithBlock], error_handler: Proc, warn_handler: T.nilable(Proc), policy_handlers: T.nilable(T::Array[AST::ErrorClause])).void }
  def self.check_function!(fn, with_blocks, error_handler, warn_handler: nil, policy_handlers: nil)
    requires_map = (fn.respond_to?(:requires) ? fn.requires : nil) || {}
    param_names = fn.params.map { |p| p.name.to_s }.to_set

    with_blocks.each do |node|
      # WITH VIEW / WITH MATERIALIZED VIEW are reads on an `@observable`
      # source, not lock acquisitions, so the LOCKED auto-shim must not fire.
      next if node.view_kind

      bound_params = collect_bound_param_names(node, param_names)

      # WITH POLYMORPHIC is REQUIRED when the bound binding's REQUIRES
      # admits more than one storage axis; REJECTED otherwise. Applies
      # only to plain WITH (the WITH MATCH form has its own per-arm
      # dispatch). VIEW and SNAPSHOT have their own paths.
      enforce_polymorphic_iff_rule!(node, bound_params, requires_map, fn,
                                    error_handler) unless node.arms

      # For WITH POLYMORPHIC blocks, project the admissible-family
      # error set and warn on errors that no handler covers (per-WITH
      # ON or program SYNC POLICY).
      warn_polymorphic_unhandled_errors!(node, bound_params, requires_map,
                                         T.must(policy_handlers), T.must(warn_handler)) unless node.arms

      if node.polymorphic
        fn.uses_rt = true if fn.respond_to?(:uses_rt=)
        fn.uses_alloc = true if fn.respond_to?(:uses_alloc=)
      end

      # Rule 1: WITH-on-param ⇒ REQUIRES-on-param.
      bound_params.each do |pname|
        next if requires_map.key?(pname)

        # `WITH POLYMORPHIC` on a param without REQUIRES is universally
        # polymorphic. Empty Set means no specific family is required and lets
        # call-site checks accept every caller without hitting the LOCKED shim.
        if node.polymorphic
          requires_map[pname] = Set.new
          fn.requires ||= {}
          fn.requires[pname] = Set.new
          node.universal_poly = true
          # The lowering routes universal-poly WITH POLYMORPHIC to
          # `CheatLib.polymorphicMutate(c, rt, ...)` which threads rt
          # into Versioned/AtomicPtr `.update(rt, alloc, ...)` paths.
          # Force the enclosing fn to take rt and report fallible
          # (compute_needs_rt! and compute_can_fail! run later and
          # honor these stamps).
          fn.uses_rt = true if fn.respond_to?(:uses_rt=)
          fn.uses_alloc = true if fn.respond_to?(:uses_alloc=)
          next
        end

        # Compatibility shim: source that uses WITH on a parameter without
        # declaring REQUIRES is auto-upgraded to
        # `REQUIRES <pname>: LOCKED`. A deprecation note surfaces so the
        # migration is visible. The shim will be removed in a future release.
        if warn_handler
          warn_handler.call(node,
            "WITH at line #{node.token.line} uses parameter '#{pname}' " \
            "without a REQUIRES clause. Auto-inferring " \
            "'REQUIRES #{pname}: LOCKED' for this release. " \
            "Add the clause explicitly to silence this warning; the shim " \
            "will be removed in a future release.")
          requires_map[pname] = Set[:LOCKED]
          # Also stamp fn.requires so call-site checks and FunctionSignature
          # see the inferred clause.
          fn.requires ||= {}
          fn.requires[pname] = Set[:LOCKED]
        else
          error_handler.call(node,
            "WITH at line #{node.token.line} uses parameter '#{pname}', " \
            "but '#{pname}' is not constrained by REQUIRES. " \
            "Add a REQUIRES clause naming the families this function supports:\n" \
            "    REQUIRES #{pname}: LOCKED\n" \
            "REQUIRES is mandatory whenever WITH is used on a parameter — " \
            "capability flow stops here.")
        end
      end

      # Rule 2: REQUIRES↔WHEN exhaustiveness (only for MATCH form).
      next unless node.arms

      arm_families = node.arms.map { |a| a[:family] }.to_set

      # Required families = union across all WITH-bound params' family disjunctions.
      required_families = bound_params.flat_map { |p| (requires_map[p] || Set.new).to_a }.to_set

      missing = required_families - arm_families
      extra   = arm_families - required_families

      missing.each do |fam|
        error_handler.call(node,
          "WITH MATCH at line #{node.token.line} is missing a WHEN arm for " \
          "#{fam} (declared in REQUIRES). Add an arm:\n" \
          "    WHEN #{fam}\n" \
          "        -> { <body for #{fam} strategy> }")
      end

      extra.each do |fam|
        error_handler.call(node,
          "WITH MATCH at line #{node.token.line} has a WHEN arm for #{fam}, " \
          "but #{fam} is not in REQUIRES. Either remove the arm or add #{fam} " \
          "to REQUIRES.")
      end
    end
    nil
  end

  # Names of parameters bound by this WITH (i.e., the original variable
  # name, not the AS alias). Walks the capabilities list; for each
  # capability whose var_node is an Identifier referencing a param, add
  # the name. Field accesses (`pool.field`) and non-param locals are
  # skipped — they don't need REQUIRES.
  sig { params(with_node: AST::WithBlock, param_names: T::Set[String]).returns(T::Set[String]) }
  def self.collect_bound_param_names(with_node, param_names)
    out = Set.new
    CapabilityPlan.require_for(with_node).all.each do |cap|
      vn = cap.var_node
      next unless vn.is_a?(AST::Identifier)
      out << vn.name if param_names.include?(vn.name)
    end
    out
  end

  # Per-WITH polymorphic-iff rule:
  #
  #   - WITH POLYMORPHIC is REQUIRED when any bound param's REQUIRES
  #     admits more than one storage axis (`poly_requires?` true).
  #     Plain WITH on a poly param errors with a hint to add POLYMORPHIC
  #     or narrow REQUIRES.
  #
  #   - WITH POLYMORPHIC is REJECTED when no bound param's REQUIRES is
  #     polymorphic (every bound param's REQUIRES admits exactly one
  #     axis, OR the WITH binds a concrete non-param). The error tells
  #     the user to "either be specific (drop POLYMORPHIC) or broaden
  #     REQUIRES to a polymorphic family."
  #
  # The check only runs for plain WITH. WITH MATCH, VIEW, MATERIALIZED VIEW,
  # and SNAPSHOT have their own dispatch shapes.
  sig { params(node: AST::WithBlock, bound_params: T::Set[String], requires_map: T::Hash[String, T.untyped], fn: AST::FunctionDef, error_handler: Proc).returns(T.nilable(FsmOps::CallExpr)) }
  def self.enforce_polymorphic_iff_rule!(node, bound_params, requires_map,
                                         fn, error_handler)
    return if node.view_kind || node.snapshot_mode

    has_poly_param = bound_params.any? { |p| poly_requires?(requires_map[p]) }

    # A parameter without REQUIRES is universally polymorphic. Treat it as
    # polymorphic only for WITH POLYMORPHIC so the plain-WITH LOCKED shim keeps
    # working.
    has_universal_poly_param = bound_params.any? { |p|
      !requires_map.key?(p) || (requires_map[p]&.empty?)
    }

    if node.polymorphic && !has_poly_param && !has_universal_poly_param
      error_handler.call(node,
        "WITH POLYMORPHIC is only allowed when at least one bound binding " \
        "is a polymorphic parameter (REQUIRES admits more than one storage " \
        "family, e.g. `LOCKED` or `SNAPSHOTTED`). " \
        "Either drop POLYMORPHIC and use plain WITH (be specific), " \
        "or broaden REQUIRES to a polymorphic family.")
    elsif !node.polymorphic && has_poly_param
      poly_param_examples = bound_params.select { |p| poly_requires?(requires_map[p]) }
      example = poly_param_examples.first
      example_fams = (requires_map[T.must(example)] || Set.new).to_a.join(' | ')
      error_handler.call(node,
        "Plain WITH on the polymorphic parameter '#{example}' " \
        "(REQUIRES admits #{example_fams}) is not allowed. " \
        "Use `WITH POLYMORPHIC ...` so the body's polymorphism is visible " \
        "at the use site (the comptime dispatch lowers per family). " \
        "If you want to commit to a single family, narrow REQUIRES to one " \
        "of: VERSIONED, ATOMIC.")
    end
  end

  # At every call site, verify each REQUIRES'd arg's binding belongs to
  # one of the families in the callee's disjunction.
  sig { params(call_sites: T::Array[AST::FuncCall], sig_lookup: Proc, error_handler: Proc).void }
  def self.check_call_sites!(call_sites, sig_lookup, error_handler)
    call_sites.each do |call_node|
      sig = FunctionSignature.unwrap(sig_lookup.call(call_node.name.to_s))
      next unless sig

      requires_map = sig.requires

      # Plain-T args passed to universal-poly params must be lowered as Zig
      # `var` so &c yields *T instead of *const T and polymorphicMutate can
      # write back.
      sig.params.each_with_index do |param, idx|
        pname = param.name.to_s
        fams = requires_map[pname]
        next unless fams && fams.empty?
        arg = call_node.args[idx]
        next unless arg.is_a?(AST::Identifier)
        sym = arg.symbol
        next unless sym
        next if sym.with_match_capability_family?
        next unless sym.respond_to?(:mutable) && sym.mutable
        sym.mark_poly_borrow_target!
      end

      sig.params.each_with_index do |param, idx|
        param_name = param.name.to_s
        disjunction = requires_map[param_name]
        next unless disjunction && !disjunction.empty?

        arg = call_node.args[idx]
        next unless arg

        arg_family = family_of_arg(arg)
        if arg_family.nil?
          error_handler.call(call_node,
            "Call to '#{call_node.name}' requires parameter '#{param_name}' to be " \
            "bound under one of: #{disjunction.to_a.join(' | ')}. " \
            "The argument here is bound without sync, which belongs to no " \
            "family. Add a sync wrapper at the binding declaration " \
            "(e.g., '@locked' or '@shared:locked').")
        elsif !disjunction_admits?(disjunction, arg_family)
          error_handler.call(call_node,
            "Call to '#{call_node.name}' requires parameter '#{param_name}' to be " \
            "bound under one of: #{disjunction.to_a.join(' | ')}. " \
            "The argument here is in family #{arg_family}, which is not " \
            "accepted by this function.")
        end
      end
    end
  end

  # Map a SymbolEntry's sync to the family name it belongs to.
  # LOCKED    = mutex / rwlock / refcell -- the lock-based path.
  # VERSIONED = MVCC Versioned(T) -- the lock-free snapshot path.
  # ATOMIC    = single-cell Atomic(T) -- the lock-free single-cell path.
  # ACTOR / LOCK_FREE remain reserved.
  LOCKED_SYNCS    = T.let(%i[locked write_locked always_mutable].to_set.freeze, T::Set[Symbol])
  VERSIONED_SYNCS = T.let(%i[versioned].to_set.freeze, T::Set[Symbol])
  ATOMIC_SYNCS    = T.let(%i[atomic].to_set.freeze, T::Set[Symbol])

  sig { params(arg: T.untyped).returns(T.nilable(Symbol)) }
  def self.family_of_arg(arg)
    sym = arg.symbol
    return nil unless sym
    return :LOCKED    if LOCKED_SYNCS.include?(sym.sync)
    return :VERSIONED if VERSIONED_SYNCS.include?(sym.sync)
    return :ATOMIC    if ATOMIC_SYNCS.include?(sym.sync)
    # Non-sync bindings (plain T, @local, @multiowned) are all in the LOCAL
    # family. The body lowers to direct alias access through the no-op
    # WITH POLYMORPHIC path.
    #   - @local       -> sym.sync == :local
    #   - @multiowned  -> sym.storage == :multiowned (sync nil)
    #   - plain T      -> sym.sync nil + storage stack/heap (no shared)
    return :LOCAL if sym.local?
    return :LOCAL if sym.sync.nil? && sym.storage == :multiowned
    return :LOCAL if sym.plain_local_family?
    nil
  end

  # SNAPSHOTTED is the umbrella family for VERSIONED and ATOMIC; LOCKED admits
  # :LOCKED at the family level. Other families are exact-match.
  sig { params(disjunction: T::Set[Symbol], arg_family: Symbol).returns(T::Boolean) }
  def self.disjunction_admits?(disjunction, arg_family)
    (disjunction || []).any? { |f|
      next true if f == arg_family
      next true if f == :SNAPSHOTTED && (arg_family == :VERSIONED || arg_family == :ATOMIC)
      false
    }
  end

  # Return the set of families an arg's binding could be in.
  # For a concrete @shared:atomic / :locked / :versioned binding, returns a
  # singleton set ({:ATOMIC} / {:LOCKED} / {:VERSIONED}).
  # For a parameter constrained by a multi-family REQUIRES disjunction
  # (REQUIRES p: ATOMIC | LOCKED), returns the disjunction Set so call-site
  # effect resolution can keep ?-form alive when the polymorphism propagates.
  # SNAPSHOTTED in sync_families is expanded to {VERSIONED, ATOMIC} so
  # downstream readers (effect resolution, mir lowering) see concrete
  # families uniformly.
  # Returns an empty Set when the arg has no sync attribute (no contention).
  sig { params(arg: T.untyped).returns(T::Set[Symbol]) }
  def self.family_of_arg_set(arg)
    sym = arg.symbol
    return Set.new unless sym
    if sym.sync_families && sym.sync_families.size > 1
      return expand_snapshotted(sym.sync_families)
    end
    if sym.sync_families && sym.sync_families.size == 1
      single = sym.sync_families.first
      return Set[:VERSIONED, :ATOMIC] if single == :SNAPSHOTTED
    end
    fam = family_of_arg(arg)
    fam ? Set[fam] : Set.new
  end

  sig { params(family_set: T::Set[T.untyped]).returns(T::Set[T.untyped]) }
  def self.expand_snapshotted(family_set)
    return family_set unless family_set.include?(:SNAPSHOTTED)
    out = family_set - [:SNAPSHOTTED]
    out << :VERSIONED << :ATOMIC
    out
  end

  # Per-storage-axis error projection.
  # Each axis can surface a fixed set of errors at the WITH boundary.
  # Used by the polymorphic-warning surface and call-site error collapsing.
  AXIS_ERRORS = T.let({
    locked:        Set[:LockTimeout].freeze,
    write_locked:  Set[:LockTimeout].freeze,
    versioned:     Set[:MvccConflict].freeze,
    atomic:        Set[:AtomicConflict].freeze,
  }.freeze, T::Hash[Symbol, T::Set[Symbol]])

  # Compute the union of errors that COULD fire from a polymorphic WITH
  # given the binding's REQUIRES disjunction. Deadlock/LockCycle are
  # NOT included here -- those are surfaced via the static cycle
  # detector (lock_helper.rb) when a cycle is reachable, and they are
  # always inline-only (never defaulted by SYNC POLICY).
  sig { params(family_set: T.nilable(T::Set[Symbol])).returns(T::Set[Symbol]) }
  def self.errors_for_requires(family_set)
    admissible_axes(family_set)
      .flat_map { |axis| (AXIS_ERRORS[axis] || Set.new).to_a }
      .to_set
  end

  # Per-WITH polymorphic-warning surface: project the admissible
  # family-set, subtract per-WITH ON handlers and program SYNC POLICY,
  # warn on the remainder.
  #
  # In normal usage with the baked-in SYNC POLICY, every axis-error
  # (LockTimeout / MvccConflict / AtomicConflict) is covered, so the
  # remainder is empty and no warning fires. The check exists so a
  # user-written partial-coverage scenario (or a future strict-mode
  # build) surfaces unhandled polymorphic errors at the WITH site.
  sig { params(node: AST::WithBlock, bound_params: T::Set[String], requires_map: T::Hash[String, T::Set[Symbol]], policy_handlers: T::Array[AST::ErrorClause], warn_handler: Proc).returns(T.nilable(T::Set[String])) }
  def self.warn_polymorphic_unhandled_errors!(node, bound_params, requires_map,
                                              policy_handlers, warn_handler)
    return unless warn_handler && node.polymorphic
    handled = handled_error_set(node, policy_handlers)
    bound_params.each do |pname|
      fams = requires_map[pname]
      next unless fams && !fams.empty?
      possible = errors_for_requires(fams)
      unhandled = possible - handled
      unhandled.each do |err|
        warn_handler.call(node,
          "Polymorphic error `#{err}` may fire under " \
          "`REQUIRES #{pname}: #{fams.to_a.join(' | ')}` but no handler is " \
          "in scope (per-WITH `ON #{err} ...` or program SYNC POLICY).")
      end
    end
  end

  # Names of errors handled by either the per-WITH `ON ...` clause
  # or the program-level SYNC POLICY. Type selectors contribute their
  # literal name, kind selectors expand via AST.types_for_kind.
  sig { params(node: AST::WithBlock, policy_handlers: T.nilable(T::Array[AST::ErrorClause])).returns(T::Set[Symbol]) }
  def self.handled_error_set(node, policy_handlers)
    handled = Set.new
    [node.lock_error_clause, *(policy_handlers || [])].compact.each do |clause|
      clause.selectors.each do |sel|
        case sel.form
        when :type
          handled << sel.name
        when :kind
          AST.types_for_kind(sel.name).each { |t| handled << t }
        end
      end
    end
    handled
  end

end
