  A. The "Verification Decay" Signal
  Currently, you track last_test_exposure_at.
   * The Gap: If a function has 100% mutant coverage in Commit A, but has been modified 5 times since then without a new mutant
     run, the coverage is "Stale."
   * High-Value Fix: Surface a "Verification Staleness" score.
       * Logic: current_timestamp - last_mutant_run_at.
       * Result: SlopCop can flag: "Warning: This atomic hazard was verified by Loom 3 months ago, but has changed logically 4
         times since then. Re-verification required."
   * Create a warning / caution banner if coverage or mutant or any important data is ever stale or out of sink.

  B. The "Fix Effectiveness" Metric
  Gigasail knows when a unit was "fixed" and when it "crashed."
   * The Gap: It doesn't explicitly link the two to measure "Fix Regressions."
   * High-Value Fix: Add a reopened_count to the UnitSummary.
       * Logic: How many crash_events occurred on a line after a FIX event for that same line?
       * Result: Identifies "Whack-a-Mole" bugs where your fixes aren't actually solving the root cause.
   * TODO: Is this a Boobytrap or SlopCop metric?
