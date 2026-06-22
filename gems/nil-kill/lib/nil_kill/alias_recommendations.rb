# typed: false
# frozen_string_literal: true

begin
  require "espalier/alias_recommendations"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../espalier/lib", __dir__))
  require "espalier/alias_recommendations"
end

module NilKill
  AliasRecommendations = Espalier::AliasRecommendations
end
