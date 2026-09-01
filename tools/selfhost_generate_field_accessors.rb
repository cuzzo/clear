#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate the `X__field` accessors the tree calls but never defines.
#
# rtoc emits `funcCall__name(x)` for Ruby's `x.name` and defines the accessor
# only when it happened to visit the struct. The rest are undefined-function
# errors that surface one per compile -- and a compile of the annotator package
# takes the better part of an hour.
#
# Only struct fields are generated here: the name resolves to exactly one field
# on exactly one struct, so the body is `RETURN COPY self.field;`. Union
# dispatch is `selfhost_generate_dispatchers.rb`'s job.
require 'set'
require_relative 'selfhost_union_accessor'

ROOT = File.expand_path('../compiler/src', __dir__)
apply = ARGV.include?('--apply')

variants, fields = SelfhostUnionAccessor.load_types(ROOT)
texts = Dir.glob(File.join(ROOT, '**', '*.clear')).sort.to_h { |p| [p, File.read(p)] }

defined = Set.new
texts.each_value { |t| t.scan(/\bFN ([\w?!]+)\s*(?:<[^>]*>)?\(/) { |m| defined << m[0] } }

# Where each struct is declared, so the accessor lands beside it.
declared = {}
texts.each { |p, t| t.scan(/^(?:PUB )?STRUCT (\w+) \{/) { |m| declared[m[0]] = p } }

wanted = Hash.new(0)
texts.each_value do |t|
  t.scan(/(?<![\w.])([a-z]\w*__[\w?!]+)\(/) { |m| wanted[m[0]] += 1 unless defined.include?(m[0]) }
end

pending = Hash.new { |h, k| h[k] = [] }
made = 0
wanted.sort.each do |name, uses|
  recv, field = name.split('__', 2)
  type = recv[0].upcase + recv[1..]
  bare_field = field.delete_suffix('?').delete_suffix('!')
  next unless (decl = fields[type]) && decl.key?(bare_field)
  next unless (path = declared[type])

  ftype = decl[bare_field]
  pending[path] << "PUB FN #{name}(self: #{type}) RETURNS #{ftype} ->\n  RETURN COPY self.#{bare_field};\nEND\n"
  made += 1
  puts format('  %-46s %-28s %d call(s)', name, ftype, uses)
end

if apply
  pending.each { |path, bodies| File.write(path, texts[path] + bodies.join) }
  puts "generated #{made} accessor(s) across #{pending.size} file(s)"
else
  puts "#{made} accessor(s) -- --apply to write"
end
