# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "decomplex"
  s.version     = "0.0.1"
  s.summary     = "Decision-level duplication and neglected-condition detector"
  s.description = <<~DESC
    Mines the decision structure of a Ruby codebase (case/when dispatch,
    boolean conjunction guards) and reports two design defects nobody
    else's tooling measures: (a) a guard tuple recomputed across N
    methods with 0 reifications -- a missing abstraction, ranked by
    support x scatter; (b) a site whose dispatch is a Hamming-1 subset
    of a high-support pattern -- a neglected condition, i.e. a likely
    bug. Line-clone detectors (Flay) and complexity counters (McCabe)
    do not see this; it is the decision-level analog. Flay is consumed
    read-only when available for broad Type-2/Type-3 similarity; core
    detectors remain stdlib RubyVM::AbstractSyntaxTree only.
  DESC
  s.authors     = ["CLEAR"]
  s.license     = "PolyForm-Noncommercial-1.0.0"
  s.files       = Dir["lib/**/*.rb", "exe/*"]
  s.bindir      = "exe"
  s.executables = ["decomplex"]
  s.required_ruby_version = ">= 3.1"
end
