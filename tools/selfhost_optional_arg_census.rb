#!/usr/bin/env ruby
# frozen_string_literal: true

# Nilable fields passed where a non-optional parameter is declared.
#
# Ruby has no such distinction, so the translation passes `node.default_body`
# straight into a parameter typed `[]Emittable` and CLEAR rejects it. The build
# reports one of these per run.
#
# Like the other censuses, this only reports what it can type precisely: the
# callee must have a visible signature, and the argument must be a field read
# off a `node:` parameter whose struct declares that field optional. Anything
# it cannot type, it stays quiet about.
#
#   ruby tools/selfhost_optional_arg_census.rb [--root DIR] [--file PATTERN]

require 'optparse'
require 'set'

root = File.expand_path('../compiler/src', __dir__)
file_filter = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_optional_arg_census.rb [--root DIR] [--file PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--file PATTERN') { |value| file_filter = Regexp.new(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

sources = Dir.glob(File.join(root, '**', '*.clear')).sort

# struct -> field -> declared type, keyed by the OWNING struct: `name` is a
# String on one struct and optional on another.
field_type = Hash.new { |hash, key| hash[key] = {} }
# function -> array of declared parameter types, in order.
param_types = {}
sources.each do |path|
  current = nil
  File.readlines(path).each do |line|
    if (match = line.match(/\APUB STRUCT (\w+) \{/))
      current = match[1]
    elsif line.start_with?('}')
      current = nil
    elsif current && (match = line.match(/\A  ([a-z_]\w*): (.+?),?\s*\z/))
      field_type[current][match[1]] = match[2]
    end

    next unless (match = line.match(/\A(?:PRIVATE |PUB )?FN (\w+[?!]?)(?:<[^>]*>)?\((.*?)\)\s*(?:RETURNS|->|$)/))

    param_types[match[1]] = match[2].split(/,\s*(?![^<>{}]*[>}])/).map do |param|
      param.sub(/\A(?:MUTABLE )?\w+:\s*/, '').sub(/\s*=.*\z/, '').strip
    end
  end
end

findings = []
sources.each do |path|
  relative = path.delete_prefix("#{root}/")
  next if file_filter && !relative.match?(file_filter)

  owner = nil
  File.readlines(path).each_with_index do |line, index|
    if line =~ /\A(?:PRIVATE |PUB )?FN \w+\(.*?node: (\w+)[,)]/
      owner = Regexp.last_match(1)
    elsif line =~ /\A(?:PRIVATE |PUB )?FN /
      owner = nil
    end
    next unless owner

    line.scan(/(\w+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)/) do |callee, argument_text|
      declared = param_types[callee]
      next unless declared

      argument_text.split(/,\s*(?![^()]*\))/).each_with_index do |argument, position|
        next unless argument.strip =~ /\Anode\.([a-z_]\w*)\z/

        actual = field_type[owner][Regexp.last_match(1)]
        expected = declared[position]
        next unless actual&.start_with?('?') && expected && !expected.start_with?('?')
        next if expected == 'Any@multiowned'

        findings << [relative, index + 1, callee, position + 1, Regexp.last_match(1), actual, expected]
      end
    end
  end
end

if findings.empty?
  puts 'selfhost_optional_arg_census: no nilable field passed to a non-optional parameter'
  exit 0
end

puts "selfhost_optional_arg_census: #{findings.length} nilable argument(s) at a non-optional parameter"
findings.each do |file, line, callee, position, field, actual, expected|
  puts format('  %s:%d  %s arg %d: node.%s is %s, parameter is %s',
              file, line, callee, position, field, actual, expected)
end
exit 1
