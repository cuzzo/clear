#!/usr/bin/env ruby
# frozen_string_literal: true

# Parse every self-hosted package, including each SCC group as the single
# merged file it actually compiles as.
#
# Parsing is the one stage that needs no importer and no dependency closure, so
# it costs seconds where a transpile costs minutes -- and a syntax error inside
# a cyclic group is invisible until the group is merged, because every member
# parses fine on its own.
#
#   ruby tools/selfhost_parse_check.rb [--root compiler/src] [--only PATTERN]
#
# Exits 1 if anything fails to parse.

require 'optparse'
require 'set'

root = File.expand_path('../compiler/src', __dir__)
only = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_parse_check.rb [--root DIR] [--only PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--only PATTERN') { |value| only = Regexp.new(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

saved = $PROGRAM_NAME
$PROGRAM_NAME = 'selfhost_parse_check_support'
require_relative 'parser_compat'
$PROGRAM_NAME = saved

src = File.expand_path('../compiler/ruby', __dir__)
$LOAD_PATH.unshift(src)
%w[ast mir backends annotator-helpers].each { |dir| $LOAD_PATH.unshift(File.join(src, dir)) }
require 'compiler/compiler_frontend'

groups = ParserCompat.package_groups(root)
grouped = groups.values.flatten.to_set

units = Dir.glob(File.join(root, '**', '*.clear')).map { |path| path.delete_prefix("#{root}/") }
targets = groups.map { |name, members| [name, members] }
targets += units.reject { |unit| grouped.include?(unit) }.map { |unit| [unit, [unit]] }
targets.select! { |name, _| name.match?(only) } if only

failures = []
targets.sort_by(&:first).each do |name, members|
  source = members.map { |member| File.read(File.join(root, member)) }.join("\n")
  ClearParser.new(Lexer.new(source).tokenize, source).parse
rescue StandardError => e
  message = e.message.to_s.gsub(/\e\[[0-9;]*m/, '').lines.reject { |l| l.strip.empty? }.first(2).join(' ').strip
  failures << [name, members.length, message[0, 200]]
end

if failures.empty?
  puts "selfhost_parse_check: #{targets.length} package(s) parse"
  exit 0
end

puts "selfhost_parse_check: #{failures.length}/#{targets.length} package(s) fail to parse"
failures.each { |name, count, message| puts format('  %-28s (%d member(s)) %s', name, count, message) }
exit 1
