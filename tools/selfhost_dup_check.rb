#!/usr/bin/env ruby
# frozen_string_literal: true

# Find declarations that collide inside a merged package, in seconds.
#
# DUPLICATE_FUNCTION_DECLARATION raises before any per-statement accumulation,
# so it ends the whole run and hides everything behind it: one ~25 minute round
# per collision, found one at a time. The merge is textual, so a scan finds
# them all at once.
#
# Scanning a group's MEMBERS is not enough -- PackageSource.merge also inlines
# the packages those members require, and a collision between a member and an
# inlined unit only exists in the merged text. So the check merges exactly what
# the compiler merges and reads that.
$PROGRAM_NAME = 'selfhost_dup_check_support'
require_relative 'parser_compat'
require_relative '../compiler/ruby/compiler/module_importer'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
DECL = /^(?:PUB |PRIVATE )?(FN|STRUCT|UNION|ENUM|PROTOCOL)\s+([A-Za-z_]\w*[?!]?)/

groups = ParserCompat.package_groups(GEN)
pkg_paths = {}
groups.each { |n, m| pkg_paths[n] = m.map { |r| File.join(GEN, r) }.join(',') }
ParserCompat.generated_relatives(GEN).each { |r| pkg_paths[ParserCompat.package_name(r)] = File.join(GEN, r) }

total = 0
groups.each do |name, members|
  merged = PackageSource.merge(members.map { |r| File.join(GEN, r) },
                               resolve_pkg: ->(n) { pkg_paths[n] })
  seen = Hash.new { |h, k| h[k] = [] }
  current = '?'
  merged.source.split("\n").each_with_index do |line, i|
    if (m = line.match(/\A# FILE: (.+)\z/))
      current = m[1].sub("#{GEN}/", '')
      next
    end
    d = DECL.match(line) or next
    seen[[d[1], d[2]]] << "#{current} (merged line #{i + 1})"
  end
  # A group also collides with the PUB surface of any package it imports: the
  # merged source declares its own copy of a helper another unit exports, and
  # the importer sees two. Neither a member scan nor a merged scan finds that.
  imported = {}
  merged.source.scan(/^REQUIRE "pkg:([A-Za-z0-9_]+)"/).flatten.uniq.each do |dep|
    path = pkg_paths[dep]
    next if path.nil? || path.include?(',')
    next if members.any? { |r| File.join(GEN, r) == path }

    File.readlines(path).each_with_index do |line, i|
      next unless line.start_with?('PUB ')

      d = DECL.match(line) or next
      imported[[d[1], d[2]]] ||= "#{path.sub("#{GEN}/", '')}:#{i + 1}"
    end
  end
  imported.each do |key, where|
    seen[key] << "#{where} (PUB, imported)" if seen.key?(key)
  end

  dups = seen.select { |_k, v| v.length > 1 }
  next if dups.empty?

  puts "#{name}: #{dups.length} collisions in the merged source"
  dups.sort_by { |k, _v| k[1] }.each { |(kind, sym), where| puts "  #{kind} #{sym}\n    #{where.join("\n    ")}" }
  total += dups.length
end
puts "total collisions: #{total}"
exit(total.zero? ? 0 : 1)
