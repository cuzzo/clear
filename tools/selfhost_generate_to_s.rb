#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate `to_s` for unions the tree interpolates.
#
# Ruby writes `"#{dispatch}"` where dispatch is a symbol or a boolean; CLEAR's
# $+ takes String operands and a union has no toString intrinsic. The helper is
# the union's own to_s -- each variant rendered the way Ruby renders it.
#
# Driven by the probe: only unions an interpolation site actually needs.
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

# Rendering per payload type, matching Ruby's interpolation.
def render(type)
  case type.to_s.sub(/@\w+\z/, '')
  when 'String' then 'COPY item'
  when 'String@symbol', 'Symbol' then 'CAST(COPY item AS String)'
  when 'Bool', 'Int64', 'Float64' then 'item.toString()'
  end
end

wanted = Set.new
JSON.parse(File.read(probe)).each do |r|
  next if r['ok']

  m = r['error'].to_s.match(/requires String operands, got (\w+)/) ||
      r['error'].to_s.match(/No overload for 'toString' matches arguments \((\w+)\)/)
  wanted << m[1] if m && variants.key?(m[1])
end

made = Hash.new { |h, k| h[k] = [] }
skipped = []
wanted.each do |union|
  path = declared[union] or next

  fn = "#{union[0].downcase}#{union[1..]}__to_s"
  next if existing.include?("FN #{fn}(")

  members = variants[union]
  rendered = members.map { |name, type| [name, render(type.to_s.include?('@symbol') ? 'String@symbol' : type)] }
  if rendered.any? { |_, r| r.nil? }
    skipped << union
    next
  end

  body = +"\n# Ruby interpolates this value directly; each variant renders the\n"
  body << "# way Ruby renders it.\n"
  body << "PUB FN #{fn}(value: #{union}) RETURNS String ->\n  PARTIAL MATCH value START\n"
  rendered.each { |name, r| body << "    #{union}.#{name} AS item -> RETURN #{r};,\n" }
  body << "  END\n  RETURN \"\";\nEND\n"
  made[path] << body
end

made.each { |path, bodies| File.write(path, File.read(path) + bodies.join) } if apply
puts "#{made.values.sum(&:length)} to_s helper(s) across #{made.length} file(s)"
puts "skipped (non-primitive payload): #{skipped.join(', ')}" unless skipped.empty?
puts '(dry run -- pass --apply to write)' unless apply
