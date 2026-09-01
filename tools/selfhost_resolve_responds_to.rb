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
      # A narrowing binds a name to a known type just as a declaration does.
      if (m = line.match(/IS_A\s+([\w@?\[\]{}]+)\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\b/))
        return m[1]
      end
      # `PARTIAL MATCH x START Union.Variant AS name ->` binds the variant type.
      if (m = line.match(/(\w+)\.(\w+)\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*->/))
        return @variant_types&.dig(m[1], m[2]) || m[2]
      end
      # `x EXISTS AS name` binds the narrowed, non-optional form of x.
      if (m = line.match(/([\w.?]+(?:\([^()]*\))?)\s+EXISTS\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\b/))
        inner = receiver_type(lines, i, m[1], fields) if m[1] =~ /\A\w+\z/
        inner ||= @resolve_hook&.call(m[1], lines, i)
        return inner.to_s.delete_prefix('?') if inner
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
  attr_accessor :variant_types
  attr_accessor :resolve_hook

  def resolve(expr, lines, index, fields, variants)
    expr = expr.strip
    if (m = expr.match(/\A([A-Za-z_]\w*)\[[^\]]+\]\??\z/))
      base = receiver_type(lines, index, m[1], fields) or return nil
      return element_of(bare(base))
    end
    # `x.f()` is a call, and the callee declares its return type. Ruby writes
    # the reader and the field the same way, so both spellings resolve here.
    if (m = expr.match(/\A([A-Za-z_][\w.]*)\.([\w?!]+)\(\)\z/))
      base = resolve(m[1], lines, index, fields, variants) or return nil
      ret = @returns_table["#{base[0].downcase}#{base[1..]}__#{m[2]}"] ||
            @returns_table[m[2]]
      return ret && bare(ret.delete_prefix('!'))
    end
    # A plain call: the callee's declared return type is the receiver's type.
    if (m = expr.match(/\A([\w?!]+)\(.*\)\z/m)) && (ret = @returns_table[m[1]])
      return bare(ret.delete_prefix('!'))
    end
    # A field chain: resolve the head, then walk one field at a time.
    if (m = expr.match(/\A([A-Za-z_]\w*)((?:\.\w+)+)\z/))
      type = receiver_type(lines, index, m[1], fields) or return nil
      m[2].split('.').reject(&:empty?).each do |step|
        owner = fields[bare(type)] or return nil
        type = owner[step] or return nil
      end
      return bare(type)
    end
    return nil unless expr =~ /\A[A-Za-z_]\w*\z/

    t = receiver_type(lines, index, expr, fields)
    return bare(t) if t

    inferred = inferred_from_call(lines, index, expr, @returns_table.to_h)
    return bare(inferred) if inferred

    # An unannotated local still has a type: whatever its initializer is.
    rhs = initializer_of(lines, index, expr) or return nil
    resolve(rhs, lines, index, fields, variants)
  end

  # The right-hand side a local was declared with, stripped of the wrappers
  # that do not change its type.
  def initializer_of(lines, index, name)
    index.downto(0) do |i|
      line = lines[i]
      break if line.start_with?('PUB FN', 'FN ', 'PRIVATE FN') && i < index

      m = line.match(/\b(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*=\s*(.+?);?\s*$/) or next

      rhs = m[1].strip
      rhs = rhs.sub(/\A(?:COPY|KEEP|OWN|MOVE|UNWRAP)\s+/, '') while rhs =~ /\A(?:COPY|KEEP|OWN|MOVE|UNWRAP)\s/
      return rhs
    end
    nil
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

    # Every union a given variant type appears in, so a variant can answer
    # through a mixin method that translated to a union-level function.
    enclosing = Hash.new { |h, k| h[k] = [] }
    variants.each { |u, vs| vs.each { |_, ty| enclosing[bare(ty)] << u } }

    # Ruby's respond_to? asks whether the receiver's CLASS defines the name; it
    # is true for a field that happens to be nil. A union answers per variant,
    # so when the variants disagree the question needs a predicate, not the
    # accessor's non-NIL test -- that would silently read "responds" as "set".
    responds_per_variant = lambda do |union, field|
      name = field.delete_suffix('=')
      # Ruby spells a bang method `x!`; it translates with a `_mut` suffix. The
      # AST module form (`aST__x`) answers for Locatable just as `locatable__x`
      # would.
      spellings = [name, name.sub(/!\z/, '_mut'), "#{name}_mut"].uniq
      owner_answers = lambda do |owner|
        forms = ["#{owner[0].downcase}#{owner[1..]}"]
        forms << 'aST' if owner == 'Locatable'
        forms.product(spellings).any? { |f, s| methods.include?("#{f}__#{s}") }
      end
      # A mixin method is defined for every variant at once, so finding it at
      # the union level answers for all of them.
      return variants[union].map { |n, _| [n, true] } if owner_answers.call(union)

      aliases = [name, name.sub(/_info\z/, '_object'), "#{name}_object"]
      variants[union].map do |n, ty|
        b = bare(ty)
        carries = aliases.any? { |a| fields[b]&.key?(a) }
        # A variant also answers through any union it belongs to: that is where
        # a Ruby mixin method lands after translation.
        [n, carries || owner_answers.call(b) || enclosing[b].any? { |u| owner_answers.call(u) }]
      end
    end

    predicate = lambda do |union, field|
      fn = "#{union[0].downcase}#{union[1..]}__responds_to_#{field.delete_suffix('=').delete_suffix('!').delete_suffix('?')}?"
      return fn if methods.include?(fn)

      path = declared[union] or return nil
      per = responds_per_variant.call(union, field)
      body = +"\n# Ruby asks `respond_to?(:#{field})`: a question about the variant, not\n"
      body << "# about whether the value is set.\n"
      body << "PUB FN #{fn}(value: #{union}) RETURNS Bool ->\n  PARTIAL MATCH value START\n"
      per.select { |_, ok| ok }.each { |n, _| body << "    #{union}.#{n} AS item -> RETURN TRUE;,\n" }
      body << "    DEFAULT -> RETURN FALSE;\n  END\n  RETURN FALSE;\nEND\n"
      pending[path] << body
      methods << fn
      fn
    end

    @returns_table = returns
    @variant_types = variants.transform_values { |vs| vs.to_h }
    @resolve_hook = ->(e, ls, ix) { resolve(e, ls, ix, fields, variants) }
    counts = Hash.new(0)
    unresolved = Hash.new(0)
    decided = []
    Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
      lines = File.readlines(path)
      changed = false
      lines.each_with_index do |line, i|
        next unless line.include?('respondsTo?(')

        new = line.gsub(/respondsTo\?\(([^,]+),\s*"([a-zA-Z_?!]+)"\)/) do
          # Hold the match: deciding the answer runs regexes of its own, and
          # `Regexp.last_match` would then no longer name this call site --
          # leaving it would replace the call with an empty string.
          whole = Regexp.last_match(0)
          recv = Regexp.last_match(1)
          field = Regexp.last_match(2)
          type = resolve(recv, lines, i, fields, variants)
          if type.nil?
            unresolved["#{field} <- #{recv.strip}"] += 1
            next whole
          end

          if variants.key?(type)
            per = responds_per_variant.call(type, field)
            if per.all? { |_, ok| ok }
              counts[:true] += 1
              decided << "TRUE   #{field} on #{type}  (#{path.sub(%r{.*/compiler/src/}, '')}:#{i + 1})"
              next 'TRUE'
            end
            if per.none? { |_, ok| ok }
              # Not one variant answers. That is far more often a receiver this
              # tool typed too broadly than a branch Ruby never takes, and
              # writing FALSE would silently delete the behaviour -- so leave it
              # for a human.
              unresolved["#{field} <- #{recv.strip} (no variant of #{type} responds)"] += 1
              next whole
            end

            # The guard is only half the site: whatever Ruby reads next needs
            # an accessor that answers NIL for the variants that do not carry
            # it, so build that at the same time.
            generate.call(type, field)
            fn = predicate.call(type, field)
            unless fn
              unresolved["#{field} <- #{recv.strip} (no predicate for #{type})"] += 1
              next whole
            end

            counts[:union] += 1
            "#{fn}(#{recv})"
          elsif fields.key?(type)
            answer = fields[type].key?(field) ||
                     methods.include?("#{type[0].downcase}#{type[1..]}__#{field}")
            counts[answer ? :true : :false] += 1
            answer ? 'TRUE' : 'FALSE'
          else
            unresolved["#{field} <- #{recv.strip} (unknown type #{type})"] += 1
            whole
          end
        end
        next if new == line

        lines[i] = new
        changed = true
      end
      File.write(path, lines.join) if changed && apply
    end

    pending.each { |path, bodies| File.write(path, File.read(path) + bodies.join) } if apply
    decided.each { |d| puts "  #{d}" }
    puts "generated #{pending.values.sum(&:length)} accessor(s)"
    puts "resolved: #{counts[:union]} union dispatch, #{counts[:true]} TRUE, #{counts[:false]} FALSE"
    puts "unresolved: #{unresolved.values.sum} site(s)"
    unresolved.sort_by { |_, v| -v }.first(15).each { |k, v| puts format('  %-64s %d', k, v) }
    puts '(dry run -- pass --apply to write)' unless apply
    0
  end
end

exit(SelfhostRespondsTo.main(ARGV)) if $PROGRAM_NAME.end_with?('selfhost_resolve_responds_to.rb')
