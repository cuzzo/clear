# frozen_string_literal: true

begin
  require "fact_mine/ast"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../fact-mine/lib", __dir__))
  require "fact_mine/ast"
end

module Decomplex
  Ast = FactMine::Ast unless const_defined?(:Ast, false)
end
