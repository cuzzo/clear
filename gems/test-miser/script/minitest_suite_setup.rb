# frozen_string_literal: true

# Load Mutant's Minitest integration before any test helper can register
# Minitest's autorun hook. Test Miser invokes examples itself; an autorun at
# process exit would execute the entire suite again for every baseline trace
# and every mutant.
require "mutant/integration/minitest"

test_root = ENV.fetch("TEST_MISER_TEST_ROOT")
Dir[File.join(test_root, "**", "*_test.rb")].sort.each { |path| require File.expand_path(path) }
