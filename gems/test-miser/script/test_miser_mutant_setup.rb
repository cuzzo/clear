# frozen_string_literal: true

# Canonical Minitest bootstrap for Test Miser's full-corpus mutation profile.
# The collector needs every test registered before it can trace baselines and
# attribute mutant kills to individual tests.
require "mutant/integration/minitest"
require "test_miser"
require "test_miser/subject_inventory"

test_files = Dir[File.expand_path("../test/**/*_test.rb", __dir__)].sort
if ENV["TEST_MISER_MUTATION_ANALYSIS"] == "1"
  # These files verify external command orchestration (including this
  # collector) and the Lineage importer. They remain in the ordinary suite,
  # coverage run, and NilKill trace. Running them *inside* a Test Miser mutant
  # worker recursively launches corpus/inference commands and measures the
  # harness rather than the selected production mutant.
  mutation_harness_tests = %w[lineage_ingest_integration_test.rb test_miser_test.rb]
  test_files.reject! { |path| mutation_harness_tests.include?(File.basename(path)) }
end
test_files.each { |path| require path }
