# frozen_string_literal: true

begin
  require "fact_mine/ast"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../fact-mine/lib", __dir__))
  require "fact_mine/ast"
end

module Decomplex
  module Ast
    def self.parse(...)
      FactMine::Ast.parse(...)
    end

    def self.parse_semantic(...)
      FactMine::Ast.parse_semantic(...)
    end
  end unless const_defined?(:Ast, false)
end
