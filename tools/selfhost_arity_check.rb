#!/usr/bin/env ruby
# frozen_string_literal: true

# Report calls whose argument count does not match the callee's signature.
#
# The annotator package reports one type error per compile, at roughly an hour
# each, so a mismatch found statically is an hour saved. Splitting on top-level
# commas has to respect string literals: `match_mut(self, :CHAR, ",")` is three
# arguments, not four.
#
# The byte-compatible parser is the control: a mismatch reported inside
# compiler/src/ast/parser* is this tool being wrong, not the tree.
ROOT = File.expand_path('../compiler/src', __dir__)

def split_args(s)
  # A generic argument list carries its own commas: `Tuple<Bool, T>` is one
  # type, not two. Collapse them before splitting.
  s = s.gsub(/<[^<>]*>/) { |g| g.tr(',', "\u0000") }
  out = []; depth = 0; cur = +''; instr = false; esc = false; interp = 0
  s.each_char do |ch|
    if instr
      cur << ch
      if esc then esc = false
      elsif ch == '\\' then esc = true
      elsif ch == '{' && cur[-2] == '$' then interp += 1
      elsif ch == '}' && interp.positive? then interp -= 1
      elsif ch == '"' && interp.zero? then instr = false
      end
      next
    end
    if ch == '"' then instr = true; cur << ch; next end
    depth += 1 if '([{'.include?(ch)
    depth -= 1 if ')]}'.include?(ch)
    if ch == ',' && depth.zero? then out << cur; cur = +''
    else cur << ch
    end
  end
  out << cur unless cur.strip.empty?
  out.map { |x| x.tr("\u0000", ',') }
end

def close_paren(text, open_at)
  k = open_at; depth = 0; instr = false; esc = false; interp = 0
  while k < text.length
    ch = text[k]
    if instr
      if esc then esc = false
      elsif ch == '\\' then esc = true
      elsif ch == '{' && text[k - 1] == '$' then interp += 1
      elsif ch == '}' && interp.positive? then interp -= 1
      elsif ch == '"' && interp.zero? then instr = false
      end
    elsif ch == '"' then instr = true
    elsif ch == '(' then depth += 1
    elsif ch == ')'
      depth -= 1
      return k if depth.zero?
    end
    k += 1
  end
  nil
end

sigs = {}
texts = Dir.glob(File.join(ROOT, '**', '*.clear')).sort.to_h { |p| [p, File.read(p)] }
texts.each_value do |t|
  # The parameter list has to be closed by balance, not by the first `)`: a
  # parameter typed `[]FN() -> T` closes one of its own.
  t.to_enum(:scan, /^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(/).each do
    m = Regexp.last_match
    fin = close_paren(t, m.end(0) - 1) or next
    ps = split_args(t[m.end(0)...fin])
    sigs[m[1]] ||= [ps.count { |x| !x.split(':', 2).last.to_s.include?('=') }, ps.length]
  end
end

bad = []
texts.each do |path, t|
  t.to_enum(:scan, /(?<![\w.])([a-z]\w*__[\w?!]+)\(/).each do
    m = Regexp.last_match
    # a comment mentioning a call is not a call
    line_start = t.rindex("\n", m.begin(0)).to_i + 1
    next if t[line_start...m.begin(0)] =~ /(?<!")#/

    name = m[1]
    lo, hi = sigs[name]
    next unless lo

    fin = close_paren(t, m.end(0) - 1) or next
    n = split_args(t[m.end(0)...fin]).count { |a| !a.strip.empty? }
    next if n >= lo && n <= hi

    bad << [path.sub("#{ROOT}/", ''), t[0...m.begin(0)].count("\n") + 1, name, n, lo, hi]
  end
end

parser = bad.count { |b| b[0].start_with?('ast/parser') }
puts "#{bad.length} arity mismatches (#{parser} inside the parser, i.e. this tool being wrong)"
bad.group_by { |b| b[2] }.sort_by { |_, v| -v.length }.first(12).each do |name, v|
  lo, hi = sigs[name]
  puts format('  %3d  %-46s wants %d..%d, got %s', v.length, name, lo, hi, v.map { |x| x[3] }.uniq.sort.join('/'))
  v.first(2).each { |b| puts format('        %s:%d', b[0], b[1]) } if ARGV.include?('--where')
end
