#!/usr/bin/env ruby
# frozen_string_literal: true

# Find CLEAR parameters whose optionality disagrees with Ruby's sig.
#
# The mirror of selfhost_return_optionality: rtoc infers a parameter type from
# call sites, so one caller passing nil makes the parameter `?T` while Ruby's
# sig declares `T`. Every caller passing a plain T then fails
# ARGUMENT_TYPE_ERROR -- again one diagnostic per caller, which is why these
# hide behind large counts.
require 'set'

RUBY_ROOT = File.expand_path('../compiler/ruby', __dir__)
CLEAR_ROOT = File.expand_path('../compiler/src', __dir__)

# A Sorbet type alias can itself be nilable -- MaybeSymbol includes NilClass,
# DiagnosticToken is T.nilable(...) -- so the alias name alone says nothing
# about optionality. Resolve them before comparing.
NILABLE_ALIAS = Set.new
Dir.glob("#{RUBY_ROOT}/**/*.rb").each do |f|
  File.read(f).scan(/(\w+)\s*=\s*T\.type_alias\s*\{(.+?)\}/m) do |name, body|
    NILABLE_ALIAS << name if body.include?('nilable') || body.include?('NilClass')
  end
end

ruby_params = {}
Dir.glob("#{RUBY_ROOT}/**/*.rb").each do |f|
  lines = File.readlines(f)
  cls = nil
  lines.each_with_index do |l, i|
    cls = Regexp.last_match(1) if l =~ /^\s*class (\w+)/
    next unless l =~ /^\s*def (?:self\.)?([\w?!]+)/
    next unless cls

    name = Regexp.last_match(1)
    sig = lines[(i - 6).clamp(0, i)...i].reverse.find { |s| s.include?('sig ') }
    next unless sig && (params = sig[/params\((.+?)\)\s*\.\s*(?:returns|void)/m, 1])

    decl = params.scan(/(\w+):\s*([^,]+?)(?=,\s*\w+:|\z)/).to_h
    ruby_params["#{cls}##{name}"] = decl
  end
end

def clear_recv(cls) = "#{cls[0].downcase}#{cls[1..]}"

rows = []
Dir.glob("#{CLEAR_ROOT}/**/*.clear").each do |f|
  File.read(f).scan(/^(?:PUB |PRIVATE )?FN (\w+)__([\w?!]+)\(([^\n]*?)\)\s*RETURNS/) do |recv, meth, params|
    key = ruby_params.keys.find { |k| clear_recv(k.split('#').first) == recv && k.split('#').last == meth }
    next unless key

    rb = ruby_params[key]
    params.split(/,\s*(?=(?:MUTABLE\s+)?\w+:)/).each do |p|
      m = p.match(/\A(?:MUTABLE\s+)?(\w+):\s*(\?[\w@\[\]{}]+)/) or next
      pname = m[1]
      rbt = rb[pname] or next
      next if rbt.include?('nilable') || rbt.include?('NilClass')
      next if NILABLE_ALIAS.include?(rbt.strip.split('::').last)

      rows << ["#{recv}__#{meth}", pname, m[2], rbt.strip[0, 34], f.sub("#{CLEAR_ROOT}/", '')]
    end
  end
end

puts "#{rows.length} parameter(s) optional in CLEAR but not in Ruby's sig:"
rows.first(25).each { |fn, p, ct, rbt, _| puts format('  %-46s %-14s %-12s ruby %s', fn, p, ct, rbt) }
