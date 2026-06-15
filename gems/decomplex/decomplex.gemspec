# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "decomplex"
  s.version     = "0.0.1"
  s.summary     = "Language-aware decision duplication and neglected-condition detector"
  s.description = <<~DESC
    Mines decision structure (case/switch/match dispatch, boolean
    conjunction guards) and reports two design defects nobody else's
    tooling measures: (a) a guard tuple recomputed across N methods
    with 0 reifications -- a missing abstraction, ranked by support x
    scatter; (b) a site whose dispatch is a Hamming-1 subset of a
    high-support pattern -- a neglected condition, i.e. a likely bug.
    Ruby remains supported through RubyVM::AbstractSyntaxTree by
    default; DECOMPLEX_PARSER=tree_sitter enables Tree-sitter-backed
    profiles for Ruby, Python, JavaScript/TypeScript, Go, Rust, and Zig.
  DESC
  s.authors     = ["CLEAR"]
  s.license     = "PolyForm-Noncommercial-1.0.0"
  s.files       = Dir["lib/**/*.rb", "exe/*"]
  s.bindir      = "exe"
  s.executables = ["decomplex"]
  s.required_ruby_version = ">= 3.1"
  s.add_dependency "tree_sitter", "~> 0.1"
end
