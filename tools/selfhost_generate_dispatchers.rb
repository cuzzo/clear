#!/usr/bin/env ruby
# frozen_string_literal: true

# Bulk-generate the union field accessors the reflection sites need.
#
# `selfhost_union_accessor` answers one (union, field) at a time, which costs a
# human round per site. The set is knowable up front: every name a
# `respondsTo?` asks about, crossed with every union whose variants can answer
# it unambiguously. Generating them all at once turns the whole reflection
# class from a human decision into a mechanical rewrite the autofixer already
# knows how to make.
require 'set'
require_relative 'selfhost_union_accessor'

root = File.expand_path('../compiler/src', __dir__)
variants, fields = SelfhostUnionAccessor.load_types(root)

sources = Dir.glob(File.join(root, '**', '*.clear')).sort
text = sources.to_h { |p| [p, File.read(p)] }
# Only the accessors the tree already calls. Generating every union crossed
# with every reflected name buries the tree in code nothing calls; a call that
# exists with no definition is a site that is already blocked.
called = text.values.join.scan(/\b([a-z]\w*)__([a-zA-Z_?!]+)\(/).uniq
defined = text.values.join.scan(/FN (\w+)\(/).flatten.to_set
wanted = Hash.new { |h, k| h[k] = [] }
called.each do |recv, field|
  fn = "#{recv}__#{field}"
  next if defined.include?(fn)

  wanted[recv] << field
end

# Where each union is declared, so the accessor lands beside it.
declared = {}
text.each do |path, body|
  body.each_line { |l| (m = l.match(/^(?:PUB )?UNION (\w+) \{/)) && declared[m[1]] = path }
end

existing = text.values.join
made = Hash.new { |h, k| h[k] = [] }
skipped = Hash.new(0)

variants.each do |union, members|
  path = declared[union] or next
  recv = "#{union[0].downcase}#{union[1..]}"
  wanted[recv].uniq.each do |field|
    fn = "#{recv}__#{field}"
    next if existing.include?("FN #{fn}(")

    carrying = members.select { |_, type| fields[type.sub(/@\w+\z/, '')].key?(field) }
    next if carrying.empty?

    types = carrying.map { |_, t| fields[t.sub(/@\w+\z/, '')][field].delete_prefix('?') }.uniq
    # A field meaning different things on different variants needs a human to
    # say which meaning the call site wants.
    (skipped[:mixed] += 1) and next if types.length > 1

    result = types.first
    result = "?#{result}" unless result.start_with?('?')
    body = +"\n# Ruby asks `respond_to?(:#{field})` and then reads it. A union variant\n"
    body << "# either carries the field or it does not, so the question is answered here:\n"
    body << "# the variants that have it return it, the rest return NIL.\n"
    body << "PUB FN #{fn}(value: #{union}) RETURNS #{result} ->\n  PARTIAL MATCH value START\n"
    carrying.each { |name, _| body << "    #{union}.#{name} AS item -> RETURN COPY item.#{field};,\n" }
    body << "    DEFAULT -> RETURN NIL;\n  END\n  RETURN NIL;\nEND\n"
    made[path] << body
  end
end

made.each { |path, bodies| File.write(path, File.read(path) + bodies.join) }
puts "generated #{made.values.sum(&:length)} accessor(s) across #{made.length} file(s)"
puts "skipped #{skipped[:mixed]} mixed-type field(s) -- those need a human to pick the meaning"
made.sort_by { |_, b| -b.length }.first(8).each { |p, b| puts format('  %-52s %d', p.sub("#{root}/", ''), b.length) }
