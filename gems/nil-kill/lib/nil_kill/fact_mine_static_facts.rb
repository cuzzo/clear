# typed: false
# frozen_string_literal: true

begin
  require "fact_mine/espalier_profile"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../fact-mine/lib", __dir__))
  require "fact_mine/espalier_profile"
end

module NilKill
  # Delegates to FactMine::EspalierProfile for all fact extraction.
  # Retained for backward compatibility.
  FactMineStaticFacts = FactMine::EspalierProfile
end