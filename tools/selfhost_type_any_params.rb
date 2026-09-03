#!/usr/bin/env ruby
# frozen_string_literal: true

# Give an `Any`-typed parameter the type its own body proves it has.
#
# Ruby's sig says T.untyped, so rtoc faithfully emits `Any` -- but CLEAR's Any
# is a float, not a dynamic type, so every field read on it fails
# ILLEGAL_FIELD_LOOKUP. Call sites pass expressions too varied to parse, but
# the BODY names the fields it reads, and usually exactly one declared type
# carries all of them.
#
# Retypes only when the field set picks out a single type.
#
# MEASURED 2026-09-03: this does not discriminate. A body typically reads ONE
# field off the parameter, and a single field name is carried by far too many
# types -- `.symbol` alone matches 229. Call sites would settle it, but the
# arguments there are CAST/pipeline expressions this cannot parse.
#
# 205 real (non-rtoc-helper) Any parameters remain. Typing them needs either a
# real expression type-checker or per-site judgement; kept here so the next
# attempt starts from what was already ruled out.
require 'set'
require 'optparse'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = false
verbose = false
OptionParser.new do |p|
  p.on('--apply') { apply = true }
  p.on('--verbose') { verbose = true }
end.parse!

variants, fields = SelfhostUnionAccessor.load_types(ROOT)
# A union answers a field read through its generated accessor, so treat a
# union as carrying every field any of its variants carries.
union_fields = variants.transform_values do |members|
  members.flat_map { |_n, t| fields[t.to_s.sub(/@\w+\z/, '')]&.keys || [] }.uniq
end
carriers = {}
fields.each { |s, f| carriers[s] = f.keys }
union_fields.each { |u, f| carriers[u] = f }

changes = []
Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
  text = File.read(path)
  text.scan(/^((?:PUB |PRIVATE )?FN ([\w?!]+)\(([^\n]*?)\)\s*RETURNS[^\n]*\n)/) do |whole, name, params|
    next if name.start_with?('ruby_', 'rtoc_')

    params.split(/,\s*(?=(?:MUTABLE\s+)?\w+:)/).each do |p|
      m = p.match(/\A\s*(?:MUTABLE\s+)?(\w+):\s*(Any|\[\]Any)\s*\z/) or next

      pname, decl = m[1], m[2]
      start = text.index(whole) or next
      fin = text.index(/^END$/, start) || text.length
      body = text[start...fin]
      # Fields read directly off the parameter (or its elements, for a list).
      read = body.scan(/(?<![\w.])#{Regexp.escape(pname)}(?:\[[^\]]*\])?\.(\w+)/).flatten.uniq
      read -= %w[toString size length]
      next if read.empty?

      hits = carriers.select { |_t, f| read.all? { |r| f.include?(r) } }.keys
      warn "  #{name}.#{pname} reads #{read.inspect[0, 50]} -> #{hits.size} candidates" if verbose
      next unless hits.length == 1

      changes << [path, name, pname, decl, decl == '[]Any' ? "[]#{hits.first}" : hits.first]
    end
  end
end

applied = 0
by_path = changes.group_by(&:first)
by_path.each do |path, list|
  t = File.read(path)
  list.each do |_p, fn, pname, decl, got|
    pat = /(FN #{Regexp.escape(fn)}\([^\n]*?(?:MUTABLE )?#{Regexp.escape(pname)}:\s*)#{Regexp.escape(decl)}(?=[,)])/
    next unless t =~ pat

    t = t.sub(pat) { "#{Regexp.last_match(1)}#{got}" }
    applied += 1
  end
  File.write(path, t) if apply
end

puts "#{applied} Any parameter(s) typed from the fields their body reads"
changes.first(10).each { |_p, fn, pname, decl, got| puts format('  %-46s %s: %s -> %s', fn, pname, decl, got) }
puts '(dry run -- pass --apply to write)' unless apply
