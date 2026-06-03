# typed: strict
# Strongly-typed representation of a function's return.
#
# Replaces the untyped `return_type` union (Type | Symbol | nil |
# Proc | Hash) and the std_lib `return_type: ->(recv){...}` Procs.
# Every return is one of a closed set of variants; `resolve` always
# yields a concrete non-nil Type. No Proc, no Hash, no nil.
#
#   Fixed              -> a concrete Type (covers all static returns,
#                         incl. {type:,sync:} -> Type.new with caps,
#                         and the implicit-Void case)
#   ElementOf          -> receiver.element_type
#   OptionalOfElement  -> ?element_type
#   IdOfElement        -> Id<element_type>
#   OptionalOfValue    -> ?value_type
#   ValueList          -> value_type[]@list
#   KeyList            -> key_type[]@list
#   Infer              -> a host inference method (bounded Symbol set:
#                         infer_element_type / infer_optional_element_type
#                         / infer_map_return_type) -- a typed variant,
#                         not a Proc; resolve dispatches via the host.
require "sorbet-runtime"
require_relative "../../ast/type"

class FunctionReturn
  extend T::Sig

  class Kind < T::Enum
    enums do
      Fixed             = new("fixed")
      ElementOf         = new("element_of")
      OptionalOfElement = new("optional_of_element")
      IdOfElement       = new("id_of_element")
      OptionalOfValue   = new("optional_of_value")
      ValueList         = new("value_list")
      KeyList           = new("key_list")
      Infer             = new("infer")
    end
  end

  sig { returns(Kind) }
  attr_reader :kind
  sig { returns(T.nilable(Type)) }
  attr_reader :fixed
  sig { returns(T.nilable(Symbol)) }
  attr_reader :infer

  sig { params(kind: Kind, fixed: T.nilable(Type), infer: T.nilable(Symbol)).void }
  def initialize(kind:, fixed: nil, infer: nil)
    @kind = kind
    @fixed = fixed
    @infer = infer
  end

  sig { params(t: Type).returns(FunctionReturn) }
  def self.fixed(t) = new(kind: Kind::Fixed, fixed: t)

  sig { params(m: Symbol).returns(FunctionReturn) }
  def self.infer(m) = new(kind: Kind::Infer, infer: m)

  # Single source for "is this the Fixed (concrete-Type) variant".
  # Was reinvented inline as `kind == FunctionReturn::Kind::Fixed`
  # (decomplex Reification-Miss: function_signature#fixed_return?,
  # intrinsic_registry#to_return_type).
  sig { returns(T::Boolean) }
  def fixed? = kind == Kind::Fixed

  # A receiver-parametric variant (ElementOf / OptionalOfElement /
  # IdOfElement / OptionalOfValue / ValueList / KeyList) by Kind
  # constant name. No payload -- the Type is computed from the
  # receiver at resolve time.
  sig { params(kind_name: Symbol).returns(FunctionReturn) }
  def self.variant(kind_name) = new(kind: Kind.const_get(kind_name))

  # Resolve to a concrete Type. receiver is the call's receiver type
  # (for parametric shapes); args/host support the Infer variant's
  # host-method dispatch. Always returns a Type, never nil.
  sig do
    params(receiver: T.nilable(Type), args: T::Array[T.untyped],
           host: T.untyped).returns(Type)
  end
  def resolve(receiver, args = [], host = nil)
    case kind
    when Kind::Fixed
      T.must(fixed)
    when Kind::ElementOf
      el = receiver&.element_type
      el.is_a?(Type) ? el : Type.new(el || :Any)
    when Kind::OptionalOfElement
      Type.new(:"?#{T.must(T.must(receiver).element_type).resolved}")
    when Kind::IdOfElement
      Type.new(:"Id<#{T.must(T.must(receiver).element_type).resolved}>")
    when Kind::OptionalOfValue
      Type.new(:"?#{T.must(receiver).value_type.resolved}")
    when Kind::ValueList
      Type.new(:"#{T.must(receiver).value_type.resolved}[]@list")
    when Kind::KeyList
      Type.new(:"#{T.must(receiver).key_type.resolved}[]@list")
    when Kind::Infer
      r = host.send(T.must(infer), args, nil)
      r.is_a?(Type) ? r : Type.new(r || :Any)
    else
      Type.new(:Any)
    end
  end
end
