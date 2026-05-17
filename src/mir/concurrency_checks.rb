# typed: strict
# frozen_string_literal: true

# Compile-time correctness checks for concurrent CLEAR programs.
#
# Runs after EffectInference.analyze! has stamped fn.effect_set, so
# transitive yield/io/fail/alloc effects are visible.
#
# The checks:
#
#   Hold-lock-across-yield        — refuse :yield inside any WITH body
#   Naked nested WITH             — refuse nested WITH on differing parameters
#                                   and suggest the multi-resource form
#   Compile-time reentrant lock   — refuse calls into callees whose REQUIRES
#                                   names a parameter that aliases a held lock
#   FAST_PATH constraint          — author-written `! fast_path` is violated
#                                   by any blocking effect
#
# The checks share a `walk_scope_no_nested_with` helper: descend into a
# WithBlock body or arm, but skip nested WithBlocks (those bubble their
# own diagnostics). Nodes inside lambdas / nested function defs are
# similarly ignored — they're separate scopes.
module ConcurrencyChecks
  extend T::Sig
  module_function

  # Run every check. Each fn is independent.
  # `lock_ranks` is a Hash {type_sym => rank}; bindings whose declared
  # type appears here participate in the rank-DAG protocol; the rank-cycle
  # analysis owns ordering for those bindings.
  sig { params(fn_nodes: T.untyped, sig_lookup: T.untyped, error_handler: T.untyped, lock_ranks: T.untyped).void }
  def check_all!(fn_nodes, sig_lookup, error_handler, lock_ranks: {})
    fn_nodes.each_value do |fn|
      next unless fn&.body
      check_hold_across_yield!(fn, fn_nodes, error_handler)
      check_naked_nested_with!(fn, error_handler, lock_ranks)
      check_reentrant!(fn, sig_lookup, error_handler)
    end
  end

  # A WITH body must not contain any node that yields. The walker
  # is purely structural — it has to find nodes by their LOCATION inside
  # this WITH body. The yield property itself is read from the existing
  # annotator-stamped effect set (fn.effects, populated by record_effect
  # at visit_BgBlock / visit_NextExpr and propagated by compute_effects!).
  sig { params(fn: T.untyped, fn_nodes: T.untyped, error_handler: T.untyped).void }
  def check_hold_across_yield!(fn, fn_nodes, error_handler)
    walk_with_blocks(fn.body) do |with_block, scope|
      walk_scope_no_nested_with(scope) do |node|
        offender_token = nil
        reason = nil

        case node
        when AST::BgBlock
          offender_token = node.token
          reason = "BG"
        when AST::NextExpr
          offender_token = node.token
          reason = "NEXT"
        when AST::FuncCall
          callee = fn_nodes[node.name.to_s]
          if callee&.effects&.include?(EffectTracker::YIELD)
            offender_token = node.token
            reason = "call to '#{node.name}' which yields"
          end
        end

        next unless offender_token

        error_handler.call(with_block,
          "Hold-lock-across-yield: #{reason} at line " \
          "#{offender_token.line} executes inside the WITH at line " \
          "#{with_block.token&.line}, while a lock is held. " \
          "Move the suspending operation outside the WITH, or restructure " \
          "so the lock is released before suspension.")
      end
    end
  end

  # Refuse `WITH x { WITH y { ... } }` (different parameter) when
  # BOTH the outer and inner block acquire actual locks. Borrow-only
  # variants (BORROWED, RESTRICT) don't hold a lock; nesting them is
  # safe. Same-binding nesting is permitted (still useful for re-entry
  # checks; reentrant detection covers the dangerous case).
  LOCK_HOLDING_CAPABILITIES = T.let(%i[EXCLUSIVE write_locked_read infer].to_set.freeze, T::Set[Symbol])

  sig { params(fn: T.untyped, error_handler: T.untyped, lock_ranks: T.untyped).void }
  def check_naked_nested_with!(fn, error_handler, lock_ranks = {})
    walk_with_blocks(fn.body) do |outer, outer_scope|
      outer_lock_names = lock_holding_names(outer)
      next if outer_lock_names.empty?
      # @locked(rank: N) bindings opt into the rank-DAG analysis, which is a
      # stronger ordering guarantee than this pattern check.
      next if any_lock_rank?(outer, lock_ranks)

      walk_scope_for_nested_with(outer_scope) do |inner|
        inner_lock_names = lock_holding_names(inner)
        next if inner_lock_names.empty?
        # Same opt-out applies if the inner block uses ranks.
        next if any_lock_rank?(inner, lock_ranks)

        # Re-entry on the same binding is permitted; reentrant detection flags
        # the unsafe case.
        names = inner_lock_names - outer_lock_names
        next if names.empty?

        suggested_names = (outer_lock_names + names).to_a
        error_handler.call(inner,
          "Naked nested WITH on a different binding (#{names.to_a.join(', ')}) " \
          "while #{outer_lock_names.to_a.join(', ')} is held — symmetric " \
          "callers may deadlock. Use the multi-resource form for safe " \
          "ordering:\n" \
          "    WITH EXCLUSIVE #{suggested_names.join(', ')} " \
          "AS (#{suggested_names.map { |n| 'i_' + n }.join(', ')}) { ... }")
      end
    end
  end

  # Any binding in this WithBlock that carries an @locked(rank: N) /
  # @writeLocked(rank: N) annotation. The rank-DAG check owns ordering
  # correctness for ranked locks.
  # `lock_ranks` is the annotator-built type-rank registry.
  sig { params(with_block: T.untyped, lock_ranks: T.untyped).returns(T::Boolean) }
  def any_lock_rank?(with_block, lock_ranks)
    return false if lock_ranks.empty?
    (with_block.capabilities || []).any? do |cap|
      ti = cap[:resolved_type]
      next false unless ti && ti.respond_to?(:base_type)
      lock_ranks.key?(ti.base_type)
    end
  end

  # Names of bindings that the WithBlock acquires a LOCK on (vs.
  # borrow-only captures).
  sig { params(with_block: T.untyped).returns(T::Set[T.untyped]) }
  def lock_holding_names(with_block)
    out = Set.new
    (with_block.capabilities || []).each do |cap|
      next unless LOCK_HOLDING_CAPABILITIES.include?(cap[:capability])
      n = cap_var_name(cap[:var_node])
      out << n if n
    end
    out
  end

  # For each WITH on parameter `p`, any call inside whose callee has REQUIRES
  # naming a parameter aliasing `p` reacquires `p`'s lock.
  sig { params(fn: T.untyped, sig_lookup: T.untyped, error_handler: T.untyped).returns(T.untyped) }
  def check_reentrant!(fn, sig_lookup, error_handler)
    walk_with_blocks(fn.body) do |with_block, scope|
      held_params = collect_held_params(with_block, fn)
      next if held_params.empty?

      walk_scope_no_nested_with(scope) do |node|
        next unless node.is_a?(AST::FuncCall) && node.respond_to?(:name)
        sig = sig_lookup.call(node.name.to_s)
        next unless sig.is_a?(FunctionSignature) && sig.requires && !sig.requires.empty?

        sig.params.each_with_index do |param, idx|
          pname = param[:name].to_s
          next unless sig.requires.key?(pname)
          arg = node.args[idx]
          next unless arg
          arg_name = arg.respond_to?(:name) ? arg.name : nil
          next unless arg_name && held_params.include?(arg_name)

          error_handler.call(node,
            "Reentrant lock acquisition: '#{node.name}' has REQUIRES " \
            "'#{pname}: #{sig.requires[pname].to_a.join(' | ')}' and is " \
            "called with '#{arg_name}', which is already held by the WITH " \
            "at line #{with_block.token&.line}. Pass the unwrapped inner " \
            "alias instead of the wrapped binding.")
        end
      end
    end
  end

  # ── Internal helpers ────────────────────────────────────────────────────

  # Yield each WithBlock found in `body` along with the "scope" to scan
  # for in-scope statements. The scope is:
  #   - the WithBlock's body (legacy single-form), or
  #   - each arm's body (MATCH form). For MATCH, yields one tuple per arm.
  sig { params(body: T.untyped, blk: T.untyped).returns(T.untyped) }
  def walk_with_blocks(body, &blk)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::WithBlock)
      if node.arms
        node.arms.each { |arm| yield(node, arm[:body]) }
      else
        yield(node, node.body)
      end
    end
  end

  # Walk a WithBlock's scope. Descend into IF/WHILE/FOR/ etc., but stop
  # at nested WithBlocks (they own their own checks) and lambdas.
  sig { params(stmts: T.untyped, blk: T.untyped).returns(NilClass) }
  def walk_scope_no_nested_with(stmts, &blk)
    stack = stmts.is_a?(Array) ? stmts.dup : [stmts]
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(AST::Locatable)
      yield(node)
      next if node.is_a?(AST::WithBlock)        # let it bubble its own
      next if node.is_a?(AST::LambdaLit)        # separate scope
      next if node.is_a?(AST::FunctionDef)      # separate scope (rare)
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

  # Find nested WithBlocks within a scope (no recursion into them; we
  # only care about the topmost nested one per branch).
  sig { params(stmts: T.untyped, blk: T.untyped).returns(NilClass) }
  def walk_scope_for_nested_with(stmts, &blk)
    walk_scope_no_nested_with(stmts) do |node|
      yield(node) if node.is_a?(AST::WithBlock)
    end
  end

  # Names of function parameters held by a WithBlock's bindings.
  sig { params(with_block: T.untyped, fn: T.untyped).returns(T::Set[T.untyped]) }
  def collect_held_params(with_block, fn)
    return Set.new unless fn.respond_to?(:params)
    param_names = fn.params.map { |p| p[:name].to_s }.to_set
    out = Set.new
    (with_block.capabilities || []).each do |cap|
      n = cap_var_name(cap[:var_node])
      out << n if n && param_names.include?(n)
    end
    out
  end

  sig { params(var_node: T.untyped).returns(T.untyped) }
  def cap_var_name(var_node)
    var_node.is_a?(AST::Identifier) ? var_node.name : nil
  end
end
