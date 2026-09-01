#!/usr/bin/env ruby
# frozen_string_literal: true

# Wrap the anchor argument of every diagnostic call in a DiagnosticAnchor.
#
# Ruby's `error!(node_or_token, ...)` takes anything; CLEAR needs one type, and
# `DiagnosticAnchor` is it -- a Token or a Locatable. The translation passes the
# receiver bare, so every one of ~730 call sites is an ARGUMENT_TYPE_ERROR the
# package reports one at a time, at roughly an hour each.
#
# The wrap depends on what the argument IS, so each is resolved from its
# declaration, narrowing, or the call that produced it. Anything unresolved is
# reported rather than guessed.
require 'set'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = ARGV.include?('--apply')

variants, fields = SelfhostUnionAccessor.load_types(ROOT)
locatable = variants['Locatable'].to_h { |name, type| [type.sub(/@\w+\z/, ''), name] }
$VARIANT_TYPES = variants.transform_values(&:to_h)

returns = {}
Dir.glob(File.join(ROOT, '**', '*.clear')).each do |p|
  File.read(p).scan(/FN ([\w?!]+)\([^\n]*?\)\s*RETURNS\s+([\w@?\[\]{}!]+)/) { |n, r| returns[n] = r }
end

def bare(type) = type.to_s.sub(/@\w+\z/, '').delete_prefix('?')

# The declared type of `name`, searched upward from the call.
def type_of(lines, index, name, returns)
  index.downto([0, index - 400].max) do |i|
    l = lines[i]
    return Regexp.last_match(1) if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}:\s*([\w@?\[\]{}]+)/
    return Regexp.last_match(1) if l =~ /IS_A\s+([\w@?\[\]{}]+)\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\b/
    if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*=\s*(?:TRY \()?\s*([\w?!]+)\(/
      r = returns[Regexp.last_match(1)]
      return r.delete_prefix('!') if r
    end
    # `x EXISTS AS name` narrows x; `Union.Variant AS name ->` binds the variant.
    if l =~ /(\w+)\s+EXISTS\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\b/
      inner = type_of(lines, i, Regexp.last_match(1), returns)
      return inner.delete_prefix('?') if inner
    end
    if l =~ /(\w+)\.(\w+)\s+AS\s+(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*->/
      return $VARIANT_TYPES&.dig(Regexp.last_match(1), Regexp.last_match(2)) || Regexp.last_match(2)
    end
    # An unannotated local takes the type of a simple initializer.
    if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*=\s*(?:COPY |KEEP |OWN )?(\w+);?\s*$/
      other = Regexp.last_match(1)
      return type_of(lines, i, other, returns) unless other == name
    end
    break if l.start_with?('PUB FN', 'FN ', 'PRIVATE FN') && i < index && !l.include?("#{name}:")
  end
  nil
end

CALL = /(\w+__(?:error_mut|fixable_mut|note_mut))\(\s*(\w+),\s*(\w+),/
wrapped = 0
casts = Set.new
unresolved = Hash.new(0)
Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
  # The parser is byte compatible and compiles: its `error_mut` takes a bare
  # ?Token, so wrapping there would break what already works.
  next if path.include?('/ast/parser')

  lines = File.readlines(path)
  changed = false
  lines.each_with_index do |line, i|
    new = line.gsub(CALL) do
      whole = Regexp.last_match(0)
      fn = Regexp.last_match(1)
      recv = Regexp.last_match(2)
      anchor = Regexp.last_match(3)
      type = type_of(lines, i, anchor, returns)
      b = bare(type)
      inner =
        if b == 'Token' then "DiagnosticAnchor{ TokenValue: COPY #{anchor} }"
        elsif b == 'Locatable' then "DiagnosticAnchor{ Locatable: COPY #{anchor} }"
        elsif b == 'AnchorToken' then "DiagnosticAnchor{ AnchorTokenValue: COPY #{anchor} }"
        elsif b == 'DiagnosticAnchor' then nil
        elsif locatable.key?(b) then "DiagnosticAnchor{ Locatable: Locatable{ #{locatable[b]}: COPY #{anchor} } }"
        elsif variants.key?(b) && variants[b].any? { |_, ty| locatable.key?(bare(ty)) }
          # A materialized union of AST nodes: cast to Locatable, which answers
          # NIL for a variant that is not one, and let the anchor be optional.
          casts << b
          "diagnosticAnchor__of(cast#{b}ToLocatable(#{anchor}))"
        else
          unresolved["#{anchor} (#{type || 'unknown'})"] += 1
          nil
        end
      next whole unless inner

      wrapped += 1
      "#{fn}(#{recv}, #{inner},"
    end
    next if new == line

    lines[i] = new
    changed = true
  end
  File.write(path, lines.join) if changed && apply
end

puts "casts needed: #{casts.to_a.sort.join(', ')}" unless casts.empty?
puts "wrapped #{wrapped} anchor argument(s)"
puts "unresolved: #{unresolved.values.sum}"
unresolved.sort_by { |_, v| -v }.first(10).each { |k, v| puts format('  %-46s %d', k, v) }
puts '(dry run -- pass --apply to write)' unless apply
