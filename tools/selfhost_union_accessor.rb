#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate a union-level field accessor.
#
# Ruby asks `node.respond_to?(:f)` and then reads `node.f`. CLEAR has no
# reflection, but the question is answerable statically: a union variant either
# carries the field or it does not. The faithful translation is one accessor
# that returns the field for the variants that have it and NIL for the rest --
# so `respond_to?(:f) && node.f.is_a?(T)` becomes `accessor(node) EXISTS`.
#
# Writing those by hand is the bulk of the reflection class (124 respondsTo?
# sites), and each is a mechanical read of the union's variants.
#
#   ruby tools/selfhost_union_accessor.rb --union Emittable --field ownership_consumption
require 'optparse'

module SelfhostUnionAccessor
  extend self

  def load_types(root)
    variants = {}
    fields = Hash.new { |h, k| h[k] = {} }
    current = nil
    Dir.glob(File.join(root, '**', '*.clear')).sort.each do |path|
      File.readlines(path).each do |line|
        if (union = line.match(/^(?:PUB )?UNION (\w+) \{(.*)\}\s*$/))
          variants[union[1]] = union[2].split(',').filter_map do |member|
            name, type = member.split(':', 2)
            next unless name && type

            [name.strip, type.strip]
          end
          current = nil
          next
        end
        if (struct = line.match(/^(?:PUB )?STRUCT (\w+) \{/))
          current = struct[1]
          next
        end
        if current
          if line.strip.start_with?('}')
            current = nil
          elsif (field = line.match(/^\s*(\w+):\s*(.+?),?\s*$/))
            fields[current][field[1]] = field[2]
          end
        end
      end
    end
    [variants, fields]
  end

  def main(argv)
    root = File.expand_path('compiler/src', __dir__ + '/..')
    union = field = nil
    OptionParser.new do |parser|
      parser.on('--root DIR') { |v| root = File.expand_path(v) }
      parser.on('--union NAME') { |v| union = v }
      parser.on('--field NAME') { |v| field = v }
    end.parse!(argv)
    abort 'usage: --union NAME --field NAME' unless union && field

    variants, fields = load_types(root)
    members = variants[union] or abort "selfhost_union_accessor: no union '#{union}'"

    carrying = members.select { |_, type| fields[type.sub(/@\w+\z/, '')].key?(field) }
    abort "selfhost_union_accessor: no variant of #{union} carries '#{field}'" if carrying.empty?

    types = carrying.map { |_, type| fields[type.sub(/@\w+\z/, '')][field] }.uniq
    abort "selfhost_union_accessor: '#{field}' has mixed types #{types.inspect}" if types.length > 1

    result = types.first
    result = "?#{result}" unless result.start_with?('?')
    fn = "#{union[0].downcase}#{union[1..]}__#{field}"
    puts "# Ruby asks `respond_to?(:#{field})` and then reads it. A union variant"
    puts "# either carries the field or it does not, so the question is answered here:"
    puts "# the variants that have it return it, the rest return NIL."
    puts "PUB FN #{fn}(value: #{union}) RETURNS #{result} ->"
    puts "  PARTIAL MATCH value START"
    carrying.each { |name, _| puts "    #{union}.#{name} AS item -> RETURN COPY item.#{field};," }
    puts "    DEFAULT -> RETURN NIL;"
    puts '  END'
    puts '  RETURN NIL;'
    puts 'END'
    warn "selfhost_union_accessor: #{carrying.length}/#{members.length} variants carry '#{field}'"
    0
  end
end

exit(SelfhostUnionAccessor.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_union_accessor.rb')
