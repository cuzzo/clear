# Shared SimpleCov bootstrap for entry points outside RSpec
# (transpile-tests/gen.rb, clear CLI, ad-hoc bundle exec ruby ...).
#
# Caller MUST require this BEFORE loading any src/**/*.rb. Files loaded
# before SimpleCov.start are not instrumented.
#
# Set COVERAGE=1 to enable. Each caller passes its own command_name so
# resultsets from different entry points stay distinct in
# coverage/.resultset.json. spec/collate_coverage.rb merges them all
# into a single "RSpec" entry that RubyCritic reads.
#
# Usage:
#   require_relative "../spec/coverage_bootstrap"
#   CoverageBootstrap.start("transpile-tests")
#
#   # ... then load src/ as usual
#
# When COVERAGE != 1 or simplecov isn't installed, this is a no-op.

module CoverageBootstrap
  def self.start(command_name)
    return unless ENV["COVERAGE"] == "1"

    begin
      require "simplecov"
    rescue LoadError
      return
    end

    SimpleCov.start do
      command_name "#{command_name}-#{Process.pid}"
      enable_coverage :branch

      # Don't pre-declare the file set with `track_files`. Each non-spec
      # entry point loads only the src/ paths its workflow exercises
      # (`clear build` may not load formatter; `gen.rb` doesn't load
      # the CLI helpers). With `track_files`, SimpleCov adds zero-hit
      # entries for unloaded files into the resultset; their inflated
      # `relevant_lines` count then dilutes the merged percentage when
      # collated with entries that DID exercise more files. Filters
      # below catch the gem/spec/test code we don't want measured;
      # everything else is auto-tracked.
      add_filter "/spec/"
      add_filter "/transpile-tests/"
      add_filter "/vendor/"
      add_filter "/examples/"
      add_filter "/benchmarks/"

      add_group "AST + Parser",      "src/ast"
      add_group "Annotator",         "src/annotator"
      add_group "Annotator helpers", "src/annotator/helpers"
      add_group "MIR",               "src/mir"
      add_group "Backends",          "src/backends"

      # Hold for an hour so a partial re-run of one entry point merges
      # into the existing data instead of dropping files the partial
      # run didn't load.
      merge_timeout 3600
    end
    SimpleCov.print_error_status = false
    # CLI entry points sometimes capture child stdout as generated source
    # (notably `clear test` capturing `gen.rb --single` Zig). Persist the
    # resultset, but leave report rendering to spec/collate_coverage.rb so
    # coverage never contaminates machine-readable stdout.
    SimpleCov.at_exit { SimpleCov.result }
  end
end
