# frozen_string_literal: true

require "minitest/autorun"

module FactMine
  module EspalierProfile
    def self.build(document, structural_facts, root:, profile:)
    end
  end
end

module Kernel
  alias_method :original_require, :require
  def require(name)
    if name == "fact_mine/espalier_profile"
      return true
    end
    original_require(name)
  end
end

require_relative "../lib/espalier/fact_mine_static_facts"

class FactMineStaticFactsTest < Minitest::Test
  def test_delegates_to_fact_mine
    # Mock FactMine::EspalierProfile.build
    mock_called = false
    FactMine::EspalierProfile.define_singleton_method(:build) do |document, structural_facts, root:, profile:|
      mock_called = true
    end

    Espalier::FactMineStaticFacts.build("doc", "facts", root: "root", profile: :nil_kill)
    assert mock_called
  end
end
