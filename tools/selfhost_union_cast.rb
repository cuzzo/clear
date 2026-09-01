#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate a cast between two rtoc-materialized unions.
#
# rtoc materializes a fresh union at every site that needed one -- BgSourceWalkValue,
# SegmentStmt, AstIdentWalkRoot, MIRLoweringFallback -- and each is some slice of
# Locatable with its own variant names (`FunctionDefMultiowned` for
# `FunctionDef@multiowned`). Code that has one and needs the other cannot say so
# without a cast, and hand-writing 128 arms per pair does not scale.
#
# Variants are matched by TYPE, not by name, so the renames line up. A variant the
# target cannot represent falls through to the caller's default.
#
#   ruby tools/selfhost_union_cast.rb --from BgSourceWalkValue --to Locatable
#   ruby tools/selfhost_union_cast.rb --from X --to Y --apply
require 'optparse'
require 'set'

ROOT = File.expand_path('../compiler/src', __dir__)

def unions
  found = {}
  Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
    File.read(path).scan(/^(?:PUB )?UNION (\w+) \{(.*?)\}$/) do |name, body|
      found[name] = [path, body.split(',').filter_map do |part|
        part =~ /\s*(\w+):\s*(.+?)\s*\z/m ? [Regexp.last_match(1), Regexp.last_match(2)] : nil
      end]
    end
  end
  found
end

from = to = nil
apply = false
OptionParser.new do |p|
  p.on('--from NAME') { |v| from = v }
  p.on('--to NAME') { |v| to = v }
  p.on('--apply') { apply = true }
end.parse!(ARGV)
abort 'usage: --from NAME --to NAME [--apply]' unless from && to

all = unions
src = all[from] or abort "no union '#{from}'"
dst = all[to] or abort "no union '#{to}'"

# Target variant per type, so a rename on either side still matches.
by_type = dst[1].to_h { |name, type| [type, name] }
arms = src[1].filter_map do |name, type|
  target = by_type[type] || by_type[type.sub(/@\w+\z/, '')]
  next unless target

  "    #{from}.#{name} AS item -> RETURN #{to}{ #{target}: COPY item };,"
end

fn = "cast#{from}To#{to}"
puts "# #{arms.length} of #{src[1].length} #{from} variants map to #{to}"
body = +"FN #{fn}(value: #{from}) RETURNS ?#{to} ->\n  PARTIAL MATCH value START\n"
body << arms.join("\n") << "\n    DEFAULT -> RETURN NIL;\n  END\n  RETURN NIL;\nEND\n"

if apply
  # The cast belongs where BOTH unions are visible. rtoc's materialized unions
  # are declared downstream of the one they slice, so that is the derived
  # union's file -- putting it beside Locatable would name a type ast.clear
  # cannot see.
  path = [src[0], dst[0]].reject { |f| f.end_with?('ast/ast.clear') }.first || src[0]
  text = File.read(path)
  abort "#{fn} already defined" if text.include?("FN #{fn}(")
  File.write(path, "#{text}#{body}")
  puts "appended #{fn} to #{path.sub("#{ROOT}/", '')}"
else
  puts body.lines.first(4).join
  puts '  ... (--apply to write)'
end
