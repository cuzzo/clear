#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "rbconfig"

options = { fact_mine_consumers: false, coverage: true }
OptionParser.new do |parser|
  parser.on("--fact-mine-consumers", "Run only Ruby suites that invoke FactMine") do
    options[:fact_mine_consumers] = true
  end
  parser.on("--without-coverage", "Run tests without SimpleCov instrumentation") do
    options[:coverage] = false
  end
end.parse!

root = File.expand_path("..", __dir__)
Dir.chdir(root)
if options[:coverage]
  FileUtils.rm_rf(File.join(root, "coverage", "ruby-gems"))
  FileUtils.rm_rf(File.join(root, "coverage", "ruby-gems-subprocess"))
end

def merge_nil_kill_subprocess_coverage(root)
  child_resultset = File.join(root, "coverage", "ruby-gems-subprocess", ".resultset.json")
  return unless File.file?(child_resultset)

  parent_resultset = File.join(root, "coverage", "ruby-gems", ".resultset.json")
  parent = File.file?(parent_resultset) ? JSON.parse(File.read(parent_resultset)) : {}
  child = JSON.parse(File.read(child_resultset))
  FileUtils.mkdir_p(File.dirname(parent_resultset))
  File.write(parent_resultset, JSON.pretty_generate(parent.merge(child)))
rescue JSON::ParserError
  warn "failed to merge nil-kill subprocess coverage"
end

if options[:coverage]
  $LOAD_PATH.unshift(File.join(root, "gems/ruby-to-clear/lib"))

  require "simplecov"
  begin
    require "simplecov-cobertura"
    cobertura_available = true
  rescue LoadError
    cobertura_available = false
  end

  SimpleCov.command_name "ruby-gems"
  SimpleCov.coverage_dir "coverage/ruby-gems"
  SimpleCov.print_error_status = false
  SimpleCov.minimum_coverage 0
  SimpleCov.start do
    enable_coverage :branch
    track_files "gems/{auto-type,boobytrap,decomplex,espalier,fact-mine,nil-kill,ruby-to-clear,slopcop}/lib/**/*.rb"
    add_filter "/vendor/"
    add_filter "/spec/"
    add_filter "/test/"
    add_filter "/tmp/"
    add_group "auto-type", "gems/auto-type/lib"
    add_group "boobytrap", "gems/boobytrap/lib"
    add_group "decomplex", "gems/decomplex/lib"
    add_group "espalier", "gems/espalier/lib"
    add_group "fact-mine", "gems/fact-mine/lib"
    add_group "nil-kill", "gems/nil-kill/lib"
    add_group "ruby-to-clear", "gems/ruby-to-clear/lib"
    add_group "slopcop", "gems/slopcop/lib"

    if cobertura_available
      formatter SimpleCov::Formatter::MultiFormatter.new([
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::CoberturaFormatter,
      ])
    end
  end
end

# The nil-kill spec helper has its own focused coverage mode. Keep it off here
# because this harness owns the all-gems SimpleCov session.
ENV.delete("NIL_KILL_COVERAGE")
ENV["NIL_KILL_TMP_DIR"] ||= File.join(root, "tmp", "ruby-gem-coverage", Process.pid.to_s)
if options[:coverage]
  ENV["NIL_KILL_SUBPROCESS_COVERAGE"] = "1"
  ENV["NIL_KILL_SUBPROCESS_COVERAGE_DIR"] = File.join(root, "coverage", "ruby-gems-subprocess")
else
  ENV.delete("NIL_KILL_SUBPROCESS_COVERAGE")
  ENV.delete("NIL_KILL_SUBPROCESS_COVERAGE_DIR")
end

require "rspec/core"

rspec_patterns, minitest_patterns = if options[:fact_mine_consumers]
  [
    ["gems/nil-kill/spec/**/*_spec.rb"],
    ["gems/espalier/test/**/*_test.rb", "gems/slopcop/test/**/*_test.rb"],
  ]
else
  [
    [
      "gems/auto-type/spec/**/*_spec.rb",
      "gems/nil-kill/spec/**/*_spec.rb",
      "gems/ruby-to-clear/spec/**/*_spec.rb",
    ],
    [
      "gems/boobytrap/test/**/*_test.rb",
      "gems/decomplex/test/**/*_test.rb",
      "gems/espalier/test/**/*_test.rb",
      "gems/fact-mine/test/**/*_test.rb",
      "gems/slopcop/test/**/*_test.rb",
    ],
  ]
end
rspec_files = Dir[*rspec_patterns].sort
minitest_files = Dir[*minitest_patterns].sort
coverage_owned_minitest_files, simplecov_minitest_files =
  minitest_files.partition { |file| File.read(file).include?("Coverage.start") }

rspec_status = RSpec::Core::Runner.run(rspec_files, $stderr, $stdout)
external_status = 0
coverage_owned_minitest_files.each do |file|
  ok = system(
    { "COVERAGE" => "0", "SIMPLECOV_DISABLED" => "1" },
    RbConfig.ruby,
    File.expand_path(file, root)
  )
  external_status = 1 unless ok
end

at_exit do
  exit rspec_status if rspec_status != 0 && $!.nil?
  exit external_status if external_status != 0 && $!.nil?
end

at_exit { merge_nil_kill_subprocess_coverage(root) } if options[:coverage]

simplecov_minitest_files.each { |file| require File.expand_path(file, root) }
