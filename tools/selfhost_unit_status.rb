#!/usr/bin/env ruby
# frozen_string_literal: true

# Which units in the annotator closure type-check, and where the rest stop.
#
# The closure compiles all-or-nothing, so "how far along" is otherwise
# invisible: one file's first error is all the package build reports. Checking
# each unit on its own turns that into a count.
require 'open3'
require 'set'

ROOT = File.expand_path('..', __dir__)
root = File.join(ROOT, 'compiler', 'src')

units = Dir.glob(File.join(root, '**', '*.clear')).map { |p| p[(root.length + 1)..] }.sort
pass = []
fail = {}
units.each_with_index do |u, i|
  out, err, status = Open3.capture3({ 'RUBYOPT' => '-W0' }, RbConfig.ruby,
                                    File.join(ROOT, 'tools', 'selfhost_check_unit.rb'), u, chdir: ROOT)
  if status.success?
    pass << u
  else
    line = "#{out}\n#{err}".lines.grep(/Compiler Error|Parser Error/).first.to_s.strip
    fail[u] = line.gsub(/\e\[[0-9;]*m/, '')[0, 150]
  end
  warn "[#{i + 1}/#{units.length}] #{pass.length} pass"
end
puts "PASS #{pass.length} / #{units.length}"
fail.sort.each { |u, e| puts "  FAIL #{u}\n        #{e}" }
