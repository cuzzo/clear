#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate a narrowing cast from a union to ONE of its variants.
#
# Ruby passes a node where a specific node type is wanted and lets duck typing
# sort it out. CLEAR needs the narrowing spelled: the union either holds that
# variant or it does not, which is exactly an `IS_A` test. Sibling tool to
# selfhost_union_cast.rb, which casts between two unions.
#
#   ruby tools/selfhost_variant_cast.rb --union Locatable --variant BinaryOp [--apply]
require 'optparse'

ROOT = File.expand_path('../compiler/src', __dir__)

def unions
  found = {}
  Dir.glob(File.join(ROOT, '**', '*.clear')).sort.each do |path|
    File.foreach(path).with_index do |line, index|
      next unless (m = line.match(/^(?:PUB )?UNION (\w+) \{(.*)\}\s*$/))

      members = m[2].split(',').filter_map do |member|
        name, type = member.split(':', 2)
        next unless name && type

        [name.strip, type.strip]
      end
      found[m[1]] = { members: members, path: path, line: index }
    end
  end
  found
end

union = variant = nil
apply = false
OptionParser.new do |p|
  p.on('--union NAME') { |v| union = v }
  p.on('--variant NAME') { |v| variant = v }
  p.on('--apply') { apply = true }
end.parse!(ARGV)
abort 'usage: --union NAME --variant NAME [--apply]' unless union && variant

all = unions
info = all[union] or abort "selfhost_variant_cast: no union '#{union}'"
hit = info[:members].find { |_, type| type.sub(/@\w+\z/, '') == variant }
abort "selfhost_variant_cast: #{union} has no variant of type '#{variant}'" unless hit

fn = "cast#{union}To#{variant}"
carrier = hit[1]
text = <<~CLEAR

  # Ruby hands the node straight to a callee that wants one specific shape.
  # The union either holds that variant or it does not.
  PUB FN #{fn}(value: #{union}) RETURNS ?#{carrier} EFFECTS REENTRANT ->
    IF value IS_A #{variant} AS item THEN
      RETURN item;
    END
    RETURN NIL;
  END
CLEAR

if apply
  path = info[:path]
  File.write(path, "#{File.read(path).rstrip}\n#{text}")
  warn "appended #{fn} to #{path.sub("#{ROOT}/", '')}"
else
  puts text
end
