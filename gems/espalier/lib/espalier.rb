# frozen_string_literal: true

require_relative "espalier/ast_extractor"
require_relative "espalier/nil_kill_evidence"
begin
  require "decomplex/ruby_topology"
rescue LoadError
  require_relative "../../decomplex/lib/decomplex/ruby_topology"
end
require_relative "espalier/privacy_analyzer"
require_relative "espalier/architecture_analyzer"
require_relative "espalier/aggregator"
require_relative "espalier/formatter"
require_relative "espalier/reporter"

# Espalier: Architectural representation and semantic abstraction aggregator for LLMs.
# Parses Ruby class/module skeletons and instance variable modifications, compiles call
# nodes into DELEGATIONS, and synthesizes annotations from sibling gems: nil-kill,
# decomplex, boobytrap, and slopcop.
module Espalier
  VERSION = "0.0.1"
end
