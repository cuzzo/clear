#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate castXToY for two unions whose variants line up.
#
# rtoc emits a cast only where it happened to need one, so a call passing a
# SymbolEntryRegInput where Locatable is expected has no bridge and fails
# ARGUMENT_TYPE_ERROR. Both are unions over the same AST node types, so the
# cast is variant-by-variant re-wrapping; a variant the target does not carry
# panics, which is what the existing generated casts do.
#
# Driven by the probe: only pairs a call site actually needs.
require 'json'
require 'set'
require 'optparse'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
probe = File.expand_path('../.fn_probe.json', __dir__)
apply = false
OptionParser.new do |p|
  p.on('--apply') { apply = true }
  p.on('--probe FILE') { |v| probe = v }
end.parse!

variants, = SelfhostUnionAccessor.load_types(ROOT)
texts = Dir.glob(File.join(ROOT, '**', '*.clear')).sort.to_h { |p| [p, File.read(p)] }
existing = texts.values.join
declared = {}
texts.each { |p, t| t.scan(/^(?:PUB )?UNION (\w+) /) { |m| declared[m[0]] = p } }

wanted = Set.new
JSON.parse(File.read(probe)).each do |r|
  next if r['ok']

  m = r['error'].to_s.match(/argument \d+ expects (\w+), got (\w+)\z/) or next
  wanted << [m[2], m[1]] if variants.key?(m[1]) && variants.key?(m[2])
end

made = Hash.new { |h, k| h[k] = [] }
skipped = []
wanted.each do |src, dst|
  fn = "cast#{src}To#{dst}"
  next if existing.include?("FN #{fn}(")

  path = declared[src] or next
  target = variants[dst].to_h { |n, t| [t.to_s.sub(/@\w+\z/, ''), n] }
  arms = variants[src].filter_map do |name, type|
    tn = target[type.to_s.sub(/@\w+\z/, '')] or next
    "    #{src}.#{name} AS cast_payload -> RETURN #{dst}{ #{tn}: COPY cast_payload };,"
  end
  # A bridge that covers almost nothing is not a bridge.
  if arms.length < variants[src].length / 2
    skipped << "#{src}->#{dst} (#{arms.length}/#{variants[src].length})"
    next
  end

  body = +"\nFN #{fn}(value: #{src}) RETURNS #{dst} ->\n  PARTIAL MATCH value START\n"
  body << arms.join("\n")
  body << "\n    DEFAULT -> panic(\"Invalid cast to #{dst}\");\n  END\n"
  body << "  panic(\"Invalid cast to #{dst}\");\nEND\n"
  made[path] << body
end

made.each { |path, bodies| File.write(path, File.read(path) + bodies.join) } if apply
puts "#{made.values.sum(&:length)} union cast(s) generated"
puts "skipped: #{skipped.join(', ')}" unless skipped.empty?
puts '(dry run -- pass --apply to write)' unless apply
