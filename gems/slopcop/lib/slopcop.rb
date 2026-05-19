# frozen_string_literal: true

require_relative "slopcop/classifier"
require_relative "slopcop/decomplex_verdict"
require_relative "slopcop/rollup"
require_relative "slopcop/report"

# slopcop: categorical coverage-gap synthesis (the capstone).
# Owns the gap-categorization analysis; consumes the sibling boobytrap
# gem for churn, an optional nil-kill verdict for type_norm
# removability, and optional decomplex for the `spurious` filter
# (redundant decision -> refactor not test) plus the structural-
# deviance rank amplifier on genuine gaps. See docs/agents/design.md.
module SlopCop
  VERSION = "0.0.1"
end
