#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate the union field SETTERS the annotator's write sites need.
#
# `selfhost_generate_dispatchers.rb` covers reads: a union has no fields, so
# `x.field` becomes `union__field(x)`. A write has the same problem and no
# answer -- `x.field = v` on a union is UNION_FIELD_ACCESS with nothing to
# rewrite to. The setter is the mirror of the accessor: the variants that
# carry the field assign it, the rest are a no-op, which is what Ruby's
# `x.field = v` does when the node does not have that attribute.
#
# Driven by the probe: only (union, field) pairs an actual write site needs.
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

variants, fields = SelfhostUnionAccessor.load_types(ROOT)
sources = Dir.glob(File.join(ROOT, '**', '*.clear')).sort
text = sources.to_h { |p| [p, File.read(p)] }
existing = text.values.join
declared = {}
text.each do |path, body|
  body.each_line { |l| (m = l.match(/^(?:PUB )?UNION (\w+) \{/)) && declared[m[1]] = path }
end

# Every write site the compiler reported against a union receiver.
wanted = Hash.new { |h, k| h[k] = Set.new }
JSON.parse(File.read(probe)).each do |r|
  next if r['ok'] || !r['line']

  m = r['error'].to_s.match(/'(\w+)' is a union type/) or next
  src = text[File.join(ROOT, r['file'])] or next

  line = src.lines[r['line'] - 1].to_s
  line.scan(/\.(\w+)\s*=[^=]/) { |field,| wanted[m[1]] << field }
end

made = Hash.new { |h, k| h[k] = [] }
skipped = Hash.new(0)
wanted.each do |union, want|
  path = declared[union] or next
  members = variants[union] or next
  recv = "#{union[0].downcase}#{union[1..]}"
  want.each do |field|
    fn = "#{recv}__set_#{field}_mut"
    next if existing.include?("FN #{fn}(")

    carrying = members.select { |_, type| fields[type.to_s.sub(/@\w+\z/, '')]&.key?(field) }
    (skipped[:none] += 1) and next if carrying.empty?

    types = carrying.map { |_, t| fields[t.sub(/@\w+\z/, '')][field] }.uniq
    (skipped[:mixed] += 1) and next if types.length > 1

    body = +"\n# The mirror of #{recv}__#{field}: a variant that carries the field takes\n"
    body << "# the write, and one that does not ignores it -- which is what Ruby does\n"
    body << "# when the node has no such attribute.\n"
    body << "PUB FN #{fn}(MUTABLE value: #{union}, new_value: #{types.first}) RETURNS Void ->\n"
    body << "  PARTIAL MATCH value START\n"
    carrying.each { |name, _| body << "    #{union}.#{name} AS MUTABLE item -> item.#{field} = COPY new_value;,\n" }
    body << "    DEFAULT -> RETURN;\n  END\nEND\n"
    made[path] << body
  end
end

made.each { |path, bodies| File.write(path, File.read(path) + bodies.join) } if apply
puts "#{made.values.sum(&:length)} setter(s) across #{made.length} file(s)"
puts "skipped: #{skipped[:mixed]} mixed-type, #{skipped[:none]} carried by no variant"
puts '(dry run -- pass --apply to write)' unless apply
