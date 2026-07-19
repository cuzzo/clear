# frozen_string_literal: true

# Espalier-specific mutation setup. This intentionally lives with Espalier;
# Test Miser only consumes the resulting mutant-facts or MTE artifact.
fact_mine_cache = File.expand_path("../../../tmp/espalier-test-miser-fact-cache", __dir__)
cached_fact_mine = File.expand_path("test_miser_cached_fact_mine", __dir__)
real_fact_mine = ENV.fetch(
  "FACT_MINE_RUST_BINARY",
  File.expand_path("../../fact-mine/target/release/fact-mine-rust", __dir__)
)
unless real_fact_mine == cached_fact_mine
  ENV["TEST_MISER_FACT_MINE_REAL_BINARY"] = real_fact_mine
  ENV["FACT_MINE_RUST_BINARY"] = cached_fact_mine
end
ENV["TEST_MISER_FACT_MINE_CACHE_DIR"] = fact_mine_cache

require "espalier"
require "mutant/integration/minitest"

unless Espalier::StaticEvidence::FACT_MINE_RUST_BINARY == cached_fact_mine
  Espalier::StaticEvidence.__send__(:remove_const, :FACT_MINE_RUST_BINARY)
  Espalier::StaticEvidence.const_set(:FACT_MINE_RUST_BINARY, cached_fact_mine)
end

Minitest::Test.cover "Espalier*"

test_pattern = File.expand_path("../test/*_test.rb", __dir__)
Dir[test_pattern].sort.each { |path| require path }
