# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module AST
  # ruby-to-clear: pub
  StructField = Struct.new(:type, :default, :borrowed, keyword_init: true) do
    extend T::Sig

    sig { returns(Type) }
    def type
      T.cast(self[:type], Type)
    end

    sig { returns(T.untyped) }
    def default
      self[:default]
    end

    sig { returns(T::Boolean) }
    def borrowed
      !!self[:borrowed]
    end
  end
end
