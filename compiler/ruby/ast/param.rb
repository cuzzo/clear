# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "type"

module AST
  StructKwargs = T.type_alias { BasicObject }

  # ruby-to-clear: pub
  Param = Struct.new(:name, :type, :default, :mutable, :takes,
                     :comptime, :name_token, :required, :sync, :symbol,
                     keyword_init: true) do
    extend T::Sig

    sig { params(kw: StructKwargs).void }
    def initialize(**kw)
      super
      t = T.let(self[:type], T.nilable(Type::TypeInput))
      self[:type] = Type.new(t || Type.type_input_symbol_or_any(nil))
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
