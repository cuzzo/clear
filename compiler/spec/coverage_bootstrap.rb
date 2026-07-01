# Shared SimpleCov bootstrap for entry points outside RSpec
# (transpile-tests/gen.rb, clear CLI, ad-hoc bundle exec ruby ...).
#
# Caller MUST require this BEFORE loading any compiler/ruby/**/*.rb. Files loaded
# before SimpleCov.start are not instrumented.
#
# Set COVERAGE=1 to enable. Each caller passes its own command_name so
# resultsets from different entry points stay distinct in
# coverage/.resultset.json. compiler/spec/collate_coverage.rb merges them all
# into a single "RSpec" entry that RubyCritic reads.
#
# Usage:
#   require_relative "../compiler/spec/coverage_bootstrap"
#   CoverageBootstrap.start("transpile-tests")
#
#   # ... then load compiler/ruby as usual
#
# When COVERAGE != 1 or simplecov isn't installed, this is a no-op.

module CoverageBootstrap
  def self.isolated_coverage_dir(command_name)
    File.join(
      ENV.fetch("COVERAGE_DIR", "coverage"),
      "isolated",
      "#{command_name}-#{Process.pid}"
    )
  end

  def self.isolate_process!(command_name)
    return unless ENV["COVERAGE"] == "1"
    return unless ENV["COVERAGE_ISOLATED"] == "1"
    return unless defined?(SimpleCov)

    SimpleCov.command_name("#{command_name}-#{Process.pid}") if SimpleCov.respond_to?(:command_name)
    SimpleCov.coverage_dir(isolated_coverage_dir(command_name))
  end

  def self.start(command_name)
    return unless ENV["COVERAGE"] == "1"

    begin
      require "simplecov"
      require "simplecov/process"
    rescue LoadError
      return
    end

    SimpleCov.start do
      coverage_dir(
        ENV["COVERAGE_ISOLATED"] == "1" ?
          isolated_coverage_dir(command_name) :
          ENV.fetch("COVERAGE_DIR", "coverage")
      )
      command_name "#{command_name}-#{Process.pid}"
      enable_coverage :branch

      # Don't pre-declare the file set with `track_files`. Each non-spec
      # entry point loads only the compiler/ruby paths its workflow exercises
      # (`clear build` may not load formatter; `gen.rb` doesn't load
      # the CLI helpers). With `track_files`, SimpleCov adds zero-hit
      # entries for unloaded files into the resultset; their inflated
      # `relevant_lines` count then dilutes the merged percentage when
      # collated with entries that DID exercise more files. Filters
      # below catch the gem/spec/test code we don't want measured;
      # everything else is auto-tracked.
      add_filter "/compiler/spec/"
      add_filter "/transpile-tests/"
      add_filter "/vendor/"
      add_filter "/examples/"
      add_filter "/benchmarks/"
      add_filter "/gems/nil-kill/"
      add_filter do |source_file|
        source_file.filename.start_with?(File.join(SimpleCov.root, "tools/"))
      end

      add_group "AST + Parser",      "compiler/ruby/ast"
      add_group "Annotator",         "compiler/ruby/annotator"
      add_group "Annotator helpers", "compiler/ruby/annotator/helpers"
      add_group "MIR",               "compiler/ruby/mir"
      add_group "Backends",          "compiler/ruby/backends"
      add_group "Tools",             "compiler/ruby/tools"

      # Hold for an hour so a partial re-run of one entry point merges
      # into the existing data instead of dropping files the partial
      # run didn't load.
      merge_timeout 3600
    end
    SimpleCov.print_error_status = false
    # CLI entry points sometimes capture child stdout as generated source
    # (notably `clear test` capturing `gen.rb --single` Zig). Persist the
    # resultset, but leave report rendering to compiler/spec/collate_coverage.rb so
    # coverage never contaminates machine-readable stdout.
    SimpleCov.at_exit { SimpleCov.result }
  end
end
