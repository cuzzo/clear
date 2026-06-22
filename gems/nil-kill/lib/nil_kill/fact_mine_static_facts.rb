# typed: false
# frozen_string_literal: true

begin
  require "espalier/fact_mine_static_facts"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../espalier/lib", __dir__))
  require "espalier/fact_mine_static_facts"
end

module NilKill
  FactMineStaticFacts = Espalier::FactMineStaticFacts
end
