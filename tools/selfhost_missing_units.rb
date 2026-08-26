#!/usr/bin/env ruby
# frozen_string_literal: true

# Which generated units does compiler/src REQUIRE but not contain?
#
# The self-hosted tree is fail-fast and serialized: one bad unit hides every
# unit behind it, so a missing FILE shows up only as whatever error the
# compiler happens to reach first, minutes into a build. A REQUIRE names its
# target as a hex-encoded relative path, so the whole answer is a set
# difference -- and it takes about a second instead of a build.
#
#   ruby tools/selfhost_missing_units.rb [--root compiler/src]
#
# Exits 1 when anything is missing, so it can gate a build.

require 'optparse'
require 'set'

root = File.expand_path('../compiler/src', __dir__)
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_missing_units.rb [--root DIR]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

sources = Dir.glob(File.join(root, '**', '*.clear'))
present = sources.map { |path| path.delete_prefix("#{root}/") }.to_set

missing = Hash.new { |hash, key| hash[key] = [] }
sources.each do |path|
  relative = path.delete_prefix("#{root}/")
  text = File.read(path)

  text.scan(/REQUIRE "pkg:rtoc_([0-9a-f]+)"/) do |(encoded)|
    required = [encoded].pack('H*')
    missing[required] << relative unless present.include?(required)
  end

  # A REQUIRE also takes a path relative to the requiring FILE. Checking only
  # the hex package form reported a clean tree while
  # `mir_lowering.clear`'s `REQUIRE "test_lowering.clear"` still dangled.
  text.scan(/REQUIRE "(?!pkg:)([^"]+)"/) do |(spec)|
    required = File.expand_path(spec, File.dirname(path)).delete_prefix("#{root}/")
    missing[required] << relative unless present.include?(required)
  end
end

if missing.empty?
  puts "selfhost_missing_units: every REQUIRE resolves (#{present.length} units)"
  exit 0
end

puts "selfhost_missing_units: #{missing.length} unit(s) REQUIRED but absent from #{root}"
missing.sort_by { |unit, users| [-users.length, unit] }.each do |unit, users|
  ruby = unit.sub(/\.clear\z/, '.rb')
  ruby_path = File.expand_path("../compiler/ruby/#{ruby}", __dir__)
  lines = File.exist?(ruby_path) ? "#{File.readlines(ruby_path).length} Ruby lines" : 'NO Ruby source'
  puts format('  %-42s %-16s required by: %s', unit, lines, users.sort.join(', '))
end
exit 1
