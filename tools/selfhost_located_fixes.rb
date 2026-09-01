#!/usr/bin/env ruby
# frozen_string_literal: true

# Apply the fixes the per-function probe's diagnostics fully determine.
#
# Each rule keys off a compiler message that names both the site and the thing
# to change, so nothing is inferred: the argument index, the receiver type, the
# variable name all come from the error text. Run after a probe; the locations
# drift as soon as any file is edited, so re-probe between rounds.
require 'json'
require 'optparse'
require 'set'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
probe = File.expand_path('../.fn_probe.json', __dir__)
apply = false
OptionParser.new do |p|
  p.on('--apply') { apply = true }
  p.on('--probe FILE') { |v| probe = v }
end.parse!

def close_paren(t, i)
  d = 0
  instr = false
  while i < t.length
    c = t[i]
    if instr then instr = false if c == '"'
    elsif c == '"' then instr = true
    elsif c == '(' then d += 1
    elsif c == ')'
      d -= 1
      return i if d.zero?
    end
    i += 1
  end
  nil
end

def arg_spans(t, from, fin)
  spans = []
  d = 0
  start = from
  instr = false
  (from...fin).each do |i|
    c = t[i]
    if instr
      instr = false if c == '"'
      next
    end
    if c == '"'
      instr = true
      next
    end
    d += 1 if '([{'.include?(c)
    d -= 1 if ')]}'.include?(c)
    if c == ',' && d.zero?
      spans << [start, i]
      start = i + 1
    end
  end
  spans << [start, fin]
  spans
end

