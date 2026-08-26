#!/usr/bin/env ruby
# frozen_string_literal: true

# Locals bound from a nilable field with no annotation.
#
# `MUTABLE x = node.thing` where `thing` is optional gives CLEAR nothing to
# infer from -- "Cannot infer `x` from an optional value" -- because Ruby's
# untyped assignment carries no answer to "optional of what". The build reports
# one of these per run.
#
# Keyed by the OWNING struct, like the other censuses: the same field name is
# optional on one struct and not on another.
#
#   ruby tools/selfhost_optional_bind_census.rb [--root DIR] [--file PATTERN]

require 'optparse'

root = File.expand_path('../compiler/src', __dir__)
file_filter = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_optional_bind_census.rb [--root DIR] [--file PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--file PATTERN') { |value| file_filter = Regexp.new(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

sources = Dir.glob(File.join(root, '**', '*.clear')).sort

field_type = Hash.new { |hash, key| hash[key] = {} }
element_of = {}
sources.each do |path|
  current = nil
  File.readlines(path).each do |line|
    if (match = line.match(/\APUB STRUCT (\w+) \{/))
      current = match[1]
    elsif line.start_with?('}')
      current = nil
    elsif current && (match = line.match(/\A  ([a-z_]\w*): (.+?),?\s*\z/))
      field_type[current][match[1]] = match[2]
      element_of[[current, match[1]]] = Regexp.last_match(1) if match[2] =~ /\A\?*\[\](\w+)\z/
    end
  end
end

findings = []
sources.each do |path|
  relative = path.delete_prefix("#{root}/")
  next if file_filter && !relative.match?(file_filter)

  # Receiver types come from the same four places the field-call census uses:
  # the `node:` parameter, a `MUTABLE x: T` annotation, a FOR over a declared
  # list field, and the `_` a pipeline binds. Most of these live on `_`.
  binding_type = {}
  File.readlines(path).each_with_index do |line, index|
    if line =~ /\A(?:PRIVATE |PUB )?FN \w+\(.*?node: (\w+)[,)]/
      binding_type = { 'node' => Regexp.last_match(1) }
    elsif line =~ /\A(?:PRIVATE |PUB )?FN /
      binding_type = {}
    end
    binding_type[Regexp.last_match(1)] = Regexp.last_match(2) if line =~ /MUTABLE (\w+): \??(\w+) =/
    owner = binding_type['node']
    if owner
      if line =~ /FOR (\w+) IN [\w.]*\.([a-z_]\w*)\b/ && element_of[[owner, Regexp.last_match(2)]]
        binding_type[Regexp.last_match(1)] = element_of[[owner, Regexp.last_match(2)]]
      end
      if line =~ /[\w.]*\.([a-z_]\w*) \|> (?:SELECT|WHERE|ANY|ALL|FIND)/ && element_of[[owner, Regexp.last_match(1)]]
        binding_type['_'] = element_of[[owner, Regexp.last_match(1)]]
      end
    end
    next unless line =~ /\A\s*MUTABLE (\w+) = (\w+)\.([a-z_]\w*);\s*\z/

    name = Regexp.last_match(1)
    receiver = Regexp.last_match(2)
    field = Regexp.last_match(3)
    struct = binding_type[receiver]
    next unless struct

    type = field_type[struct][field]
    findings << [relative, index + 1, name, "#{receiver}:#{struct}", field, type] if type&.start_with?('?')
  end
end

if findings.empty?
  puts 'selfhost_optional_bind_census: no un-annotated bind of a nilable field'
  exit 0
end

puts "selfhost_optional_bind_census: #{findings.length} un-annotated bind(s) of a nilable field"
findings.each do |file, line, name, owner, field, type|
  puts format('  %s:%d  MUTABLE %s = %s;  -- %s declares %s as %s', file, line, name, field, owner, field, type)
end
exit 1
