#!/usr/bin/env ruby
# frozen_string_literal: true

# Struct literals that pass NIL to a field that is not optional.
#
# Ruby lets a Struct field be nil until something sets it; CLEAR types the
# field, so rtoc's `field: NIL` is a type error at every such site. The
# compiler reports one per build, and each build of a top-of-graph unit costs
# tens of minutes -- so find them all at once instead.
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
_variants, fields = SelfhostUnionAccessor.load_types(ROOT)

found = Hash.new { |h, k| h[k] = [] }
Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
  rel = path[(ROOT.length + 1)..]
  File.readlines(path).each_with_index do |line, index|
    line.scan(/\b([A-Z]\w*)\{([^{}]*)\}/) do |type, body|
      declared = fields[type] or next

      body.scan(/(\w+):\s*NIL\b/) do |(field)|
        kind = declared[field] or next
        next if kind.start_with?('?')

        found["#{type}.#{field}: #{kind}"] << "#{rel}:#{index + 1}"
      end
    end
  end
end

puts "#{found.values.sum(&:size)} site(s) pass NIL to a non-optional field"
found.sort_by { |_, v| -v.size }.each do |what, where|
  puts format('  %-58s %d  %s', what, where.size, where.first)
end
