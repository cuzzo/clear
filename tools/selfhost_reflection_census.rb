#!/usr/bin/env ruby
# frozen_string_literal: true

# Ruby reflection that survived translation into CLEAR.
#
# CLEAR has no `respond_to?`, no `.class`, no `Kernel`, and no `Struct#members`.
# Every one of these is a guaranteed compile error the moment the compiler
# reaches it -- but the self-hosted build is fail-fast, so it reveals one per
# run and each run costs minutes. Counting them statically says how much of
# this class is left and where it is concentrated, in about a second.
#
#   ruby tools/selfhost_reflection_census.rb [--root DIR] [--list PATTERN]

require 'optparse'

PATTERNS = {
  'respondsTo?' => /respondsTo\?\(/,
  '.class()' => /\.class\(\)/,
  'unsupportedRuby' => /unsupportedRuby\(/,
  '.to_a()' => /\.to_a\(\)/,
  'Kernel.' => /\bKernel\./,
  '.members' => /\.members\b/,
  '.props' => /\.props\b/,
  'public_send' => /public_send/,
}.freeze

root = File.expand_path('../compiler/src', __dir__)
list = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_reflection_census.rb [--root DIR] [--list PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--list PATTERN', 'Print every site whose pattern name matches') { |value| list = value }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

by_file = Hash.new(0)
by_pattern = Hash.new(0)
sites = []

Dir.glob(File.join(root, '**', '*.clear')).sort.each do |path|
  relative = path.delete_prefix("#{root}/")
  File.readlines(path).each_with_index do |line, index|
    PATTERNS.each do |name, pattern|
      next unless line.match?(pattern)

      by_file[relative] += 1
      by_pattern[name] += 1
      sites << [relative, index + 1, name, line.strip[0, 110]]
    end
  end
end

total = by_pattern.values.sum
if list
  sites.select { |_, _, name, _| name.include?(list) }
       .each { |file, line, name, text| puts format('%s:%d  [%s] %s', file, line, name, text) }
  exit(total.zero? ? 0 : 1)
end

puts "selfhost_reflection_census: #{total} reflection site(s) in #{by_file.length} file(s)"
puts
puts 'By pattern:'
by_pattern.sort_by { |_, count| -count }.each { |name, count| puts format('  %-18s %d', name, count) }
puts
puts 'By file:'
by_file.sort_by { |_, count| -count }.first(15).each { |file, count| puts format('  %-52s %d', file, count) }
exit(total.zero? ? 0 : 1)
