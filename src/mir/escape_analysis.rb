# typed: strict
# Cross-module sync propagation: flows caller arg sync (and Arc-
# storage) into callee param SymbolEntries (Group-1 capability
# propagation). Escape/heap-ownership analysis moved to escape_graph.rb.

require "sorbet-runtime"

require_relative "../ast/type"
require_relative "../ast/ast"

module EscapeAnalysis
    extend T::Sig


  # E3c: Propagate caller arg sync (and Arc-storage) into callee param
  # SymbolEntry. Two axes flow with the same all-callers-agree rule:
  #   - sync     (:locked / :write_locked / :always_mutable)
  #   - storage  (:shared / :multiowned for Arc/Rc-wrapped bindings)
  # The storage axis is what mir_lowering needs to emit Arc unwrap
  # (`x.ctrl.data.*` vs `x`) at WITH/field-access sites. Sync drives the
  # acquire/release method choice. Runs to fixed point so transitive calls
  # also pick up both axes.
  #
  # Rule: a param with no caller-derived value (and no explicit declared
  # value) adopts a caller's value iff every observed caller passes the
  # same non-nil value. Disagreement leaves the param at its current
  # value. Params with declared sync (legacy) are not overwritten.
  #
  # @param fn_nodes [Hash]  name -> AST::FunctionDef
  sig { params(fn_nodes: T::Hash[String, T.untyped]).void }
  def self.propagate_caller_sync!(fn_nodes)
    return if fn_nodes.empty?

    # Index callsites: callee_name => [{ args: }, ...].
    # AST.walk_body only visits top-level statements, not expression
    # sub-trees, so a `let x = foo(...)` would miss the FuncCall. Walk
    # every Locatable descendant.
    callsites = Hash.new { |h, k| h[k] = [] }
    fn_nodes.each do |_, caller_fn|
      next unless caller_fn&.body
      collect_callsites_deep(caller_fn.body, callsites)
    end

    max_iters = 8
    max_iters.times do
      changed = T.let(false, T::Boolean)
      fn_nodes.each do |callee_name, callee_fn|
        next unless callee_fn&.params
        sites = callsites[callee_name]
        next if sites.empty?

        callee_fn.params.each_with_index do |param, idx|
          entry = param.symbol
          next unless entry

          # ── sync axis ────────────────────────────────────────────────
          unless entry.sync && param_sync_was_declared?(param)
            unified = unify_caller_attr(sites, idx) { |s| s&.sync }
            if unified && entry.sync != unified && param_accepts_caller_sync?(callee_fn, param, unified)
              entry.sync = unified
              changed = true
            end
          end

          # ── storage axis (Arc / Rc) ──────────────────────────────────
          # We're trying to detect "this binding is Arc/Rc-wrapped" so
          # the callee's lowering knows to emit `x.ctrl.data.*` unwrap.
          # For struct types, that fact lives on entry.storage (:shared /
          # :multiowned). For collection types, finalize_storage maps
          # @shared:locked + collection to :heap, so the wrapping fact
          # lives on entry.type.ownership instead. Check both axes.
          unified_storage = unify_caller_attr(sites, idx) do |s|
            next s.storage if s&.storage == :shared || s&.storage == :multiowned
            t = s&.type
            if t.is_a?(Type)
              next :shared     if t.respond_to?(:shared?)     && t.shared?
              next :multiowned if t.respond_to?(:multiowned?) && t.multiowned?
            end
            nil
          end
          if unified_storage && entry.storage != unified_storage
            entry.storage = unified_storage
            changed = true
          end
        end
      end
      break unless changed
    end
  end

  # Walk every Locatable descendant (incl. expression sub-trees), record
  # FuncCalls.
  sig { params(body: T::Array[T.untyped], callsites: T::Hash[String, T::Array[T.untyped]]).returns(NilClass) }
  private_class_method def self.collect_callsites_deep(body, callsites)
    stack = body.is_a?(Array) ? body.dup : [body]
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::FuncCall)
        T.must(callsites[node.name.to_s]) << { args: node.args }
      end
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
  end

  # Most-general unifier: returns the single non-nil value when every
  # callsite's arg projects to the same value, else nil.
  sig { params(sites: T::Array[T::Hash[T.untyped, T.untyped]], idx: Integer, project: T.untyped).returns(T.nilable(Symbol)) }
  private_class_method def self.unify_caller_attr(sites, idx, &project)
    observed = sites.map do |site|
      arg = site[:args][idx]
      next nil unless arg && arg.respond_to?(:symbol)
      project.call(arg.symbol)
    end
    return nil if observed.empty?
    unique = observed.uniq
    (unique.length == 1 && unique.first) ? unique.first : nil
  end

  # True when the param's declared type carried explicit sync (so the
  # entry.sync currently reflects an annotation, not a propagated value).
  sig { params(param: AST::Param).returns(T.nilable(T::Boolean)) }
  private_class_method def self.param_sync_was_declared?(param)
    t = param.type
    t.is_a?(Type) && t.any_sync?
  end

  sig { params(fn_node: AST::FunctionDef, param: AST::Param, sync: Symbol).returns(T::Boolean) }
  private_class_method def self.param_accepts_caller_sync?(fn_node, param, sync)
    t = param.type
    return true if t.is_a?(Type) && (t.shared? || t.any_sync?)
    # Sync axes other than :atomic were already accepted above (via shared?
    # / any_sync?) -- only :atomic needs the REQUIRES family check.
    return true unless sync == :atomic

    requires = fn_node.respond_to?(:requires) ? fn_node.requires : nil
    families = requires && requires[param.name.to_s]
    return false unless families.respond_to?(:include?)
    families.include?(:ATOMIC) || families.include?(:SNAPSHOTTED)
  end
end
