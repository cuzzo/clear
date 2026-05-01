# Loaded by .rspec via `--require spec_helper`. SimpleCov MUST start
# before any compiler source is required, otherwise files loaded earlier
# (transpiler.rb, lexer.rb, etc.) won't be instrumented.
#
# Output:
#   - coverage/.last_run.json -- RubyCritic's simple_cov formatter reads
#     this to populate its coverage column.
#   - coverage/.resultset.json -- per-run line+branch hit data. Merged
#     across runs (and across parallel workers) within merge_timeout.
#   - coverage/index.html     -- standalone HTML report.
#
# Disable with COVERAGE=0 (CI fast-mode, dev shells where the ~5%
# instrumentation overhead isn't wanted).

unless ENV["COVERAGE"] == "0"
  require "simplecov"

  # parallel_rspec forks N workers via Kernel#fork. Two consequences:
  #
  # (a) Every worker inherits the parent's SimpleCov instance with
  #     command_name "RSpec". Without per-worker disambiguation they
  #     all write to .resultset.json under the same key and the last
  #     to exit overwrites everyone else -- coverage collapses from
  #     ~75% to ~10%.
  #
  # (b) simplecov/process.rb only patches Process.fork, not
  #     Kernel#fork, so the SimpleCov.at_fork machinery never fires
  #     for parallel_rspec workers.
  #
  # Hook into parallel_rspec's own Config.after_fork (called inside
  # each child right after fork) to give the worker a unique
  # command_name and restart SimpleCov so its hits land under that
  # key. The parent merges all RSpec-w* resultsets at its at_exit.
  if defined?(ParallelRSpec) && ParallelRSpec::Config.respond_to?(:after_fork)
    ParallelRSpec::Config.after_fork do |worker|
      SimpleCov.command_name "RSpec-w#{worker}-#{Process.pid}"
      SimpleCov.print_error_status = false
      SimpleCov.minimum_coverage 0
      SimpleCov.start
    end
  end

  SimpleCov.start do
    enable_coverage :branch

    # Track all production code under src/.
    track_files "src/**/*.rb"

    # Filter the rest -- they'd otherwise dilute the percentage.
    add_filter "/spec/"
    add_filter "/transpile-tests/"
    add_filter "/vendor/"
    add_filter "/examples/"
    add_filter "/benchmarks/"

    # Subsystem groups so the index page surfaces where coverage is
    # concentrated vs. missing.
    add_group "AST + Parser",      "src/ast"
    add_group "Annotator",         "src/annotator"
    add_group "Annotator helpers", "src/annotator-helpers"
    add_group "MIR",               "src/mir"
    add_group "Backends",          "src/backends"

    # Hold the resultset for an hour so a partial re-run merges into
    # existing data rather than dropping files the subset didn't load.
    merge_timeout 3600
  end
end
