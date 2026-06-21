# frozen_string_literal: true

begin
  require "fact_mine/syntax_oracle"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../fact-mine/lib", __dir__))
  require "fact_mine/syntax_oracle"
end

module Decomplex
  SyntaxOracle = FactMine::SyntaxOracle unless const_defined?(:SyntaxOracle, false)
end
