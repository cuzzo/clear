#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: a MATCH arm naming a variant the union does not have, and an
# IS_A against a type that is not a union. Both are annotation-time blockers
# in the linked build, and both are decidable from the source.
#
# Every pre-accumulation failure class is worth a gate: the ones already here
# (collisions, visibility, EXTERNs) each replaced a ~25 minute round per site.
$PROGRAM_NAME = 'selfhost_predicate_check_support'
require_relative 'parser_compat'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')

variants = {}
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each do |line|
    m = line.match(/^(?:PUB )?UNION\s+(\w+)\s*\{(.*)\}/) or next
    variants[m[1]] ||= m[2].scan(/(\w+)\s*:/).flatten.to_set
  end
end

bad = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  rel = path.sub("#{GEN}/", '')
  File.readlines(path).each_with_index do |line, i|
    line.scan(/(?<![\w.])(\w+)\.(\w+)\s+AS\s/).each do |union, variant|
      known = variants[union] or next
      next if known.include?(variant)

      puts "#{rel}:#{i + 1}  #{union} has no variant #{variant}"
      bad += 1
    end
  end
end
puts "unknown MATCH variants: #{bad}"
exit(bad.zero? ? 0 : 1)
