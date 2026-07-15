# frozen_string_literal: true

require_relative "espalier/root"

module Espalier
  VERSION = "0.0.1"
end

require_relative "espalier/static_helpers"
require_relative "espalier/languages"
require_relative "espalier/tree_sitter"
require_relative "espalier/nil_kill_evidence"
require_relative "espalier/static_evidence"
require_relative "espalier/privacy_analyzer"
require_relative "espalier/architecture_analyzer"
require_relative "espalier/aggregator"
require_relative "espalier/dependency_graph"
require_relative "espalier/architecture_artifact"
require_relative "espalier/graphviz_formatter"
require_relative "espalier/formatter"
require_relative "espalier/unknown_operations_report"
require_relative "espalier/reporter"

# Espalier: Architectural representation and semantic abstraction aggregator for LLMs.
# Parses source skeletons and state modifications, compiles call nodes into
# DELEGATIONS, and synthesizes annotations from sibling gems.
