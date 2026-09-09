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
require 'set'

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
    union = field = only = nil
    setter = false
    OptionParser.new do |parser|
      parser.on('--root DIR') { |v| root = File.expand_path(v) }
      parser.on('--union NAME') { |v| union = v }
      parser.on('--field NAME') { |v| field = v }
      parser.on('--only TYPE', 'Restrict to variants whose field has this type') { |v| only = v }
      # Ruby also WRITES these fields (`node.storage = :stack`). The reader
      # answers respond_to? for a read; a write needs the same variant walk
      # with the assignment in each arm.
      parser.on('--setter', 'Emit the field writer instead of the reader') { setter = true }
    end.parse!(argv)
    abort 'usage: --union NAME --field NAME' unless union && field

    variants, fields = load_types(root)
    members = variants[union] or abort "selfhost_union_accessor: no union '#{union}'"

    carrying = members.select { |_, type| fields[type.sub(/@\w+\z/, '')].key?(field) }
    if carrying.empty?
      # Ruby's respond_to? is as true for a method as for an attribute, so a
      # variant that computes the answer counts as carrying it.
      methods = Set.new
      returns = {}
      Dir.glob(File.join(root, '**', '*.clear')).each do |path|
        body = File.read(path)
        body.scan(/FN ([\w?!]+)\(/) { |m| methods << m[0] }
        body.scan(/FN ([\w?!]+)\([^\n]*?\)\s*RETURNS\s+([\w@?\[\]{}!]+)/) { |n, r| returns[n] = r }
      end
      via = members.filter_map do |name, type|
        bare = type.sub(/@\w+\z/, '')
        callee = "#{bare[0].downcase}#{bare[1..]}__#{field}"
        [name, callee] if methods.include?(callee)
      end
      abort "selfhost_union_accessor: no variant of #{union} carries '#{field}'" if via.empty?

      rets = via.map { |_, m| returns[m].to_s.delete_prefix('!') }.uniq
      abort "selfhost_union_accessor: '#{field}' returns #{rets.inspect}" if rets.length > 1

      result = rets.first.start_with?('?') ? rets.first : "?#{rets.first}"
      fn = "#{union[0].downcase}#{union[1..]}__#{field}"
      fallible = returns[via.first[1]].to_s.start_with?('!')
      puts "# Ruby asks `respond_to?(:#{field})` and then calls it. The variants that"
      puts '# can answer compute it; the rest do not respond.'
      puts "PUB FN #{fn}(value: #{union}) RETURNS #{fallible ? '!' : ''}#{result} EFFECTS REENTRANT ->"
      puts '  PARTIAL MATCH value START'
      via.each do |name, callee|
        call = fallible ? "TRY (#{callee}(item))" : "#{callee}(item)"
        puts "    #{union}.#{name} AS item -> RETURN #{call};,"
      end
      puts '    DEFAULT -> RETURN NIL;'
      puts '  END'
      puts '  RETURN NIL;'
      puts 'END'
      warn "selfhost_union_accessor: #{via.length}/#{members.length} variants compute '#{field}'"
      return 0
    end


    if only
      # Compare the DECLARED type first: `String@symbol` and `String` are
      # different meanings, and stripping the sync would fold them together --
      # which is exactly the ambiguity --only exists to resolve.
      exact = carrying.select do |_, type|
        declared = fields[type.sub(/@\w+\z/, '')][field].to_s.delete_prefix('?')
        declared == only || declared == "[]#{only}"
      end
      carrying = if exact.empty?
        carrying.select do |_, type|
          candidate = fields[type.sub(/@\w+\z/, '')][field].to_s.sub(/@\w+\z/, '').delete_prefix('?')
          candidate == only || candidate == "[]#{only}"
        end
      else
        exact
      end
      abort "selfhost_union_accessor: no variant's '#{field}' is #{only}" if carrying.empty?
    end
    types = carrying.map { |_, type| fields[type.sub(/@\w+\z/, '')][field].delete_prefix('?') }.uniq
    # A field can mean different things on different variants (MIR's `value` is
    # an Emittable on some and a String on others). --only narrows the accessor
    # to one meaning, which is what a call site asking `is_a?` actually wants --
    # so it has to be applied BEFORE the mixed-type refusal it exists to answer.
    abort "selfhost_union_accessor: '#{field}' has mixed types #{types.inspect}" if types.length > 1

    result = types.first
    result = "?#{result}" unless result.start_with?('?')
    fn = "#{union[0].downcase}#{union[1..]}__#{field}"
    if setter
      puts "# Ruby writes `#{field}` on whichever variant it holds. A variant either"
      puts '# carries the field or it does not, so the write lands only where it fits.'
      puts "PUB FN #{fn.sub("__#{field}", "__set_#{field}_mut")}(MUTABLE value: #{union}, new_value: #{result}) RETURNS Void ->"
      puts '  PARTIAL MATCH value START'
      carrying.each do |name, _|
        puts "    #{union}.#{name} AS MUTABLE item -> item.#{field} = COPY new_value;,"
      end
      puts '    DEFAULT -> RETURN;'
      puts '  END'
      puts 'END'
      warn "selfhost_union_accessor: #{carrying.length}/#{members.length} variants carry '#{field}'"
      return 0
    end
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
