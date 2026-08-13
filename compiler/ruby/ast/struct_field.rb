# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module AST
  # Acyclic foundation record: field-declaration metadata with no dependency
  # on semantic Type. The Type-returning `type` accessor is defined alongside
  # Type itself (type.rb) so this file's generated package stays leaf-level.
  # ruby-to-clear: pub
  StructField = Struct.new(:type, :default, :borrowed, keyword_init: true) do
    extend T::Sig

    # The default is a parsed expression node. Typed T.untyped only because a
    # Locatable reference here would close a load cycle; naming it keeps the
    # generated record from picking up whichever union it is stored in.
    # ruby-to-clear: field-type default=?Locatable

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
