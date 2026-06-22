# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "espalier"
  s.version     = "0.0.1"
  s.summary     = "Architectural representation and semantic abstraction aggregator for LLMs"
  s.description = <<~DESC
    Extracts high-level class schemas, state footprints (EFFECTS), and
    cross-module sequence dependencies (DELEGATIONS) from Ruby ASTs.
    Integrates decomplex path-redundancy metrics, nil-kill signature contracts,
    and boobytrap/slopcop coverage/churn signals to produce extremely compact,
    high-signal architectural manifests for LLM reasoning.
  DESC
  s.authors     = ["CLEAR"]
  s.license     = "PolyForm-Noncommercial-1.0.0"
  s.files       = Dir["lib/**/*.rb", "exe/*"]
  s.bindir      = "exe"
  s.executables = ["espalier"]
  s.required_ruby_version = ">= 3.1"
  s.add_dependency "decomplex", "= 0.0.1"
  s.add_dependency "fact-mine", ">= 0.0.1"
end
