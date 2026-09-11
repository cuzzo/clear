#!/usr/bin/env ruby
# frozen_string_literal: true

# Static gate: a type named in a signature or declaration that the unit cannot
# see. Same class as the function-visibility gate -- a type generated into one
# unit and used from another has to be PUB, and an annotation-time "unknown
# type" ends the run before anything accumulates.
$PROGRAM_NAME = 'selfhost_type_check_support'
require 'set'
require_relative 'parser_compat'
require_relative '../compiler/ruby/compiler/module_importer'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
TYPE_DECL = /^(PUB |PRIVATE )?(STRUCT|UNION|ENUM|PROTOCOL)\s+(\w+)/
# Builtins and shapes the checker has no business ruling on.
BUILTIN = %w[
  String Int64 UInt64 Int32 UInt32 Int16 UInt16 Int8 UInt8 Float64 Float32 Bool Void Any
  Byte Char Self T U K V R E List Set Map Pool HashMap Runtime Allocator NoReturn
].to_set

groups = ParserCompat.package_groups(GEN)
pkg_paths = {}
groups.each { |n, m| pkg_paths[n] = m.map { |r| File.join(GEN, r) }.join(',') }
ParserCompat.generated_relatives(GEN).each { |r| pkg_paths[ParserCompat.package_name(r)] = File.join(GEN, r) }
in_group = groups.values.flatten.to_set

all_types = Set.new
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each { |l| (m = TYPE_DECL.match(l)) && all_types << m[3] }
end

units = groups.map { |n, m| [n, m] } +
        ParserCompat.generated_relatives(GEN).reject { |r| in_group.include?(r) }.map { |r| [r, [r]] }

missing = Hash.new { |h, k| h[k] = [] }
units.each do |name, members|
  merged = PackageSource.merge(members.map { |r| File.join(GEN, r) }, resolve_pkg: ->(n) { pkg_paths[n] })
  src = merged.source
  visible = src.scan(TYPE_DECL).map { |_v, _k, t| t }.to_set
  # Transitively: a unit sees the PUB surface of everything its requires reach,
  # not just its direct ones.
  seen_pkgs = Set.new
  # A unit requires its neighbours two ways: as a package, and as a plain
  # relative path. Counting only the first makes the gate cry wolf.
# PackageSource.merge STRIPS each member's REQUIREs, so the merged text has
  # none to read -- the requires have to come from the member files themselves.
  queue = []
  members.each do |owner|
    own = File.read(File.join(GEN, owner))
    queue.concat(own.scan(/^REQUIRE "pkg:([A-Za-z0-9_]+)"/).flatten)
    own.scan(/^REQUIRE "(?!pkg:)([^"]+)"/).flatten.each do |relpath|
      cand = File.expand_path(File.join(File.dirname(File.join(GEN, owner)), relpath))
      queue << ParserCompat.package_name(cand.sub("#{GEN}/", '')) if File.file?(cand)
    end
  end
  queue.uniq!
  until queue.empty?
    dep = queue.shift
    next unless seen_pkgs.add?(dep)

    pkg_paths[dep].to_s.split(',').each do |path|
      next unless File.file?(path)

      text = File.read(path)
      text.each_line do |l|
        m = TYPE_DECL.match(l) or next
        visible << m[3] if m[1] == 'PUB '
      end
      queue.concat(text.scan(/^REQUIRE "pkg:([A-Za-z0-9_]+)"/).flatten)
      text.scan(/^REQUIRE "(?!pkg:)([^"]+)"/).flatten.each do |rp|
        cand = File.expand_path(File.join(File.dirname(path), rp))
        queue << ParserCompat.package_name(cand.sub("#{GEN}/", '')) if File.file?(cand)
      end
    end
  end
  # Types as they appear in signatures: after `:` or `RETURNS`, stripped of
  # capability sigils, optional markers and collection wrappers.
  src.scan(/(?::|RETURNS|AS)\s+([?!]?[\[\]{}A-Za-z0-9_@<>, ]+)/).flatten.each do |raw|
    raw.scan(/\b([A-Z]\w*)/).flatten.each do |t|
      next if BUILTIN.include?(t) || visible.include?(t) || !all_types.include?(t)

      missing[t] << name
    end
  end
end

missing.sort_by { |k, _v| k }.each do |type, where|
  puts "#{type}  not visible in: #{where.uniq.first(3).join(', ')}"
end
puts "types used but not visible: #{missing.length}"
exit(missing.empty? ? 0 : 1)
