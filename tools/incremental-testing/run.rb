#!/usr/bin/env ruby
# typed: strict
# frozen_string_literal: true

if ENV["COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.command_name "incremental-testing-#{Process.pid}"
  SimpleCov.start do
    coverage_dir ENV.fetch("COVERAGE_DIR", "coverage/incremental-testing")
    enable_coverage :branch
    track_files "compiler/ruby/incremental/**/*.rb"
    track_files "tools/incremental-testing/**/*.rb"
    add_filter do |file|
      next true if file.filename.end_with?("/tools/incremental-testing/run.rb")

      !file.filename.include?("/compiler/ruby/incremental/") &&
        !file.filename.include?("/tools/incremental-testing/")
    end
  end
end

require_relative "cli"

exit IncrementalTesting::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
