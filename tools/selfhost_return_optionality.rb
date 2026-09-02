#!/usr/bin/env ruby
# frozen_string_literal: true

# Find CLEAR functions that return an optional where Ruby's sig does not.
#
# rtoc infers a return type from the body: a Ruby `case` with no `else`, or a
# guard clause returning nil, makes the CLEAR signature `?T`. Ruby's Sorbet sig
# is the declared contract, and where it says `T` rather than `T.nilable(T)`
# the optional is an artifact -- every caller expecting `T` then fails
# RETURN_MISMATCH, one diagnostic per caller.
require 'set'

RUBY_ROOT = File.expand_path('../compiler/ruby', __dir__)
CLEAR_ROOT = File.expand_path('../compiler/src', __dir__)

# Ruby: the sig line immediately preceding a def.
ruby_returns = {}
Dir.glob("#{RUBY_ROOT}/**/*.rb").each do |f|
  lines = File.readlines(f)
  cls = nil
  lines.each_with_index do |l, i|
    cls = Regexp.last_match(1) if l =~ /^\s*class (\w+)/
    next unless l =~ /^\s*def (?:self\.)?([\w?!]+)/

    name = Regexp.last_match(1)
    sig = lines[(i - 3).clamp(0, i)...i].reverse.find { |s| s.include?('sig ') }
    next unless sig && cls

    ret = sig[/returns\((.+)\)\s*\}/, 1]
    ruby_returns["#{cls}##{name}"] = ret if ret
  end
end

def clear_recv(cls) = "#{cls[0].downcase}#{cls[1..]}"

mismatches = []
Dir.glob("#{CLEAR_ROOT}/**/*.clear").each do |f|
  File.read(f).scan(/^(?:PUB |PRIVATE )?FN (\w+)__([\w?!]+)\([^\n]*\)\s*RETURNS\s+(!?\?[\w@\[\]{}]+)/) do |recv, meth, ret|
    key = ruby_returns.keys.find { |k| clear_recv(k.split('#').first) == recv && k.split('#').last == meth }
    next unless key

    rb = ruby_returns[key]
    # Ruby says the value is always present; CLEAR says it may be nil.
    next if rb.include?('nilable')

    mismatches << [f.sub("#{CLEAR_ROOT}/", ''), "#{recv}__#{meth}", ret, rb[0, 40], key]
  end
end

puts "#{mismatches.length} CLEAR function(s) return an optional where Ruby's sig does not:"
mismatches.first(25).each { |f, fn, ret, rb, key| puts format('  %-46s %-14s ruby %s (%s)', fn, ret, rb, key) }
