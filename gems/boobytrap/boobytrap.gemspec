# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "boobytrap"
  s.version     = "0.0.1"
  s.summary     = "Defect-risk hotspots: recurring fix-churn x branch-coverage gap"
  s.description = <<~DESC
    Finds the code most LIKELY to be the source of bugs, not merely the
    most complex. Vendors the bugspots scoring (Google's rolling,
    time-decayed bug-fix-locality prediction -- Lewis et al. ICSE'13,
    the actionable FixCache variant) and joins it with branch-coverage
    gap from SimpleCov's resultset: code that keeps getting fixed AND
    is under-exercised by the test corpus. Raw `churn` measures
    activity, not fault locality; this measures fault locality. Output
    is a single ranked hotspot report, like decomplex / nil-kill.
    Zero runtime dependencies: stdlib + the `git` CLI only.
  DESC
  s.authors     = ["CLEAR"]
  s.license     = "PolyForm-Noncommercial-1.0.0"
  s.files       = Dir["lib/**/*.rb", "exe/*"]
  s.bindir      = "exe"
  s.executables = ["boobytrap"]
  s.required_ruby_version = ">= 3.1"
end
