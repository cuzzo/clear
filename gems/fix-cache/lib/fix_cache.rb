# frozen_string_literal: true

require_relative "fix_cache/bugspots"
require_relative "fix_cache/coverage_gap"
require_relative "fix_cache/hotspot"
require_relative "fix_cache/report"

# fix-cache: defect-risk hotspots = recurring bug-fix locality
# (vendored bugspots / Google ICSE'13 time-decay) x branch-coverage
# gap. See docs/agents/design.md for rationale, prior art, and the
# decomplex / nil-kill / churn boundaries.
module FixCache
  VERSION = "0.0.1"
end
