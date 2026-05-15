# frozen_string_literal: true

require_relative "prick/classifier"
require_relative "prick/rollup"
require_relative "prick/report"

# prick: categorical coverage-gap synthesis (the capstone).
# Owns the gap-categorization analysis; consumes the sibling fix-cache
# gem for churn and an optional nil-kill verdict for type_norm
# removability. See docs/agents/design.md.
module Prick
  VERSION = "0.0.1"
end
