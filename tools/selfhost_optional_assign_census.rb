#!/usr/bin/env ruby
# frozen_string_literal: true

# Optionals assigned into non-optional locals.
#
# `capture_name = payload` where capture_name is a String and payload is a
# ?String. Ruby has no such distinction, so the translation writes the
# assignment straight across and CLEAR rejects it -- one per build.
#
# Both sides have to be typed to report this, and narrowing has to be
# respected: a nil check makes the right-hand side a plain String for the rest
# of its branch, and an earlier census that ignored that turned seven correct
# lines into errors of its own.
#
#   ruby tools/selfhost_optional_assign_census.rb [--root DIR] [--file PATTERN]

require 'optparse'

root = File.expand_path('../compiler/src', __dir__)
file_filter = nil
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby tools/selfhost_optional_assign_census.rb [--root DIR] [--file PATTERN]'
  parser.on('--root DIR') { |value| root = File.expand_path(value) }
  parser.on('--file PATTERN') { |value| file_filter = Regexp.new(value) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!(ARGV)

findings = []
Dir.glob(File.join(root, '**', '*.clear')).sort.each do |path|
  relative = path.delete_prefix("#{root}/")
  next if file_filter && !relative.match?(file_filter)

  declared = {}
  narrowed = {}
  File.readlines(path).each_with_index do |line, index|
    if line =~ /\A(?:PRIVATE |PUB )?FN /
      declared = {}
      narrowed = {}
    end
    declared[Regexp.last_match(1)] = Regexp.last_match(2) if line =~ /MUTABLE (\w+): (\??[\w@\[\]]+) =/
    line.scan(/(\w+) (?:!= NIL|EXISTS)/) { |(name)| narrowed[name] = true }

    next unless line =~ /\A\s*(\w+) = (\w+);\s*\z/

    target = Regexp.last_match(1)
    source = Regexp.last_match(2)
    target_type = declared[target]
    source_type = declared[source]
    next unless target_type && source_type
    next if target_type.start_with?('?') || !source_type.start_with?('?')
    next if narrowed[source]

    findings << [relative, index + 1, target, target_type, source, source_type]
  end
end

if findings.empty?
  puts 'selfhost_optional_assign_census: no optional assigned to a non-optional local'
  exit 0
end

puts "selfhost_optional_assign_census: #{findings.length} optional(s) assigned to a non-optional local"
findings.each do |file, line, target, target_type, source, source_type|
  puts format('  %s:%d  %s = %s;  -- %s is %s, %s is %s',
              file, line, target, source, target, target_type, source, source_type)
end
exit 1
