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
# Off by default -- SimpleCov + parallel_rspec adds ~15x to wall time
# (2s -> 30s on this repo). CI's ruby-unit job opts in via COVERAGE=1
# so Codecov gets fresh data per push; local devs run uninstrumented
# and only flip the env var when they want a coverage report.

if ENV["COVERAGE"] == "1"
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

  # Cobertura XML output for Codecov / Coveralls / GitLab. CI-friendly:
  # only loads the formatter when the gem is actually installed (skip
  # gracefully if a dev environment has bare simplecov).
  begin
    require "simplecov-cobertura"
    cobertura_available = true
  rescue LoadError
    cobertura_available = false
  end

  SimpleCov.start do
    coverage_dir ENV.fetch("COVERAGE_DIR", "coverage")
    enable_coverage :branch

    if cobertura_available
      formatter SimpleCov::Formatter::MultiFormatter.new([
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::CoberturaFormatter,
      ])
    end

    # Track all production code under src/.
    track_files "src/**/*.rb"

    # Filter the rest -- they'd otherwise dilute the percentage.
    add_filter "/spec/"
    add_filter "/transpile-tests/"
    add_filter "/vendor/"
    add_filter "/examples/"
    add_filter "/benchmarks/"
    add_filter "/tools/"

    # Subsystem groups so the index page surfaces where coverage is
    # concentrated vs. missing.
    add_group "AST + Parser",      "src/ast"
    add_group "Annotator",         "src/annotator"
    add_group "Annotator helpers", "src/annotator/helpers"
    add_group "MIR",               "src/mir"
    add_group "Backends",          "src/backends"

    # Hold the resultset for an hour so a partial re-run merges into
    # existing data rather than dropping files the subset didn't load.
    merge_timeout 3600
  end
end

if defined?(ParallelRSpec) && File.basename($PROGRAM_NAME) == "prspec"
  files = RSpec.configuration.instance_variable_get(:@files_or_directories_to_run)
  RSpec.configuration.files_or_directories_to_run = RSpec.configuration.default_path if files.empty?
end

module MirPipelineSpecHelper
  def compile_mir_frontend(src, source_dir: Dir.pwd)
    require_relative "../src/backends/compiler_frontend"
    require_relative "../src/backends/importer"

    importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
    result = CompilerFrontend.compile(src, importer: importer, source_dir: source_dir)
    raise "CompilerFrontend returned nil" unless result

    result
  end

  def run_mir_frontend(src, source_dir: Dir.pwd)
    compile_mir_frontend(src, source_dir: source_dir).ast
  end
end

RSpec.configure do |config|
  config.include MirPipelineSpecHelper
end