# The Nth argument of the call whose closing paren reaches the reported line.
def locate_arg(text, offsets, ln, argno)
  (0..8).each do |back|
    idx = ln - 1 - back
    break if idx.negative?

    found = nil
    text[offsets[idx]...offsets[idx + 1]].to_s
        .to_enum(:scan, /(?<![\w.])([a-zA-Z_]\w*[?!]?)\(/).each do
      mm = Regexp.last_match
      open_at = offsets[idx] + mm.end(0) - 1
      fin = close_paren(text, open_at) or next
      next unless fin >= offsets[ln - 1]

      sp = arg_spans(text, open_at + 1, fin)[argno - 1] or next
      found = sp
    end
    return found if found
  end
  nil
end

variants, = SelfhostUnionAccessor.load_types(ROOT)
# variant name keyed by payload type, so `got X` names the variant directly
VARIANT_OF = variants.transform_values do |vs|
  vs.to_h { |name, type| [type.to_s.sub(/@\w+\z/, ''), name] }
end.freeze

CASTS = Dir.glob(File.join(ROOT, '**', '*.clear')).flat_map do |f|
  File.read(f).scan(/\bFN (cast\w+To\w+)\(/).flatten
end.to_set.freeze

rows = JSON.parse(File.read(probe)).select { |r| !r['ok'] && r['line'] && r['error'] }
by = Hash.new { |h, k| h[k] = [] }
rows.each { |r| by[r['file']] << r }

counts = Hash.new(0)
by.each do |f, rs|
  path = File.join(ROOT, f)
  text = File.read(path)
  offsets = [0]
  text.each_line { |l| offsets << offsets.last + l.length }
  edits = []
  line_edits = []
  rs.each do |r|
    e = r['error']
    argno = e[/[Aa]rgument (\d+)/, 1].to_i

    if (m = e.match(/argument \d+ expects ([\w@\[\]{}]+), got \?([\w@\[\]{}]+)\z/)) && m[1] == m[2]
      sp = locate_arg(text, offsets, r['line'], argno) or next
      expr = text[sp[0]...sp[1]].strip
      next if expr.empty? || expr.start_with?('UNWRAP')

      edits << [sp[0], sp[1], " UNWRAP (#{expr})", :unwrap_arg]
    elsif (m = e.match(/argument \d+ expects (\w+), got (\w+)\z/)) && VARIANT_OF[m[1]]&.key?(m[2])
      sp = locate_arg(text, offsets, r['line'], argno) or next
      expr = text[sp[0]...sp[1]].strip
      next if expr.empty? || expr.start_with?("#{m[1]}{")

      edits << [sp[0], sp[1], " #{m[1]}{ #{VARIANT_OF[m[1]][m[2]]}: COPY #{expr} }", :wrap_variant]
    elsif (m = e.match(/argument \d+ expects (\w+), got (\w+)\z/)) && CASTS.include?("cast#{m[2]}To#{m[1]}")
      sp = locate_arg(text, offsets, r['line'], argno) or next
      expr = text[sp[0]...sp[1]].strip
      next if expr.empty? || expr.start_with?('cast')

      edits << [sp[0], sp[1], " UNWRAP (cast#{m[2]}To#{m[1]}(#{expr}))", :cast_arg]
    elsif (m = e.match(/Pass '(\w+)' as '&\w+'/))
      sp = locate_arg(text, offsets, r['line'], argno) or next
      expr = text[sp[0]...sp[1]].strip
      next unless expr =~ /\A#{m[1]}(\.|\z)/

      edits << [sp[0], sp[1], " &#{expr}", :mutable_arg]
    elsif (m = e.match(/passed immutable variable '(\w+)'/))
      line_edits << [r['line'], :declare_mutable, m[1]]
    elsif e.include?('UNWRAP_NON_OPTIONAL')
      line_edits << [r['line'], :drop_unwrap, nil]
    end
  end

  edits.uniq!
  edits.sort_by!(&:first)
  edits.reverse_each do |a, b, s, kind|
    text = text[0...a] + s + text[b..]
    counts[kind] += 1
  end

  lines = text.lines
  line_edits.uniq.each do |ln, kind, name|
    i = ln - 1
    next unless lines[i]

    case kind
    when :declare_mutable
      j = i
      while j >= 0
        break if lines[j] =~ /^(PUB |PRIVATE )?FN /

        if lines[j] =~ /\bAS\s+#{name}\b/ && lines[j] !~ /AS\s+MUTABLE\s+#{name}\b/
          lines[j] = lines[j].sub(/\bAS\s+#{name}\b/, "AS MUTABLE #{name}")
          counts[kind] += 1
          break
        elsif lines[j] =~ /^(\s*)#{name}\s*(:[^=]*)?=/ && lines[j] !~ /\bMUTABLE\b/
          lines[j] = lines[j].sub(/^(\s*)#{name}\b/) { "#{Regexp.last_match(1)}MUTABLE #{name}" }
          counts[kind] += 1
          break
        end
        j -= 1
      end
    when :drop_unwrap
      # Two spellings reach the same diagnostic. Rewrite only when the line
      # offers exactly one candidate, so no guess is needed about which
      # subexpression the compiler meant.
      safe_nav = lines[i].scan(/\w\?\./).length
      unwraps = lines[i].scan(/\bUNWRAP\s*\(/).length
      if safe_nav == 1 && unwraps.zero?
        lines[i] = lines[i].sub(/(\w)\?\./) { "#{Regexp.last_match(1)}." }
        counts[kind] += 1
      elsif unwraps == 1 && safe_nav.zero?
        at = lines[i].index(/\bUNWRAP\s*\(/)
        open_at = lines[i].index('(', at)
        fin = close_paren(lines[i], open_at)
        if fin
          inner = lines[i][(open_at + 1)...fin].strip
          lines[i] = lines[i][0...at] + inner + lines[i][(fin + 1)..]
          counts[kind] += 1
        end
      end
    end
  end
  File.write(path, lines.join) if apply
end

counts.sort_by { |_, v| -v }.each { |k, v| puts format('  %-16s %d', k, v) }
puts "total #{counts.values.sum}"
puts '(dry run -- pass --apply to write)' unless apply
