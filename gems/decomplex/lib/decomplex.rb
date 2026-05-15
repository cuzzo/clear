# frozen_string_literal: true

require_relative "decomplex/site_extractor"
require_relative "decomplex/miner"
require_relative "decomplex/co_update"
require_relative "decomplex/predicate_alias"

# Decomplex: decision-level duplication + neglected-condition detector.
# See decomplex.gemspec for the rationale. v0 scope is exact-match
# case/when dispatch + && conjunction over the given files; alias,
# polarity, path-condition, and derived-state signals are v1.
module Decomplex
  VERSION = "0.0.1"
end
