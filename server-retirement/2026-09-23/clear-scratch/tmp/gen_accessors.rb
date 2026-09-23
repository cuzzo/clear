#!/usr/bin/env ruby
# Generate every union field accessor `method_to_accessor` reported missing.
require 'set'
require_relative '/home/yahn/cheat/tools/selfhost_union_accessor'

ROOT = File.expand_path('/home/yahn/cheat/compiler/src')
apply = ARGV.include?('--apply')
variants, fields = SelfhostUnionAccessor.load_types(ROOT)

texts = Dir.glob(File.join(ROOT, '**', '*.clear')).sort.to_h { |p| [p, File.read(p)] }
defined = Set.new
texts.each_value { |t| t.scan(/\bFN ([\w?!]+)\s*(?:<[^>]*>)?\(/) { |m| defined << m[0] } }

def accessor_name(union, field)
  "#{union[0].downcase}#{union[1..]}__#{field}"
end

wanted = ARGF.class # placeholder
pairs = File.read('/tmp/unresolved.txt').lines.map(&:strip).reject(&:empty?).map { |l| l.split('#', 2) }

made = 0
pairs.each do |union, field|
  next unless variants.key?(union)
  name = accessor_name(union, field)
  next if defined.include?(name)
  carriers = variants[union].select do |_v, type|
    st = type.to_s.sub(/@\w+\z/, '').delete_prefix('?')
    fields[st]&.key?(field)
  end
  next if carriers.empty?
  types = carriers.map { |v, t| fields[t.to_s.sub(/@\w+\z/, '').delete_prefix('?')][field] }.uniq
  next if types.length != 1
  ret = types.first.to_s
  ret = "?#{ret}" unless ret.start_with?('?')
  body = +"\n# Ruby asks `respond_to?(:#{field})` and then reads it. A union variant either\n"
  body << "# carries the field or it does not, so the question is answered here.\n"
  body << "PUB FN #{name}(value: #{union}) RETURNS #{ret} ->\n  PARTIAL MATCH value START\n"
  carriers.each { |(v, _t)| body << "    #{union}.#{v} AS item -> RETURN COPY item.#{field};,\n" }
  body << "    DEFAULT -> RETURN NIL;\n  END\n  RETURN NIL;\nEND\n"
  # Append to the file that declares the union.
  target = texts.keys.find { |p| texts[p] =~ /^(?:PUB )?UNION #{Regexp.escape(union)} \{/ }
  next unless target
  texts[target] = texts[target] + body
  defined << name
  made += 1
  puts "#{name} (#{carriers.length} variants) -> #{File.basename(target)}"
end
if apply
  texts.each { |p, t| File.write(p, t) }
end
puts "generated #{made} accessor(s)#{apply ? '' : ' (dry run)'}"
