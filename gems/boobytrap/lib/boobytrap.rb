# frozen_string_literal: true

require_relative "boobytrap/bugspots"
require_relative "boobytrap/coverage_data"
require_relative "boobytrap/coverage_gap"
require_relative "boobytrap/decomplex_risk"
require_relative "boobytrap/hotspot"
require_relative "boobytrap/method_gap"
require_relative "boobytrap/mutation_facts"
require_relative "boobytrap/report"

# boobytrap: defect-risk hotspots = recurring bug-fix locality
# (vendored bugspots / Google ICSE'13 time-decay) x branch-coverage
# gap. See docs/agents/design.md for rationale, prior art, and the
# decomplex / nil-kill / churn boundaries.
module Boobytrap
  VERSION = "0.0.1"
end
