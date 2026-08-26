#!/usr/bin/env ruby
# frozen_string_literal: true

# Optionals used where CLEAR requires a String.
#
# Ruby renders a nil inside `"#{...}"` as the empty string; CLEAR rejects a
# `?String` outright. The translation carries the interpolation over unchanged,
# so every optional that reaches one is an error the build reports one at a
# time.
#
# Two sources of optionals are tracked, both keyed precisely: a field read
# whose OWNING struct declares it optional, and a local annotated `?T`. A
# field-name-only version of this reported 56 candidates where 11 were real,
# because `name` is a String on FnDef and optional on MIRStructDef.
#
#   ruby tools/selfhost_optional_interp_census.rb [--root DIR] [--file PATTERN]

require 'optparse'

root = File.expand_path('../compiler/src', __dir__)
file_filter = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_optional_interp_census.rb [--root DIR] [--file PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--file PATTERN') { |value| file_filter = Regexp.new(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

sources = Dir.glob(File.join(root, '**', '*.clear')).sort

field_type = Hash.new { |hash, key| hash[key] = {} }
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
  end
end

findings = []
sources.each do |path|
  relative = path.delete_prefix("#{root}/")
  next if file_filter && !relative.match?(file_filter)

  owner = nil
  optional_locals = {}
  File.readlines(path).each_with_index do |line, index|
    if line =~ /\A(?:PRIVATE |PUB )?FN \w+\(.*?node: (\w+)[,)]/
      owner = Regexp.last_match(1)
      optional_locals = {}
    elsif line =~ /\A(?:PRIVATE |PUB )?FN /
      owner = nil
      optional_locals = {}
    end
    optional_locals[Regexp.last_match(1)] = Regexp.last_match(2) if line =~ /MUTABLE (\w+): (\?\w[\w@\[\]]*) =/
    # A nil check narrows the binding for the rest of its branch, so an
    # interpolation after one is already a plain String. Reporting those
    # produced an OR_ELSE on a non-optional -- the opposite error.
    line.scan(/(\w+) (?:!= NIL|EXISTS)/) { |(narrowed)| optional_locals.delete(narrowed) }
    next if line.strip.start_with?('#')

    line.scan(/\$\{([a-z_]\w*)\}/) do |(name)|
      next unless optional_locals.key?(name)

      findings << [relative, index + 1, name, optional_locals[name], 'local']
    end
    next unless owner

    line.scan(/\$\{node\.([a-z_]\w*)\}/) do |(field)|
      type = field_type[owner][field]
      next unless type&.start_with?('?')

      findings << [relative, index + 1, "node.#{field}", type, owner]
    end
  end
end

if findings.empty?
  puts 'selfhost_optional_interp_census: no optional interpolated as a String'
  exit 0
end

puts "selfhost_optional_interp_census: #{findings.length} optional(s) interpolated as a String"
findings.each do |file, line, name, type, source|
  puts format('  %s:%d  ${%s}  -- %s (%s)', file, line, name, type, source)
end
exit 1
