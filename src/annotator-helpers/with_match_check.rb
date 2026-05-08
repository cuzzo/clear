# typed: true
require "sorbet-runtime"
# P2.4 / P2.5 / P2.6: validation of REQUIRES + WITH MATCH at the function
# level + call-site family check.
#
# Two structural rules, enforced once per function after annotation:
#
#   1. WITH-on-param ⇒ REQUIRES-on-param
#      A WITH (any form) that binds a parameter requires the function to
#      name that parameter in REQUIRES. Capability flow stops at the WITH
#      boundary; the constraint must be authored.
#
#   2. REQUIRES↔WHEN exhaustiveness
#      For a WITH MATCH form, the set of WHEN-arm families must exactly
#      equal the family disjunction in REQUIRES for the bound parameters.
#      No missing arm; no extra arm; no default.
#
# The check runs after the annotator's body walk so all nodes are stamped
# with `symbol` references, and runs before any MIR-stage pass.
module WithMatchCheck
    extend T::Sig

  # True-Sync-Polymorphism (#326): each REQUIRES family expands to a set of
  # storage axes. A REQUIRES disjunction is "polymorphic" when its union
  # admits more than one axis -- the WITH body must lower via comptime
  # `@hasDecl` dispatch in that case (#328 lowering). Per design doc,
  # LOCKED and SNAPSHOTTED are poly; VERSIONED and ATOMIC are mono.
  FAMILY_AXES = {
    LOCKED:      Set[:locked, :write_locked].freeze,
    SNAPSHOTTED: Set[:versioned, :atomic].freeze,
    VERSIONED:   Set[:versioned].freeze,
    ATOMIC:      Set[:atomic].freeze,
    # #336: non-sync umbrella. The three axes correspond to the three
    # admissible bindings: @local, @multiowned, and plain T (no sigil).
    # All three lower to direct field access; the axis split exists
    # so the polymorphic-iff-rule sees LOCAL as poly (3 > 1) and the
    # body must use WITH POLYMORPHIC. Concrete-binding callers are
    # accepted via family_of_arg's `:LOCAL` return for non-sync syncs.
    LOCAL:       Set[:local, :multiowned, :plain].freeze,
    ACTOR:       Set[:actor].freeze,
    LOCK_FREE:   Set[:lock_free].freeze,
  }.freeze

  sig { params(family_set: T.untyped).returns(Set) }
  def self.admissible_axes(family_set)
    (family_set || []).flat_map { |f| (FAMILY_AXES[f] || Set.new).to_a }.to_set
  end

  sig { params(family_set: T.untyped).returns(T::Boolean) }
  def self.poly_requires?(family_set)
    admissible_axes(family_set).size > 1
  end

  sig { params(fn: T.untyped, error_handler: T.untyped, warn_handler: T.untyped, policy_handlers: T.untyped).returns(T.untyped) }
  def self.check_function!(fn, error_handler, warn_handler: nil, policy_handlers: nil)
    return unless fn.respond_to?(:body) && fn.body
    requires_map = (fn.respond_to?(:requires) ? fn.requires : nil) || {}
    param_names = fn.params.map { |p| p[:name].to_s }.to_set

    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::WithBlock)
      # Observables: WITH VIEW / WITH MATERIALIZED VIEW are reads on
      # an `@observable` source -- not lock acquisitions -- so the
      # LOCKED auto-shim must NOT fire here. The shim's purpose is
      # to bridge pre-Phase-2 lock-using code; observable view blocks
      # are unrelated.
      next if node.view_kind

      bound_params = collect_bound_param_names(node, param_names)

      # True-Sync-Polymorphism (#326): polymorphic-iff rule.
      # WITH POLYMORPHIC is REQUIRED when the bound binding's REQUIRES
      # admits more than one storage axis; REJECTED otherwise. Applies
      # only to plain WITH (the WITH MATCH form has its own per-arm
      # dispatch and is being phased out in #332). VIEW / SNAPSHOT / etc
      # have their own paths that don't go through plain WITH.
      enforce_polymorphic_iff_rule!(node, bound_params, requires_map, fn,
                                    error_handler) unless node.arms

      # True-Sync-Polymorphism (#327): polymorphic-warning surface.
      # For WITH POLYMORPHIC blocks, project the admissible-family
      # error set and warn on errors that no handler covers (per-WITH
      # ON or program SYNC POLICY).
      warn_polymorphic_unhandled_errors!(node, bound_params, requires_map,
                                         policy_handlers, warn_handler) unless node.arms

      # Rule 1: WITH-on-param ⇒ REQUIRES-on-param.
      bound_params.each do |pname|
        next if requires_map.key?(pname)

        # True-Sync-Polymorphism Gate 3: `WITH POLYMORPHIC` on a no-
        # REQUIRES param is universally polymorphic — admits every
        # sync family. Stamp `fn.requires[p] = Set[]` (empty) so the
        # call-site check accepts every caller without falling
        # through to the LOCKED auto-shim. Empty-Set means "no
        # specific family is required", which is what universal
        # polymorphism means. Also stamp the WithBlock so the
        # lowering can route to the comptime-dispatched mutate
        # helper without re-deriving the universal status.
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

        # P2.7: compatibility shim. Pre-Phase-2 source that uses WITH on a
        # parameter without declaring REQUIRES is auto-upgraded to
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
          # Also stamp on fn.requires so downstream readers (P2.6 call-site
          # check, FunctionSignature) see the inferred clause.
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
  end

  # Names of parameters bound by this WITH (i.e., the original variable
  # name, not the AS alias). Walks the capabilities list; for each
  # capability whose var_node is an Identifier referencing a param, add
  # the name. Field accesses (`pool.field`) and non-param locals are
  # skipped — they don't need REQUIRES.
  sig { params(with_node: T.untyped, param_names: T.untyped).returns(Set) }
  def self.collect_bound_param_names(with_node, param_names)
    out = Set.new
    (with_node.capabilities || []).each do |cap|
      vn = cap[:var_node]
      next unless vn.is_a?(AST::Identifier)
      out << vn.name if param_names.include?(vn.name)
    end
    out
  end

  # True-Sync-Polymorphism (#326). Per-WITH polymorphic-iff rule:
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
  # The check only runs for plain WITH (skipped for WITH MATCH, VIEW,
  # MATERIALIZED VIEW, SNAPSHOT — those have their own dispatch shapes;
  # WITH MATCH itself is being phased out in #332 in favor of POLYMORPHIC).
  sig { params(node: T.untyped, bound_params: T.untyped, requires_map: T.untyped, fn: T.untyped, error_handler: T.untyped).returns(T.untyped) }
  def self.enforce_polymorphic_iff_rule!(node, bound_params, requires_map,
                                         fn, error_handler)
    return if node.view_kind || node.snapshot_mode

    has_poly_param = bound_params.any? { |p| poly_requires?(requires_map[p]) }

    # True-Sync-Polymorphism Gate 3: a parameter with NO REQUIRES is
    # universally polymorphic — it admits every sync family. Treat
    # this case as `has_poly_param` for the WITH POLYMORPHIC branch
    # (so the unified `tick!(c: Counter)` body is accepted), but
    # leave the plain-WITH branch alone so the legacy LOCKED
    # auto-shim path (no REQUIRES + plain WITH) keeps working.
    has_universal_poly_param = bound_params.any? { |p|
      !requires_map.key?(p) || (requires_map[p] && requires_map[p].empty?)
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
      example_fams = (requires_map[example] || Set.new).to_a.join(' | ')
      error_handler.call(node,
        "Plain WITH on the polymorphic parameter '#{example}' " \
        "(REQUIRES admits #{example_fams}) is not allowed. " \
        "Use `WITH POLYMORPHIC ...` so the body's polymorphism is visible " \
        "at the use site (the comptime dispatch lowers per family). " \
        "If you want to commit to a single family, narrow REQUIRES to one " \
        "of: VERSIONED, ATOMIC.")
    end
  end

  # P2.6: at every FuncCall in `fn`, verify each REQUIRES'd arg's binding
  # belongs to one of the families in the callee's disjunction.
  #
  # @param fn [AST::FunctionDef]
  # @param sig_lookup [Proc] name → FunctionSignature (or nil)
  # @param error_handler [Proc] (node, msg) → raises CompilerError
  sig { params(fn: T.untyped, sig_lookup: T.untyped, error_handler: T.untyped).returns(T.untyped) }
  def self.check_call_sites!(fn, sig_lookup, error_handler)
    return unless fn.respond_to?(:body) && fn.body

    # True-Sync-Polymorphism Gate 3: walk every FuncCall in the body
    # (including those nested in expressions like `tick!(c) OR EXIT`)
    # and stamp poly_borrow_target on plain-T args bound to universal-
    # poly params. The symbol flag flows to lower_var_decl, which
    # forces Zig `var` so &c yields *T (not *const T) -- otherwise the
    # polymorphicMutate body's mutation can't write back through the
    # pointer.
    deep_funcalls(fn.body).each do |call_node|
      sig = sig_lookup.call(call_node.name.to_s)
      next unless sig.is_a?(FunctionSignature) && sig.requires
      sig.params.each_with_index do |param, idx|
        pname = (param[:name] || param["name"]).to_s
        fams = sig.requires[pname]
        next unless fams && fams.empty?
        arg = (call_node.args || [])[idx]
        next unless arg.is_a?(AST::Identifier)
        sym = arg.symbol
        next unless sym
        next if sym.sync || sym.storage == :shared || sym.storage == :multiowned ||
                sym.storage == :local || sym.storage == :heap
        next unless sym.respond_to?(:mutable) && sym.mutable
        sym.poly_borrow_target = true if sym.respond_to?(:poly_borrow_target=)
      end
    end

    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::FuncCall) && node.respond_to?(:name)
      sig = sig_lookup.call(node.name.to_s)
      next unless sig.is_a?(FunctionSignature)
      next unless sig.requires && !sig.requires.empty?

      sig.params.each_with_index do |param, idx|
        param_name = param[:name].to_s
        disjunction = sig.requires[param_name]
        next unless disjunction && !disjunction.empty?

        arg = node.args[idx]
        next unless arg

        arg_family = family_of_arg(arg)
        if arg_family.nil?
          error_handler.call(node,
            "Call to '#{node.name}' requires parameter '#{param_name}' to be " \
            "bound under one of: #{disjunction.to_a.join(' | ')}. " \
            "The argument here is bound without sync, which belongs to no " \
            "family. Add a sync wrapper at the binding declaration " \
            "(e.g., '@locked' or '@shared:locked').")
        elsif !disjunction_admits?(disjunction, arg_family)
          error_handler.call(node,
            "Call to '#{node.name}' requires parameter '#{param_name}' to be " \
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
  # ACTOR / LOCK_FREE remain reserved for future phases.
  LOCKED_SYNCS    = %i[locked write_locked always_mutable].to_set.freeze
  VERSIONED_SYNCS = %i[versioned].to_set.freeze
  ATOMIC_SYNCS    = %i[atomic].to_set.freeze

  sig { params(arg: T.untyped).returns(T.nilable(Symbol)) }
  def self.family_of_arg(arg)
    sym = arg.symbol
    return nil unless sym
    return :LOCKED    if LOCKED_SYNCS.include?(sym.sync)
    return :VERSIONED if VERSIONED_SYNCS.include?(sym.sync)
    return :ATOMIC    if ATOMIC_SYNCS.include?(sym.sync)
    # #336: non-sync bindings (plain T, @local, @multiowned) are all
    # in the LOCAL family. The body lowers to direct alias access at
    # comptime via the no-op WITH POLYMORPHIC path.
    #   - @local       -> sym.sync == :local
    #   - @multiowned  -> sym.storage == :multiowned (sync nil)
    #   - plain T      -> sym.sync nil + storage stack/heap (no shared)
    return :LOCAL if sym.sync == :local
    return :LOCAL if sym.sync.nil? && sym.storage == :multiowned
    return :LOCAL if sym.sync.nil? && (sym.storage.nil? ||
                                       sym.storage == :stack ||
                                       sym.storage == :heap)
    nil
  end

  # True-Sync-Polymorphism (#326): does the REQUIRES disjunction admit
  # this concrete arg-family? SNAPSHOTTED is the umbrella family that
  # admits {VERSIONED, ATOMIC}; LOCKED admits :LOCKED at the family
  # level (the storage-axis split between :locked / :write_locked is
  # below the family abstraction). Other families are exact-match.
  sig { params(disjunction: T.untyped, arg_family: T.untyped).returns(T::Boolean) }
  def self.disjunction_admits?(disjunction, arg_family)
    (disjunction || []).any? { |f|
      next true if f == arg_family
      next true if f == :SNAPSHOTTED && (arg_family == :VERSIONED || arg_family == :ATOMIC)
      false
    }
  end

  # Atomics M1.6.5 + #326: return the SET of families an arg's binding
  # could be in.
  # For a concrete @shared:atomic / :locked / :versioned binding, returns a
  # singleton set ({:ATOMIC} / {:LOCKED} / {:VERSIONED}).
  # For a parameter constrained by a multi-family REQUIRES disjunction
  # (REQUIRES p: ATOMIC | LOCKED), returns the disjunction Set so call-site
  # effect resolution can keep ?-form alive when the polymorphism propagates.
  # SNAPSHOTTED in sync_families is expanded to {VERSIONED, ATOMIC} so
  # downstream readers (effect resolution, mir lowering) see concrete
  # families uniformly.
  # Returns an empty Set when the arg has no sync attribute (no contention).
  sig { params(arg: T.untyped).returns(T.untyped) }
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

  sig { params(family_set: T.untyped).returns(Set) }
  def self.expand_snapshotted(family_set)
    return family_set unless family_set.include?(:SNAPSHOTTED)
    out = family_set - [:SNAPSHOTTED]
    out << :VERSIONED << :ATOMIC
    out
  end

  # True-Sync-Polymorphism (#327): per-storage-axis error projection.
  # Each axis can surface a fixed set of errors at the WITH boundary.
  # Used by the polymorphic-warning surface (errors_for_polymorphic_with)
  # and by future call-site error collapsing (#329).
  AXIS_ERRORS = {
    locked:        Set[:LockTimeout].freeze,
    write_locked:  Set[:LockTimeout].freeze,
    versioned:     Set[:MvccConflict].freeze,
    atomic:        Set[:AtomicConflict].freeze,
  }.freeze

  # Compute the union of errors that COULD fire from a polymorphic WITH
  # given the binding's REQUIRES disjunction. Deadlock/LockCycle are
  # NOT included here -- those are surfaced via the static cycle
  # detector (lock_helper.rb) when a cycle is reachable, and they are
  # always inline-only (never defaulted by SYNC POLICY).
  sig { params(family_set: T.untyped).returns(Set) }
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
  sig { params(node: T.untyped, bound_params: T.untyped, requires_map: T.untyped, policy_handlers: T.untyped, warn_handler: T.untyped).returns(T.nilable(Set)) }
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
  # or the program-level SYNC POLICY. Both forms carry a `:selectors`
  # array of `{ form: :type | :kind, name: Symbol }` entries; type
  # selectors contribute their literal name, kind selectors expand
  # via AST.types_for_kind.
  sig { params(node: T.untyped, policy_handlers: T.untyped).returns(Set) }
  def self.handled_error_set(node, policy_handlers)
    handled = Set.new
    [node.lock_error_clause, *(policy_handlers || [])].compact.each do |clause|
      (clause[:selectors] || []).each do |sel|
        case sel[:form]
        when :type
          handled << sel[:name]
        when :kind
          AST.types_for_kind(sel[:name]).each { |t| handled << t }
        end
      end
    end
    handled
  end

  # Iterative deep walk that returns every FuncCall in `body`, including
  # those nested inside expressions (e.g. `tick!(c) OR EXIT`, where the
  # FuncCall is the LHS of a BinaryOp). AST.walk_body only iterates
  # statement-level nodes; we need the expression sub-tree too for
  # the universal-poly auto-borrow stamp.
  sig { params(body: T.untyped).returns(Array) }
  def self.deep_funcalls(body)
    out = []
    stack = body.is_a?(Array) ? body.dup : [body]
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(AST::Locatable)
      out << node if node.is_a?(AST::FuncCall)
      next if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit)
      node.class.members.each do |m|
        v = node[m]
        if v.is_a?(Array)
          v.each { |c| stack.push(c) if c.is_a?(AST::Locatable) }
        elsif v.is_a?(AST::Locatable)
          stack.push(v)
        end
      end
    end
    out
  end
end
