# frozen_string_literal: true

# Canonical Minitest bootstrap for Test Miser's full-corpus mutation profile.
# The collector needs every test registered before it can trace baselines and
# attribute mutant kills to individual tests.
require "mutant/integration/minitest"

Dir[File.expand_path("../test/**/*_test.rb", __dir__)].sort.each do |path|
  require path
end
