#!/usr/bin/env ruby
# frozen_string_literal: true

# Mark arguments that a MUTABLE parameter receives with `&`.
#
# CLEAR makes mutation explicit at the call site; Ruby does not, so the
# translation passes a bare name to a `MUTABLE` parameter and the compiler
# says: "Argument 2 ('node') is MUTABLE. Pass 'node' as '&node'".
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
# Which parameter positions are declared MUTABLE.
mutable_params = {}
texts.each_value do |t|
  t.to_enum(:scan, /^(?:PUB |PRIVATE )?FN ([\w?!]+)(?:<[^>]*>)?\(/).each do
    m = Regexp.last_match
    fin = close_paren(t, m.end(0) - 1) or next
    flags = split_args(t[m.end(0)...fin]).map { |p| p.strip.start_with?('MUTABLE ') }
    mutable_params[m[1]] ||= flags
  end
end

marked = 0
texts.each_key do |path|
  next if path.include?('/ast/parser')

  text = texts[path]
  edits = []
  text.to_enum(:scan, /(?<![\w.])([a-z]\w*__[\w?!]+)\(/).each do
    m = Regexp.last_match
    flags = mutable_params[m[1]] or next
    next unless flags.any?

    fin = close_paren(text, m.end(0) - 1) or next
    offset = m.end(0)
    split_args(text[m.end(0)...fin]).each_with_index do |arg, idx|
      start = offset
      offset += arg.length + 1
      next unless flags[idx]

      name = arg.strip
      next unless name =~ /\A[a-z_]\w*\z/

      edits << [start, start + arg.length, " &#{name}"]
    end
  end
  next if edits.empty?

  edits.sort_by!(&:first)
  edits.reverse_each { |a, b, s| text = text[0...a] + s + text[b..] }
  marked += edits.length
  File.write(path, text) if apply
end

puts "#{marked} arguments marked '&' for a MUTABLE parameter"
puts '(dry run -- pass --apply to write)' unless apply
