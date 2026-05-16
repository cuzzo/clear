# frozen_string_literal: true

require_relative "slopcop/classifier"
require_relative "slopcop/rollup"
require_relative "slopcop/report"

# slopcop: categorical coverage-gap synthesis (the capstone).
# Owns the gap-categorization analysis; consumes the sibling fix-cache
# gem for churn and an optional nil-kill verdict for type_norm
# removability. See docs/agents/design.md.
module SlopCop
  VERSION = "0.0.1"
end
