#!/usr/bin/env ruby
# frozen_string_literal: true

# Zero-argument calls that are really FIELD reads.
#
# Ruby reaches a Struct member through an accessor -- `arm.body` is a method
# call -- and the translation kept the call syntax. CLEAR has no such accessor
# unless someone wrote one, so `arm.body()` is UNKNOWN_INHERENT_METHOD while
# `arm.body` is correct. The build finds one of these per run, minutes apart.
#
# Reporting them needs the receiver's TYPE, not just its name: `.name()` is a
# field read on MIRIfBinding and a real FN call on Type. So this only reports
# receivers whose type is locally evident -- a `node:` parameter, a `MUTABLE x:
# T` annotation, or a FOR over a field whose element type is declared -- and
# only when no accessor FN of that name exists anywhere.
#
#   ruby tools/selfhost_field_call_census.rb [--root DIR] [--file PATTERN]

require 'optparse'
require 'set'

root = File.expand_path('../compiler/src', __dir__)
file_filter = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_field_call_census.rb [--root DIR] [--file PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--file PATTERN') { |value| file_filter = Regexp.new(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

sources = Dir.glob(File.join(root, '**', '*.clear')).sort

# struct -> Set(field); (struct, field) -> element struct for list-typed
# fields; and the exact accessor names that exist.
#
# All three have to be keyed by the OWNING struct. Keyed by field name alone,
# `arms` resolves to whichever struct was read last and `body` looks like it
# has an accessor because some unrelated struct has one -- which is how a
# first cut of this reported nothing at all.
struct_fields = Hash.new { |hash, key| hash[key] = Set.new }
element_of = {}
accessors = Set.new
sources.each do |path|
  current = nil
  File.readlines(path).each do |line|
    if (match = line.match(/\APUB STRUCT (\w+) \{/))
      current = match[1]
    elsif line.start_with?('}')
      current = nil
    elsif current && (match = line.match(/\A  ([a-z_]\w*): (.+?),?\s*\z/))
      struct_fields[current] << match[1]
      element_of[[current, match[1]]] = Regexp.last_match(1) if match[2] =~ /\A\?*\[\](\w+)\z/
    end
    accessors << Regexp.last_match(1) if line =~ /\A(?:PRIVATE |PUB )?FN (\w+__[a-z_]\w*[?!]?)\(/
  end
end

# `SwitchArm` is reached as `switchArm__body`.
def accessor_name(struct, field)
  "#{struct[0].downcase}#{struct[1..]}__#{field}"
end

findings = []
sources.each do |path|
  relative = path.delete_prefix("#{root}/")
  next if file_filter && !relative.match?(file_filter)

  binding_type = {}
  File.readlines(path).each_with_index do |line, index|
    binding_type = { 'node' => Regexp.last_match(1) } if line =~ /\A(?:PRIVATE |PUB )?FN \w+\(.*?node: (\w+)[,)]/
    binding_type['node'] = nil if line =~ /\A(?:PRIVATE |PUB )?FN / && line !~ /node: \w+[,)]/
    binding_type[Regexp.last_match(1)] = Regexp.last_match(2) if line =~ /MUTABLE (\w+): \??(\w+) =/
    owner = binding_type['node']
    if owner
      if line =~ /FOR (\w+) IN [\w.]*\.([a-z_]\w*)\b/ && element_of[[owner, Regexp.last_match(2)]]
        binding_type[Regexp.last_match(1)] = element_of[[owner, Regexp.last_match(2)]]
      end
      # A pipeline binds `_` to the element type of whatever it selects from,
      # which is where most of these actually live.
      if line =~ /[\w.]*\.([a-z_]\w*) \|> (?:SELECT|WHERE|ANY|ALL|FIND)/ && element_of[[owner, Regexp.last_match(1)]]
        binding_type['_'] = element_of[[owner, Regexp.last_match(1)]]
      end
    end
    next if line.strip.start_with?('#')

    line.scan(/\b(\w+)\.([a-z_]\w*)\(\)/) do |receiver, field|
      type = binding_type[receiver]
      next unless type && struct_fields.key?(type)
      next unless struct_fields[type].include?(field)
      next if accessors.include?(accessor_name(type, field))

      findings << [relative, index + 1, receiver, type, field]
    end
  end
end

if findings.empty?
  puts 'selfhost_field_call_census: no field read written as a call'
  exit 0
end

puts "selfhost_field_call_census: #{findings.length} field read(s) written as a zero-arg call"
findings.first(60).each do |file, line, receiver, type, field|
  puts format('  %s:%d  %s.%s()  -- %s declares %s as a field', file, line, receiver, field, type, field)
end
puts "  ... #{findings.length - 60} more" if findings.length > 60
exit 1
