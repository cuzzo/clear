#!/usr/bin/env ruby
# frozen_string_literal: true

# Unwrap arguments passed as `?T` where the parameter is `T`.
#
# Ruby has no optional/non-optional distinction, so the translation hands an
# optional straight to a parameter that requires a value. This is the largest
# ARGUMENT_TYPE_ERROR shape in the per-function probe.
#
# An argument is only unwrapped when its type is KNOWN and the parameter's type
# is exactly the same minus the `?`. Anything else is reported.
require 'set'
require 'optparse'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = ARGV.include?('--apply')

def close_paren(t, i)
  depth = 0
  instr = false
  while i < t.length
    c = t[i]
    if instr then instr = false if c == '"'
    elsif c == '"' then instr = true
    elsif c == '(' then depth += 1
    elsif c == ')'
      depth -= 1
      return i if depth.zero?
    end
    i += 1
  end
  nil
end

def split_args(s)
  out = []
  depth = 0
  cur = +''
  instr = false
  s.each_char do |c|
    if instr
      cur << c
      instr = false if c == '"'
      next
    end
    if c == '"' then instr = true; cur << c; next end
    depth += 1 if '([{'.include?(c)
    depth -= 1 if ')]}'.include?(c)
    if c == ',' && depth.zero? then out << cur; cur = +''
    else cur << c
    end
  end
  out << cur unless cur.strip.empty?
  out
end

texts = Dir.glob(File.join(ROOT, '**', '*.clear')).sort.to_h { |p| [p, File.read(p)] }
sigs = {}
returns = {}
texts.each_value do |t|
  t.to_enum(:scan, /^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(/).each do
    m = Regexp.last_match
    fin = close_paren(t, m.end(0) - 1) or next
    params = split_args(t[m.end(0)...fin]).map { |p| p.split(':', 2)[1].to_s.split('=').first.to_s.strip }
    sigs[m[1]] ||= params
    ret = t[fin..(fin + 200)].to_s[/\A\)\s*(?:\n\s*REQUIRES[^\n]*)*\s*RETURNS\s+([\w@?\[\]{}!]+)/m, 1]
    returns[m[1]] ||= ret if ret
  end
end

# The declared type of a local, from a declaration or a call that produced it.
def type_of(lines, index, name, returns)
  index.downto([0, index - 200].max) do |i|
    l = lines[i]
    return Regexp.last_match(1) if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}:\s*([\w@?\[\]{}]+)/
    if l =~ /\b(?:MUTABLE\s+)?#{Regexp.escape(name)}\s*=\s*(?:TRY \()?\s*([\w?!]+)\(/
      r = returns[Regexp.last_match(1)]
      return r.delete_prefix('!') if r
    end
    break if l.start_with?('PUB FN', 'FN ', 'PRIVATE FN') && i < index && !l.include?("#{name}:")
  end
  nil
end

wrapped = 0
skipped = Hash.new(0)
texts.each_key do |path|
  next if path.include?('/ast/parser')

  lines = File.readlines(path)
  text = lines.join
  edits = []
  text.to_enum(:scan, /(?<![\w.])([a-z]\w*__[\w?!]+)\(/).each do
    m = Regexp.last_match
    params = sigs[m[1]] or next
    fin = close_paren(text, m.end(0) - 1) or next

    line_no = text[0...m.begin(0)].count("\n")
    offset = m.end(0)
    split_args(text[m.end(0)...fin]).each_with_index do |arg, idx|
      want = params[idx]
      start = offset
      offset += arg.length + 1
      next unless want && !want.start_with?('?') && arg.strip =~ /\A[a-z_]\w*\z/

      got = type_of(lines, line_no, arg.strip, returns)
      next unless got&.start_with?('?')
      next unless got.delete_prefix('?') == want
      # A nil check or an EXISTS narrowing above already made it non-optional
      # here, and unwrapping again is UNWRAP_NON_OPTIONAL.
      name = arg.strip
      window = lines[[0, line_no - 15].max..line_no].join
      next if window =~ /#{Regexp.escape(name)}\s*(?:!=|==)\s*NIL/ ||
              window =~ /#{Regexp.escape(name)}\s+EXISTS/ ||
              window =~ /IS_A\s+[\w@?\[\]{}]+\s+AS\s+#{Regexp.escape(name)}\b/

      skipped[:candidates] += 1
      edits << [start, start + arg.length, " UNWRAP (#{arg.strip})"]
    end
  end
  next if edits.empty?

  edits.sort_by!(&:first)
  edits.reverse_each { |a, b, s| text = text[0...a] + s + text[b..] }
  wrapped += edits.length
  File.write(path, text) if apply
end

puts "#{wrapped} arguments unwrapped where the parameter requires a value"
puts '(dry run -- pass --apply to write)' unless apply
