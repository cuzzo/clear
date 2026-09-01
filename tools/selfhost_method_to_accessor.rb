#!/usr/bin/env ruby
# frozen_string_literal: true

# Rewrite `value.method()` into `union__method(value)` where the receiver is a
# union.
#
# Ruby calls a method on a node; CLEAR has no methods on a union, so the
# translation has to name the accessor. rtoc left the Ruby form in place and
# the compiler reports UNKNOWN_INHERENT_METHOD -- the largest single failure
# class in the per-function probe.
#
# A rewrite happens only when the receiver's type is known AND the accessor
# exists; everything else is reported.
require 'set'
require 'optparse'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = ARGV.include?('--apply')

variants, fields = SelfhostUnionAccessor.load_types(ROOT)
texts = Dir.glob(File.join(ROOT, '**', '*.clear')).sort.to_h { |p| [p, File.read(p)] }
defined = Set.new
returns = {}
texts.each_value do |t|
  t.scan(/\bFN ([\w?!]+)\s*(?:<[^>]*>)?\(/) { |m| defined << m[0] }
  t.scan(/FN ([\w?!]+)\([^\n]*?\)\s*RETURNS\s+([\w@?\[\]{}!]+)/) { |n, r| returns[n] = r }
end

def bare(type) = type.to_s.sub(/@\w+\z/, '').delete_prefix('?')

# The receiver's type, from a declaration, a narrowing, or an initializer.
def type_of(lines, index, name, returns)
  index.downto([0, index - 300].max) do |i|
    l = lines[i]
    return Regexp.last_match(1) if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}:\s*([\w@?\[\]{}]+)/
    return Regexp.last_match(1) if l =~ /IS_A\s+([\w@?\[\]{}]+)\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\b/
    if l =~ /([\w.?]+)\s+EXISTS\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\b/
      inner = Regexp.last_match(1)
      return type_of(lines, i, inner, returns).to_s.delete_prefix('?') if inner =~ /\A\w+\z/
    end
    if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*=\s*(?:TRY \()?\s*([\w?!]+)\(/
      r = returns[Regexp.last_match(1)]
      return r.delete_prefix('!') if r
    end
    break if l.start_with?('PUB FN', 'FN ', 'PRIVATE FN') && i < index && !l.include?("#{name}:")
  end
  nil
end

rewrites = 0
unresolved = Hash.new(0)
texts.each do |path, _|
  lines = File.readlines(path)
  changed = false
  lines.each_with_index do |line, i|
    new = line.gsub(/(?<![\w.])([a-z_]\w*)\.([a-z_]\w*[?!]?)\(\)/) do
      whole = Regexp.last_match(0)
      recv = Regexp.last_match(1)
      meth = Regexp.last_match(2)
      type = type_of(lines, i, recv, returns)
      b = bare(type)
      next whole unless variants.key?(b)

      # A field with different types across variants has no single accessor;
      # the AST module already provides the reader those callers want.
      alias_fn = { %w[Locatable value] => 'aST__node_value', %w[Node value] => 'aST__node_value',
                   %w[Locatable name] => 'aST__node_name', %w[Node name] => 'aST__node_name',
                   %w[Locatable right] => 'aST__node_right' }[[b, meth]]
      if alias_fn && defined.include?(alias_fn)
        rewrites += 1
        next b == 'Node' ? "#{alias_fn}(UNWRAP (castNodeToLocatable(#{recv})))" : "#{alias_fn}(#{recv})"
      end

      fn = "#{b[0].downcase}#{b[1..]}__#{meth}"
      unless defined.include?(fn)
        unresolved["#{b}##{meth}"] += 1
        next whole
      end

      rewrites += 1
      "#{fn}(#{recv})"
    end
    next if new == line

    lines[i] = new
    changed = true
  end
  File.write(path, lines.join) if changed && apply
end

puts "#{rewrites} method calls on a union rewritten to its accessor"
puts "unresolved: #{unresolved.values.sum} (no such accessor)"
unresolved.sort_by { |_, v| -v }.first(10).each { |k, v| puts format('  %-44s %d', k, v) }
puts '(dry run -- pass --apply to write)' unless apply
