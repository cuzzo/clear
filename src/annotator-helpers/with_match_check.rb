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
  def self.check_function!(fn, error_handler, warn_handler: nil)
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

      # Rule 1: WITH-on-param ⇒ REQUIRES-on-param.
      bound_params.each do |pname|
        next if requires_map.key?(pname)

        # P2.7: compatibility shim. Pre-Phase-2 source that uses WITH on a
        # parameter without declaring REQUIRES is auto-upgraded to
        # `REQUIRES <pname>: LOCKED`. A deprecation note surfaces so the
        # migration is visible. The shim will be removed in a future release.
        if warn_handler
          warn_handler.call(node,
            "WITH at line #{node.token&.line} uses parameter '#{pname}' " \
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
            "WITH at line #{node.token&.line} uses parameter '#{pname}', " \
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
          "WITH MATCH at line #{node.token&.line} is missing a WHEN arm for " \
          "#{fam} (declared in REQUIRES). Add an arm:\n" \
          "    WHEN #{fam}\n" \
          "        -> { <body for #{fam} strategy> }")
      end

      extra.each do |fam|
        error_handler.call(node,
          "WITH MATCH at line #{node.token&.line} has a WHEN arm for #{fam}, " \
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
  def self.collect_bound_param_names(with_node, param_names)
    out = Set.new
    (with_node.capabilities || []).each do |cap|
      vn = cap[:var_node]
      next unless vn.is_a?(AST::Identifier)
      out << vn.name if param_names.include?(vn.name)
    end
    out
  end

  # P2.6: at every FuncCall in `fn`, verify each REQUIRES'd arg's binding
  # belongs to one of the families in the callee's disjunction.
  #
  # @param fn [AST::FunctionDef]
  # @param sig_lookup [Proc] name → FunctionSignature (or nil)
  # @param error_handler [Proc] (node, msg) → raises CompilerError
  def self.check_call_sites!(fn, sig_lookup, error_handler)
    return unless fn.respond_to?(:body) && fn.body
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
        elsif !disjunction.include?(arg_family)
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

  def self.family_of_arg(arg)
    sym = arg.respond_to?(:symbol) ? arg.symbol : nil
    return nil unless sym
    return :LOCKED    if LOCKED_SYNCS.include?(sym.sync)
    return :VERSIONED if VERSIONED_SYNCS.include?(sym.sync)
    return :ATOMIC    if ATOMIC_SYNCS.include?(sym.sync)
    nil
  end

  # Atomics M1.6.5: return the SET of families an arg's binding could be in.
  # For a concrete @shared:atomic / :locked / :versioned binding, returns a
  # singleton set ({:ATOMIC} / {:LOCKED} / {:VERSIONED}).
  # For a parameter constrained by a multi-family REQUIRES disjunction
  # (REQUIRES p: ATOMIC | LOCKED), returns the disjunction Set so call-site
  # effect resolution can keep ?-form alive when the polymorphism propagates.
  # Returns an empty Set when the arg has no sync attribute (no contention).
  def self.family_of_arg_set(arg)
    sym = arg.respond_to?(:symbol) ? arg.symbol : nil
    return Set.new unless sym
    if sym.sync_families && sym.sync_families.size > 1
      return sym.sync_families
    end
    fam = family_of_arg(arg)
    fam ? Set[fam] : Set.new
  end
end
