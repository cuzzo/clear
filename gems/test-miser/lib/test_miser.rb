# frozen_string_literal: true

require_relative "test_miser/mutation_report"
require_relative "test_miser/analyzer"
require_relative "test_miser/evidence/contribution"
require_relative "test_miser/evidence/subsumption"
require_relative "test_miser/evidence/stability"
require_relative "test_miser/evidence/counterfactual"
require_relative "test_miser/location_resolver"
require_relative "test_miser/reporter"
require_relative "test_miser/mutation_corpus"
require_relative "test_miser/github_artifact_store"
require_relative "test_miser/adapters/cargo_mutants"
require_relative "test_miser/adapters/pit"
require_relative "test_miser/adapters/infection"
require_relative "test_miser/adapters/mull_gtest"
require_relative "test_miser/adapters/muter"

module TestMiser
  VERSION = "0.1.0"
end
