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
# The checks consume `FunctionBodySummary#with_scope_nodes`, recorded during
# annotator body analysis. Those facts include each WITH body/arm scope, stop
# at nested WITH bodies, and ignore lambda/function bodies as separate scopes.
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../annotator/phases/body_analysis"
require_relative "capability_plan"

module ConcurrencyChecks
  extend T::Sig
  module_function

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  ErrorHandler = T.type_alias { T.proc.params(node: AST::Locatable, message: String).void }
  SigLookup = T.type_alias { T.proc.params(name: String).returns(T.nilable(T.any(FunctionSignature, Type))) }
  LockRanks = T.type_alias { T::Hash[Symbol, Integer] }
  BodySummaries = T.type_alias { T::Hash[String, Annotator::Phases::FunctionBodySummary] }
  WithScopeNodes = T.type_alias { Annotator::Phases::WithScopeNodes }
  WithScopeBlock = T.type_alias { T.proc.params(with_block: AST::WithBlock, scope: T::Array[AST::Locatable]).void }

  # Run every check. Each fn is independent.
  # `lock_ranks` is a Hash {type_sym => rank}; bindings whose declared
  # type appears here participate in the rank-DAG protocol; the rank-cycle
  # analysis owns ordering for those bindings.
  sig { params(fn_nodes: FnNodes, sig_lookup: SigLookup, error_handler: ErrorHandler, body_summaries: BodySummaries, lock_ranks: LockRanks).void }
  def check_all!(fn_nodes, sig_lookup, error_handler, body_summaries:, lock_ranks: {})
    fn_nodes.each_value do |fn|
      next unless fn&.body
      summary = body_summaries.fetch(fn.name)
      with_blocks = summary.with_blocks
      with_scope_nodes = summary.with_scope_nodes
      check_hold_across_yield!(fn, with_blocks, with_scope_nodes, fn_nodes, error_handler)
      check_naked_nested_with!(with_blocks, with_scope_nodes, error_handler, lock_ranks)
      check_reentrant!(fn, with_blocks, with_scope_nodes, sig_lookup, error_handler)
    end
  end

  # A WITH body must not contain any node that yields. Scope membership comes
  # from annotator body facts; the yield property itself is read from the
  # annotator-stamped effect set.
  sig { params(fn: AST::FunctionDef, with_blocks: T::Array[AST::WithBlock], with_scope_nodes: WithScopeNodes, fn_nodes: FnNodes, error_handler: ErrorHandler).void }
  def check_hold_across_yield!(fn, with_blocks, with_scope_nodes, fn_nodes, error_handler)
    each_with_scope(with_blocks, with_scope_nodes) do |with_block, scope|
      scope.each do |node|
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
  sig { params(with_blocks: T::Array[AST::WithBlock], with_scope_nodes: WithScopeNodes, error_handler: ErrorHandler, lock_ranks: LockRanks).void }
  def check_naked_nested_with!(with_blocks, with_scope_nodes, error_handler, lock_ranks = {})
    each_with_scope(with_blocks, with_scope_nodes) do |outer, outer_scope|
      outer_lock_names = lock_holding_names(outer)
      next if outer_lock_names.empty?
      # @locked(rank: N) bindings opt into the rank-DAG analysis, which is a
      # stronger ordering guarantee than this pattern check.
      next if any_lock_rank?(outer, lock_ranks)

      outer_scope.each do |node|
        next unless node.is_a?(AST::WithBlock)
        inner = node
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
  sig { params(with_block: AST::WithBlock, lock_ranks: LockRanks).returns(T::Boolean) }
  def any_lock_rank?(with_block, lock_ranks)
    return false if lock_ranks.empty?
    CapabilityPlan.require_for(with_block).locks.any? do |cap|
      identity = cap.lock_identity
      identity && lock_ranks.key?(identity)
    end
  end

  # Names of bindings that the WithBlock acquires a LOCK on (vs.
  # borrow-only captures).
  sig { params(with_block: AST::WithBlock).returns(T::Set[String]) }
  def lock_holding_names(with_block)
    out = Set.new
    CapabilityPlan.require_for(with_block).locks.each do |cap|
      out << cap.var_name
    end
    out
  end

  # For each WITH on parameter `p`, any call inside whose callee has REQUIRES
  # naming a parameter aliasing `p` reacquires `p`'s lock.
  sig { params(fn: AST::FunctionDef, with_blocks: T::Array[AST::WithBlock], with_scope_nodes: WithScopeNodes, sig_lookup: SigLookup, error_handler: ErrorHandler).void }
  def check_reentrant!(fn, with_blocks, with_scope_nodes, sig_lookup, error_handler)
    each_with_scope(with_blocks, with_scope_nodes) do |with_block, scope|
      held_params = collect_held_params(with_block, fn)
      next if held_params.empty?

      scope.each do |node|
        next unless node.is_a?(AST::FuncCall) && node.respond_to?(:name)
        sig = FunctionSignature.unwrap(sig_lookup.call(node.name.to_s))
        next unless sig && sig.requires && !sig.requires.empty?

        sig.params.each_with_index do |param, idx|
          pname = param.name.to_s
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

  # Yield each known WithBlock along with the annotated in-scope nodes.
  sig { params(with_blocks: T::Array[AST::WithBlock], with_scope_nodes: WithScopeNodes, blk: WithScopeBlock).void }
  def each_with_scope(with_blocks, with_scope_nodes, &blk)
    with_blocks.each do |node|
      yield(node, with_scope_nodes.fetch(node.object_id))
    end
  end

  # Names of function parameters held by a WithBlock's bindings.
  sig { params(with_block: T.untyped, fn: T.untyped).returns(T::Set[String]) }
  def collect_held_params(with_block, fn)
    return Set.new unless fn.respond_to?(:params)
    param_names = fn.params.map { |p| p.name.to_s }.to_set
    out = Set.new
    CapabilityPlan.require_for(with_block).locks.each do |cap|
      n = cap.var_name
      out << n if param_names.include?(n)
    end
    out
  end

  private :check_naked_nested_with!,
    :check_reentrant!
  private_class_method :check_naked_nested_with!,
    :check_reentrant!
  private :any_lock_rank?
  private :check_hold_across_yield!
  private :collect_held_params
  private :lock_holding_names
  private_class_method :any_lock_rank?
  private_class_method :check_hold_across_yield!
  private_class_method :collect_held_params
  private_class_method :lock_holding_names

end
