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

    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, source_path)
    raise "branch coverage fixture failed: #{err}" unless status.success?

    File.write(resultset_path, out)
    resultset_path
  end
end
