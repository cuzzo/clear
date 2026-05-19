# frozen_string_literal: true

require_relative "decomplex/ast"
require_relative "decomplex/site_extractor"
require_relative "decomplex/miner"
require_relative "decomplex/co_update"
require_relative "decomplex/predicate_alias"
require_relative "decomplex/path_condition"
require_relative "decomplex/semantic_alias"
require_relative "decomplex/sequence_mine"
require_relative "decomplex/derived_state"
require_relative "decomplex/type3_clone"
require_relative "decomplex/decision_pressure"
require_relative "decomplex/false_simplicity"
require_relative "decomplex/fat_union"
require_relative "decomplex/convergence"
require_relative "decomplex/root_cause"
require_relative "decomplex/delta"

# Decomplex: decision-level duplication + neglected-condition detector.
# See decomplex.gemspec for the rationale. v0 scope is exact-match
# case/when dispatch + && conjunction over the given files; alias,
# polarity, path-condition, and derived-state signals are v1.
module Decomplex
  VERSION = "0.0.1"
end
