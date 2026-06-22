# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "fact-mine"
  s.version     = "0.0.1"
  s.summary     = "Language-neutral source fact extraction for CLEAR tools"
  s.description = "Tree-sitter-backed source fact extraction and syntax oracles."
  s.authors     = ["CLEAR"]
  s.license     = "PolyForm-Noncommercial-1.0.0"
  s.files       = Dir["lib/**/*.rb"]
  s.required_ruby_version = ">= 3.1"
  s.add_dependency "tree_sitter", "~> 0.1"
end
