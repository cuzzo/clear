# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module AST
  StructKwargs = T.type_alias { BasicObject }

  # ruby-to-clear: pub
  Param = Struct.new(:name, :type, :default, :mutable, :takes,
                     :comptime, :name_token, :required, :sync, :symbol,
                     keyword_init: true)
end
