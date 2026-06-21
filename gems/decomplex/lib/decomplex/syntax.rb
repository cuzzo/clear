# frozen_string_literal: true

begin
  require "fact_mine/syntax"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../fact-mine/lib", __dir__))
  require "fact_mine/syntax"
end

module Decomplex
  Syntax = FactMine::Syntax unless const_defined?(:Syntax, false)
end
