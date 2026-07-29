# frozen_string_literal: true

require "open3"
require "rbconfig"

module BranchResultsetHelper
  def write_branch_resultset(source_path, resultset_path)
    script = <<~'RUBY'
      require "coverage"
      require "json"

      source_path = ARGV.fetch(0)
      Coverage.start(branches: true)
      load source_path
      result = Coverage.result
      branches = result.dig(source_path, :branches) || {}
      print JSON.dump("T" => { "coverage" => { source_path => { "branches" => branches } } })
    RUBY

    # A Nil-Kill collect is intentionally inherited by subprocesses so it
    # can observe real application workers. This fixture is different: it
    # owns an independent process-wide Coverage session solely to fabricate
    # a resultset. Do not let the parent collector start its line collector
    # before this process calls Coverage.start(branches: true).
    out, err, status = Open3.capture3(
      { "NIL_KILL_COLLECT_COVERAGE" => "0" },
      RbConfig.ruby, "-e", script, source_path
    )
    raise "branch coverage fixture failed: #{err}" unless status.success?

    File.write(resultset_path, out)
    resultset_path
  end
end
