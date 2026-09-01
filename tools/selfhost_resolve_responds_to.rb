#!/usr/bin/env ruby
# frozen_string_literal: true

# Answer rtoc's `respondsTo?` placeholders.
#
# Ruby asks `node.respond_to?(:f)` before reading `node.f`. rtoc emits that as
# `respondsTo?(node, "f")`, which nothing implements -- every one of the sites
# is a wall. But the question is answerable from the declared types:
#
#   * a struct receiver either has the field or it does not, so the call is a
#     literal TRUE or FALSE;
#   * a union receiver answers per variant at runtime, which is exactly what
#     the generated `union__f` accessor reports -- non-NIL means it responds.
#
# Only rewrites where the receiver's type is certain; everything else is
# reported so a human sees precisely what is left.
require 'set'
require_relative 'selfhost_union_accessor'

module SelfhostRespondsTo
  extend self

  ROOT = File.expand_path('../compiler/src', __dir__)

  # A local with no annotation still has a type when it is assigned the
  # result of a call: the callee declares one.
  def inferred_from_call(lines, index, name, returns)
    (index).downto(0) do |i|
      line = lines[i]
      break if line.start_with?('PUB FN', 'FN ', 'PRIVATE FN') && i < index

      m = line.match(/\b(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*=\s*(?:TRY \()?\s*([\w?!]+)\(/)
      next unless m

      declared = returns[m[1]] or next
      return declared.delete_prefix('!')
    end
    nil
  end

  # Declared type of a local, parameter, or field, searched from the site
  # upwards within the enclosing function.
  def receiver_type(lines, index, name, fields)
    (index).downto(0) do |i|
      line = lines[i]
      break if line.start_with?('PUB FN', 'FN ', 'PRIVATE FN') && i < index &&
               !line.include?("#{name}:")

      if (m = line.match(/\b(?:MUTABLE\s+)?#{Regexp.escape(name)}:\s*([\w@?\[\]{}]+)/))
        return m[1]
      end
    end
    nil
  end

  def element_of(type)
    return Regexp.last_match(1) if type =~ /\A\[\](.+)\z/
    return Regexp.last_match(1) if type =~ /\A(.+)\[\]\z/

    nil
  end

  def bare(type)
    type.to_s.sub(/@\w+\z/, '').delete_prefix('?')
  end

  # The receiver expression, reduced to a declared type where that is certain.
  attr_accessor :returns_table

  def resolve(expr, lines, index, fields, variants)
    expr = expr.strip
    if (m = expr.match(/\A([A-Za-z_]\w*)\[[^\]]+\]\??\z/))
      base = receiver_type(lines, index, m[1], fields) or return nil
      return element_of(bare(base))
    end
    if (m = expr.match(/\A([A-Za-z_]\w*)\.(\w+)\z/))
      base = receiver_type(lines, index, m[1], fields) or return nil
      owner = fields[bare(base)] or return nil
      return bare(owner[m[2]]) if owner[m[2]]

      return nil
    end
    return nil unless expr =~ /\A[A-Za-z_]\w*\z/

    t = receiver_type(lines, index, expr, fields)
    return bare(t) if t

    inferred = inferred_from_call(lines, index, expr, @returns_table.to_h)
    inferred && bare(inferred)
  end

  def main(argv)
    apply = argv.include?('--apply')
    variants, fields = SelfhostUnionAccessor.load_types(ROOT)
    methods = Set.new
    # Declared return type per function, so a method-backed accessor can state
    # what it hands back.
    returns = {}
    Dir.glob(File.join(ROOT, '**', '*.clear')).each do |p|
      body = File.read(p)
      body.scan(/FN ([\w?!]+)\(/) { |m| methods << m[0] }
      body.scan(/FN ([\w?!]+)\([^\n]*?\)\s*RETURNS\s+([\w@?\[\]{}!]+)/) { |n, r| returns[n] = r }
    end

    # Where each union is declared, so a generated accessor lands beside it.
    declared = {}
    Dir.glob(File.join(ROOT, '**', '*.clear')).each do |p|
      File.foreach(p) { |l| (m = l.match(/^(?:PUB )?UNION (\w+) \{/)) && declared[m[1]] = p }
    end
    pending = Hash.new { |h, k| h[k] = [] }

    # The accessor a union needs to answer `respond_to?(:field)`, built only
    # when every variant that carries the field agrees on its type.
    generate = lambda do |union, field|
      fn = "#{union[0].downcase}#{union[1..]}__#{field}"
      return nil if methods.include?(fn)

      path = declared[union] or return nil
      carrying = variants[union].select { |_, t| fields[bare(t)].key?(field) }
      if carrying.empty?
        # No variant stores it, but variants may compute it: Ruby's
        # respond_to? is true for a method just as much as an attribute.
        via = variants[union].filter_map do |n, t|
          b = bare(t)
          m = "#{b[0].downcase}#{b[1..]}__#{field}"
          [n, m] if methods.include?(m)
        end
        return nil if via.empty?

        rets = via.map { |_, m| returns[m].to_s.delete_prefix('!').delete_prefix('?') }.uniq
        return nil if rets.length != 1 || rets.first.empty?

        result = "?#{rets.first}"
        body = +"\n# Ruby asks `respond_to?(:#{field})` and then reads it. The variants that\n"
        body << "# can answer compute it; the rest do not respond.\n"
        body << "PUB FN #{fn}(value: #{union}) RETURNS #{result} ->\n  PARTIAL MATCH value START\n"
        via.each { |n, m| body << "    #{union}.#{n} AS item -> RETURN #{m}(item);,\n" }
        body << "    DEFAULT -> RETURN NIL;\n  END\n  RETURN NIL;\nEND\n"
        pending[path] << body
        methods << fn
        return fn
      end

      types = carrying.map { |_, t| fields[bare(t)][field].delete_prefix('?') }.uniq
      return nil if types.length > 1

      result = types.first.start_with?('?') ? types.first : "?#{types.first}"
      body = +"\n# Ruby asks `respond_to?(:#{field})` and then reads it. A union variant\n"
      body << "# either carries the field or it does not, so the question is answered here.\n"
      body << "PUB FN #{fn}(value: #{union}) RETURNS #{result} ->\n  PARTIAL MATCH value START\n"
      carrying.each { |n, _| body << "    #{union}.#{n} AS item -> RETURN COPY item.#{field};,\n" }
      body << "    DEFAULT -> RETURN NIL;\n  END\n  RETURN NIL;\nEND\n"
      pending[path] << body
      methods << fn
      fn
    end

    @returns_table = returns
    counts = Hash.new(0)
    unresolved = Hash.new(0)
    Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
      lines = File.readlines(path)
      changed = false
      lines.each_with_index do |line, i|
        next unless line.include?('respondsTo?(')

        new = line.gsub(/respondsTo\?\(([^,]+),\s*"([a-zA-Z_?!]+)"\)/) do
          recv = Regexp.last_match(1)
          field = Regexp.last_match(2)
          type = resolve(recv, lines, i, fields, variants)
          if type.nil?
            unresolved["#{field} <- #{recv.strip}"] += 1
            next Regexp.last_match(0)
          end

          if variants.key?(type)
            fn = "#{type[0].downcase}#{type[1..]}__#{field}"
            unless methods.include?(fn) || generate.call(type, field)
              unresolved["#{field} <- #{recv.strip} (no #{fn})"] += 1
              next Regexp.last_match(0)
            end

            counts[:union] += 1
            "(#{fn}(#{recv}) != NIL)"
          elsif fields.key?(type)
            answer = fields[type].key?(field) ||
                     methods.include?("#{type[0].downcase}#{type[1..]}__#{field}")
            counts[answer ? :true : :false] += 1
            answer ? 'TRUE' : 'FALSE'
          else
            unresolved["#{field} <- #{recv.strip} (unknown type #{type})"] += 1
            Regexp.last_match(0)
          end
        end
        next if new == line

        lines[i] = new
        changed = true
      end
      File.write(path, lines.join) if changed && apply
    end

    pending.each { |path, bodies| File.write(path, File.read(path) + bodies.join) } if apply
    puts "generated #{pending.values.sum(&:length)} accessor(s)"
    puts "resolved: #{counts[:union]} union dispatch, #{counts[:true]} TRUE, #{counts[:false]} FALSE"
    puts "unresolved: #{unresolved.values.sum} site(s)"
    unresolved.sort_by { |_, v| -v }.first(15).each { |k, v| puts format('  %-64s %d', k, v) }
    puts '(dry run -- pass --apply to write)' unless apply
    0
  end
end

exit(SelfhostRespondsTo.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_resolve_responds_to.rb')
