# frozen_string_literal: true

require_relative "espalier/ast_extractor"
require_relative "espalier/aggregator"
require_relative "espalier/formatter"

# Espalier: Architectural representation and semantic abstraction aggregator for LLMs.
# Parses Ruby class/module skeletons and instance variable modifications, compiles call
# nodes into DELEGATIONS, and synthesizes annotations from sibling gems: nil-kill,
# decomplex, boobytrap, and slopcop.
module Espalier
  VERSION = "0.0.1"
end
