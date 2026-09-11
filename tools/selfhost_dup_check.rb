#!/usr/bin/env ruby
# frozen_string_literal: true

# Find declarations that collide inside a merged package group, in one second.
#
# A package group concatenates its members, so two units that each generated
# the same helper become a DUPLICATE_DECLARATION -- and that raise happens
# before any per-statement accumulation, so it ends the whole run and hides
# everything behind it. Finding them by running the compiler costs one ~25
# minute round per collision; the merge is textual, so a scan finds them all.
$PROGRAM_NAME = 'selfhost_dup_check_support'
require_relative 'parser_compat'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
DECL = /^(?:PUB |PRIVATE )?(FN|STRUCT|UNION|ENUM|PROTOCOL)\s+([A-Za-z_]\w*[?!]?)/

groups = ParserCompat.package_groups(GEN)
total = 0
groups.each do |name, members|
  seen = Hash.new { |h, k| h[k] = [] }
  members.each do |rel|
    File.readlines(File.join(GEN, rel)).each_with_index do |line, i|
      m = DECL.match(line) or next
      seen[[m[1], m[2]]] << "#{rel}:#{i + 1}"
    end
  end
  dups = seen.select { |_k, v| v.length > 1 }
  next if dups.empty?

  puts "#{name} (#{members.length} members): #{dups.length} collisions"
  dups.sort_by { |k, _v| k[1] }.each { |(kind, sym), where| puts "  #{kind} #{sym}\n    #{where.join("\n    ")}" }
  total += dups.length
end
puts "total collisions: #{total}"
exit(total.zero? ? 0 : 1)
