# typed: false
# frozen_string_literal: true

require "set"
require "pathname"
require_relative "static_helpers"

begin
  require "fact_mine/espalier_profile"
rescue LoadError
  $LOAD_PATH.unshift(File.expand_path("../../../fact-mine/lib", __dir__))
  require "fact_mine/espalier_profile"
end

module Espalier
  # Delegates to FactMine::EspalierProfile for all fact extraction.
  # Kept for backward compatibility; new code should call
  # FactMine::EspalierProfile.build directly.
  module FactMineStaticFacts
    module_function

    def build(document, structural_facts, root: Espalier::ROOT, profile: :nil_kill)
      FactMine::EspalierProfile.build(document, structural_facts, root: root, profile: profile)
    end
  end
end
