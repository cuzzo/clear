# typed: strict
require "sorbet-runtime"

# Retained-identity v5 ownership-edge planner (design "Lowering requirements"
# + Operation table). Selects the physical ownership operation for a fan-out
# edge from the source's declared carrier, the fan-out op the author chose, and
# whether the callee param is UNIQUE.
#
# SCOPE (not the single ownership writer -- that claim was false):
#   - This planner is invoked only on the KEEP path (lifetimes.rb), and its
#     carrier_op is consumed only by KeepNode lowering (lower_clone), for the
#     :monomorphic_keep / :deferred_specialization results.
#   - KEPT-IDENTITY edges (param.symbol.kept_identity) are planned by the v4
#     machinery, EscapeAnalysis.apply_kept_identity_placement! (CallEdgeOwnership
#     Plan), and lowering consumes THAT on those edges (functions.rb
#     lower_kept_identity_arg, which returns first). The two are disjoint by the
#     kept_identity partition, reconciled by deferred_validation.rb's kept-edge
#     exception. Verified DISJOINT (not conflicting): a merge is NOT required.
#   - COPY carrier_ops are written directly (function_analysis.rb OWN COPY,
#     lifetimes.rb plain COPY), bypassing this planner, pending Phase 6b.
#
# Carrier preservation is the whole point: a plain payload is moved or copied,
# NEVER wrapped into an Rc (the v4 normalization this design replaces). Rc and
# Arc are distinct families; the planner never converts one to the other.
#
# The seven ops:
#   :payload_move          - plain, final consuming use: move the value
#   :rc_handle_move        - @multiowned, final use: move the Rc handle bits
#   :arc_handle_move       - @shared, final use: move the Arc handle bits
#   :payload_copy          - plain KEEP/COPY: independent payload copy
#   :rc_retain             - @multiowned KEEP: non-atomic refcount +1
#   :arc_retain            - @shared KEEP: atomic refcount +1
#   :shared_to_unique_copy - COPY of a retained carrier at a UNIQUE boundary:
#                            an explicit payload copy that detaches identity
module OwnershipEdgePlanner
  extend T::Sig

  # A carrier can be :plain, :multiowned (Rc), or :shared (Arc). A
  # carrier-polymorphic parameter's carrier is not statically known; that
  # edge is resolved per carrier specialization (Phase 4), not here.
  CARRIERS = T.let([:plain, :multiowned, :shared].freeze, T::Array[Symbol])
  # A fan-out is :move (the final consuming use; no explicit operator),
  # :keep (KEEP), or :copy (COPY).
  FAN_OUTS = T.let([:move, :keep, :copy].freeze, T::Array[Symbol])

  class Plan < T::Struct
    const :op, T.nilable(Symbol)
    const :error_kind, T.nilable(Symbol), default: nil
  end

  sig do
    params(source_carrier: Symbol, fan_out: Symbol, at_unique_boundary: T::Boolean)
      .returns(Plan)
  end
  def self.select(source_carrier:, fan_out:, at_unique_boundary: false)
    unless CARRIERS.include?(source_carrier)
      raise ArgumentError, "unknown source carrier #{source_carrier.inspect}"
    end
    unless FAN_OUTS.include?(fan_out)
      raise ArgumentError, "unknown fan-out #{fan_out.inspect}"
    end

    case fan_out
    when :move
      Plan.new(op: OwnershipEdgePlanner.move_op(source_carrier))
    when :keep
      Plan.new(op: OwnershipEdgePlanner.keep_op(source_carrier))
    else
      OwnershipEdgePlanner.select_copy(source_carrier, at_unique_boundary)
    end
  end

  sig { params(source_carrier: Symbol).returns(Symbol) }
  def self.move_op(source_carrier)
    return :payload_move if source_carrier == :plain
    return :rc_handle_move if source_carrier == :multiowned

    :arc_handle_move
  end

  sig { params(source_carrier: Symbol).returns(Symbol) }
  def self.keep_op(source_carrier)
    return :payload_copy if source_carrier == :plain
    return :rc_retain if source_carrier == :multiowned

    :arc_retain
  end

  # A final consuming use moves whatever the carrier is -- no copy, no retain.
  MOVE_OPS = T.let({
    plain: :payload_move,
    multiowned: :rc_handle_move,
    shared: :arc_handle_move,
  }.freeze, T::Hash[Symbol, Symbol])

  # KEEP preserves the carrier: copy a plain payload, retain a handle.
  KEEP_OPS = T.let({
    plain: :payload_copy,
    multiowned: :rc_retain,
    shared: :arc_retain,
  }.freeze, T::Hash[Symbol, Symbol])

  sig { params(source_carrier: Symbol, at_unique_boundary: T::Boolean).returns(Plan) }
  def self.select_copy(source_carrier, at_unique_boundary)
    # COPY of a plain value is an ordinary payload copy.
    return Plan.new(op: :payload_copy) if source_carrier == :plain

    # COPY of a retained carrier (@multiowned/@shared) is only legal as an
    # explicit conversion at a UNIQUE parameter boundary (design "Parameter
    # contracts" / rule "COPY is not allowed on an unconstrained carrier").
    return Plan.new(op: :shared_to_unique_copy) if at_unique_boundary

    Plan.new(op: nil, error_kind: :copy_needs_unique_boundary)
  end
end
