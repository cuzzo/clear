#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "vm_golden_harness"

root = File.join(MiniVM::Golden::ROOT, "examples", "minivm", "vm-tests")
targets = [:stack]
check = false

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby examples/minivm/update_vm_golden.rb [--check] [--target stack|register|all] [vm-tests-dir]"

  opts.on("--check", "Check snapshots without updating files") do
    check = true
  end

  opts.on("--target TARGET", "Target to update: stack, register, or all") do |value|
    targets = case value
              when "all" then MiniVM::Golden.targets.keys
              else [value.to_sym]
              end
  end
end

parser.parse!(ARGV)
root = File.expand_path(ARGV.shift) if ARGV.first

results = MiniVM::Golden.update_snapshots(root: root, targets: targets, check: check)
counts = results.group_by(&:status).transform_values(&:length)

results.each do |result|
  rel = result.test_case.relative_path(root)
  label = result.status.to_s.upcase.ljust(9)
  line = "#{label} #{result.target} #{rel} -> #{result.path}"
  line += " (#{result.message})" if result.message
  puts line
end

puts
puts counts.sort_by { |status, _| status.to_s }.map { |status, count| "#{status}=#{count}" }.join(" ")

failed = counts.fetch(:error, 0).positive? || (check && counts.fetch(:stale, 0).positive?)
exit(failed ? 1 : 0)
