# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "prick"
  s.version     = "0.0.1"
  s.summary     = "Categorical coverage-gap synthesis: not all gaps are equal"
  s.description = <<~DESC
    The capstone. A flat "673/2732 uncovered" is unactionable because
    gaps are not equal. prick classifies every dark branch arm by
    category -- type-normalization (likely removable, confirm with
    nil-kill), defensive/invariant-pinned (accept), dead-decision
    (delete: complexity down), or GENUINE reachable gap -- then overlays
    fix-churn so the genuine arms in churn-hot code surface as "bugs
    highly likely HERE." It OWNS the gap-categorization analysis and
    CONSUMES fix-cache (churn) + an optional nil-kill verdict; it does
    not re-derive them. Promotes tools/branch_prick.rb to a
    first-class product. Zero runtime deps beyond the sibling fix-cache.
  DESC
  s.authors     = ["CLEAR"]
  s.license     = "PolyForm-Noncommercial-1.0.0"
  s.files       = Dir["lib/**/*.rb", "exe/*"]
  s.bindir      = "exe"
  s.executables = ["prick"]
  s.required_ruby_version = ">= 3.1"
end
