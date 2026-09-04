#!/usr/bin/env ruby
# frozen_string_literal: true

# A function that mutates its receiver needs `MUTABLE self`, a mutable WITH
# alias, and `&` at every call site. rtoc emits the body's mutation without any
# of the three, so the compiler reports the argument, not the signature. Drive
# the change from that diagnostic.
require 'json'
require 'optparse'
require 'set'

ROOT = File.expand_path('../compiler/src', __dir__)
probe = File.expand_path('../.fn_probe.json', __dir__)
apply = false
OptionParser.new do |p|
  p.on('--apply') { apply = true }
  p.on('--probe FILE') { |v| probe = v }
end.parse!

wanted = Set.new
JSON.parse(File.read(probe)).each do |r|
  next if r['ok']

  e = r['error'].to_s.split.join(' ')
  # "Argument 1 ('self') is MUTABLE, but you passed immutable variable
  # 'rtoc_self_view'" means the ENCLOSING function is the one that has to
  # become mutable, not the callee.
  next unless e =~ /Argument 1 \('self'\) is MUTABLE, but you passed immutable variable/

  wanted << r['fn']
end

counts = Hash.new(0)
sources = Dir.glob(File.join(ROOT, '**', '*.clear'))
texts = sources.to_h { |f| [f, File.read(f)] }

wanted.each do |fn|
  owner = sources.find { |f| texts[f] =~ /\bFN #{Regexp.escape(fn)}\s*[(<]/ }
  next unless owner

  t = texts[owner]
  sig = t[/(?:PUB |PRIVATE )?FN #{Regexp.escape(fn)}(?:<[^>]*>)?\(self: /]
  next unless sig

  t = t.sub(sig, sig.sub('(self: ', '(MUTABLE self: '))
  i = t.index("FN #{fn}")
  fin = t.index("\nEND\n", i) || t.length
  seg = t[i...fin]
  seg2 = seg.sub('WITH POLYMORPHIC self AS rtoc_self_view {',
                 'WITH POLYMORPHIC self AS MUTABLE rtoc_self_view {')
  t = t[0...i] + seg2 + t[fin..]
  texts[owner] = t
  counts[:signature] += 1

  # every call site now passes a mutating argument
  sources.each do |f|
    s = texts[f]
    marked = s.gsub(/(?<![\w.])#{Regexp.escape(fn)}\((?!&)(?!MUTABLE)/, "#{fn}(&")
    next if marked == s

    counts[:call_sites] += marked.scan(/#{Regexp.escape(fn)}\(&/).length - s.scan(/#{Regexp.escape(fn)}\(&/).length
    texts[f] = marked
  end
end

texts.each { |f, s| File.write(f, s) } if apply
counts.each { |k, v| puts format('  %-12s %d', k, v) }
puts "functions: #{wanted.length}"
puts '(dry run -- pass --apply to write)' unless apply
