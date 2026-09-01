#!/usr/bin/env ruby
# frozen_string_literal: true

# Apply the mechanical fixes the per-function probe has already located.
#
# Every failure in .fn_probe.json carries file:line and a diagnostic, so the
# fix is a rewrite of one line rather than a search. Each rule matches one
# diagnostic shape and only rewrites when the shape is unambiguous; anything
# else is left for a human and counted.
#
#   ruby tools/selfhost_fix_located.rb            # dry run
#   ruby tools/selfhost_fix_located.rb --apply
require 'json'
require 'set'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = ARGV.include?('--apply')

variants, = SelfhostUnionAccessor.load_types(ROOT)
defined = Set.new
Dir.glob(File.join(ROOT, '**', '*.clear')).each do |p|
  File.read(p).scan(/\bFN ([\w?!]+)\s*\(/) { |m| defined << m[0] }
end

counts = Hash.new(0)
rows = JSON.parse(File.read(File.expand_path('../.fn_probe.json', __dir__)))
       .select { |r| !r['ok'] && r['line'] }
by = Hash.new { |h, k| h[k] = [] }
rows.each { |r| by[r['file']] << r }

by.each do |file, rs|
  path = File.join(ROOT, file)
  lines = File.readlines(path)
  rs.each do |r|
    ln = r['line']
    next unless (1..lines.length).cover?(ln)

    l = lines[ln - 1]
    e = r['error'].to_s
    before = l.dup

    # A one-element list of an optional where the parameter wants the values.
    if (m = e.match(/expects \[\](\w+), got \[\d+\]\?\1\b/))
      l = l.gsub(/\[([a-z_]\w*)\]/) { "[UNWRAP (#{Regexp.last_match(1)})]" }
      counts[:optional_element] += 1 if l != before
    end

    # String concatenation with an optional operand.
    if e.include?('requires String operands, got ?String')
      l2 = l.gsub(/\$\+ ([a-z_]\w*)(?![\w(])/) { "$+ (#{Regexp.last_match(1)} OR_ELSE \"\")" }
      l2 = l2.gsub(/([a-z_]\w*) \$\+/) { "(#{Regexp.last_match(1)} OR_ELSE \"\") $+" } if l2 == l
      counts[:optional_concat] += 1 if l2 != l
      l = l2
    end

    # IS_A needs the value, not the optional.
    if e =~ /Runtime IS_A requires a union-typed value on the left, got \?(\w+)/
      l2 = l.gsub(/(?<![\w.])([a-z_]\w*) IS_A /) { "UNWRAP (#{Regexp.last_match(1)}) IS_A " }
      counts[:is_a_optional] += 1 if l2 != l
      l = l2
    end

    # A method call on a union.
    if (m = e.match(/Type (\w+) has no inherent METHOD named '(\w+)'/))
      u = m[1]
      meth = m[2]
      fn = "#{u[0].downcase}#{u[1..]}__#{meth}"
      if defined.include?(fn)
        l2 = l.gsub(/(?<![\w.])([a-z_]\w*)\.#{Regexp.escape(meth)}\(\)/) { "#{fn}(#{Regexp.last_match(1)})" }
        counts[:union_method] += 1 if l2 != l
        l = l2
      end
    end

    lines[ln - 1] = l
  end

  # A local passed to a MUTABLE parameter has to be declared MUTABLE.
  rs.each do |r|
    m = r['error'].to_s.match(/is MUTABLE, but you passed immutable variable '(\w+)'/) or next

    name = m[1]
    ln = r['line']
    next unless (1..lines.length).cover?(ln)

    (ln - 1).downto([0, ln - 200].max) do |j|
      break if lines[j] =~ /\A\s*MUTABLE\s+#{Regexp.escape(name)}\b/
      # a struct field, not a local
      next if lines[j] =~ /\A\s+#{Regexp.escape(name)}:\s*[\w@?\[\]{}]+,\s*\z/

      dm = lines[j].match(/\A(\s*)#{Regexp.escape(name)}(\s*[:=])/) or next

      lines[j] = "#{dm[1]}MUTABLE #{name}#{dm[2]}#{lines[j][dm.end(0)..]}"
      counts[:needs_mutable] += 1
      break
    end
  end

  File.write(path, lines.join) if apply
end

puts counts.sort_by { |_, v| -v }.map { |k, v| "#{v} #{k}" }.join(', ')
puts '(dry run -- pass --apply to write)' unless apply
