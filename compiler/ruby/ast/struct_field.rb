# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module AST
  # ruby-to-clear: pub
  StructField = Struct.new(:type, :default, :borrowed, keyword_init: true)
end
