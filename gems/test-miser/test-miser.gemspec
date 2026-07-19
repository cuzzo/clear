# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "test-miser"
  spec.version = "0.1.0"
  spec.summary = "Find mutation-ineffective and possibly redundant tests"
  spec.description = <<~TEXT
    Analyzes per-test mutation data to find tests that kill no mutants and
    groups of tests that kill exactly the same mutant set.
  TEXT
  spec.authors = ["CLEAR"]
  spec.license = "PolyForm-Noncommercial-1.0.0"
  spec.files = Dir["exe/*", "lib/**/*.rb", "README.md"]
  spec.bindir = "exe"
  spec.executables = [
    "test-miser",
    "test-miser-artifact",
    "test-miser-corpus",
    "test-miser-facts",
    "test-miser-github-artifact",
    "test-miser-inventory",
    "test-miser-map",
    "test-miser-merge",
    "test-miser-mutant"
  ]
  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "mutant", "~> 0.15.1"
  spec.add_dependency "mutant-minitest", "~> 0.15.1"
  spec.add_dependency "mutant-rspec", "~> 0.15.1"
  spec.add_dependency "sqlite3", ">= 2.0", "< 3"
end
