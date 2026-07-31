# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "type"

# Retained identity v4 (docs/agents/retained-identity-design.md).
#
# KeptIdentityContract is the retained-parameter fact: which ownership
# family the sink demands and which sink created the keep. Stamped on the
# param's SymbolEntry by keep-analysis; consumed by signature lowering
# (handle ABI) and edge planning. Never a bare boolean: the family is what
# downstream code dispatches on, and the sink names the keeper in
# declaration-sited diagnostics.
class KeptIdentityContract < T::Struct
  extend T::Sig

  # :multiowned (Rc) today; :shared (Arc) and :value (independent copy)
  # are reserved for the B/C phases of the design.
  const :family, Symbol
  const :sink, String

  sig { returns(T::Boolean) }
  def rc? = family == :multiowned
end

# One call edge's ownership decision, produced by placement (the single
# writer, which sees the caller's declared model, the callee's contract,
# and caller liveness) and consumed by MIR lowering without re-derivation.
#
# op is exactly one of:
#   :retain_handle     - live Rc source; the edge retains (+1)
#   :move_handle       - last use or GIVE; the handle bits move
#   :move_payload_wrap - owned payload expression; move it and rcCreate
#   :copy_wrap         - COPY override; deep-copy payload and rcCreate
#   :pass_null         - omitted/NIL optional edge
class CallEdgeOwnershipPlan < T::Struct
  const :op, Symbol
  const :family, Symbol
end


module AST
  StructKwargs = T.type_alias { BasicObject }

  # ruby-to-clear: pub
  Param = Struct.new(:name, :type, :default, :mutable, :takes,
                     :comptime, :name_token, :required, :sync, :symbol,
                     :carrier_contract,
                     keyword_init: true) do
    extend T::Sig

    # Ruby Struct members default to nil, while Sorbet cannot attach a type to
    # the generated readers. Keep the self-hosted record faithful to that
    # contract instead of collapsing these boolean fields to Any.
    # ruby-to-clear: field-type mutable=?Bool
    # ruby-to-clear: field-type takes=?Bool
    # ruby-to-clear: field-type comptime=?Bool
    # ruby-to-clear: field-type required=?Bool

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      t = T.let(self[:type], T.nilable(Type::TypeInput))
      self[:type] = Type.new(t || Type.type_input_symbol_or_any(nil))
      # Retained-identity v5 parameter carrier contract: :polymorphic
      # (default, carrier-preserving), :unique (exclusively owned), :shared
      # (requires a retained-identity family).
      contract = T.let(self[:carrier_contract], T.nilable(Symbol))
      self[:carrier_contract] = contract || :polymorphic
    end

    # Mirror of Type#atomic? (Param has :sync but no :layout, so no
    # indirect?/atomic_ptr?).
    sig { returns(T::Boolean) }
    def atomic? = sync == :atomic

    sig { returns(Type) }
    # ruby-to-clear: pub
    def type
      self[:type]
    end

    sig { params(val: T.nilable(Type::TypeInput)).void }
    def type=(val)
      self[:type] = Type.new(val || Type.type_input_symbol_or_any(nil))
    end
  end
end
