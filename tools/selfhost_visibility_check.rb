#!/usr/bin/env ruby
# frozen_string_literal: true

# Find calls that cannot resolve across a unit boundary, in seconds.
#
# A function the translation left package-private is invisible to every other
# unit, and the linked build reports it as an undefined function -- one ~25
# minute round per call site, because the raise ends the run. Visibility is
# textual, so a scan finds them all at once.
#
# rtoc names every translated method `owner__method`, so a call to one of those
# is a call to a unit-level function and must resolve to a definition in the
# same unit or to a PUB definition in a package the unit requires.
$PROGRAM_NAME = 'selfhost_visibility_check_support'
require_relative 'parser_compat'
require_relative '../compiler/ruby/compiler/module_importer'

GEN = File.join(File.expand_path('..', __dir__), 'compiler', 'src')
# A generic definition spells its type params before the arg list.
DEF  = /^(PUB |PRIVATE )?FN\s+([a-zA-Z_]\w*[?!]?)\s*(?:<[^>]*>)?\s*\(/
# Not just `owner__method`: rtoc also emits bare helpers like
# castNodeToLocatable, and those cross unit boundaries the same way. A call is
# worth resolving when the corpus defines a function of that name SOMEWHERE --
# anything else is an intrinsic or a method, which this check has no business
# ruling on.
CALL = /(?<![\w.])([a-z]\w*[?!]?)\s*\(/


# A name inside a string literal is not a call. Without this the gate reports
# `fixableError__levels()` because a diagnostic message quotes it.
def strip_strings(text)
  text.gsub(/"(?:\\.|[^"\\])*"/, '""')
end

groups = ParserCompat.package_groups(GEN)
pkg_paths = {}
groups.each { |n, m| pkg_paths[n] = m.map { |r| File.join(GEN, r) }.join(',') }
ParserCompat.generated_relatives(GEN).each { |r| pkg_paths[ParserCompat.package_name(r)] = File.join(GEN, r) }
in_group = groups.values.flatten.to_set

# Every function the corpus defines anywhere, so a call can be told apart from
# an intrinsic.
ALL_DEFINED = Set.new

# name => file that exports it PUB
exported = {}
ParserCompat.generated_relatives(GEN).each do |rel|
  File.readlines(File.join(GEN, rel)).each do |line|
    m = DEF.match(line) or next
    ALL_DEFINED << m[2]
    exported[m[2]] = rel if m[1] == 'PUB '
  end
end

units = groups.map { |n, m| [n, m] } +
        ParserCompat.generated_relatives(GEN).reject { |r| in_group.include?(r) }.map { |r| [r, [r]] }

missing = Hash.new { |h, k| h[k] = [] }
units.each do |name, members|
  # The merge inlines the packages a unit requires, so everything in the merged
  # text is visible to it whether or not it is PUB. Only a package that stays
  # SEPARATE -- emitted as its own Zig module -- exports just its PUB surface.
  merged = PackageSource.merge(members.map { |r| File.join(GEN, r) },
                               resolve_pkg: ->(n) { pkg_paths[n] })
  src = strip_strings(merged.source)
  visible = src.scan(DEF).map { |_vis, fn| fn }.to_set
  # Transitively: a unit sees the PUB surface of everything its requires reach.
  # Without this the gate claims a call is unresolved whenever the exporter is
  # one hop further away than a direct require -- the same error that made the
  # type gate claim 116.
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
      text.each_line do |line|
        d = DEF.match(line) or next
        visible << d[2] if d[1] == 'PUB '
      end
      queue.concat(text.scan(/^REQUIRE "pkg:([A-Za-z0-9_]+)"/).flatten)
      text.scan(/^REQUIRE "(?!pkg:)([^"]+)"/).flatten.each do |rp|
        cand = File.expand_path(File.join(File.dirname(path), rp))
        queue << ParserCompat.package_name(cand.sub("#{GEN}/", '')) if File.file?(cand)
      end
    end
  end
  src.scan(CALL).flatten.uniq.each do |called|
    next if visible.include?(called)
    next unless ALL_DEFINED.include?(called)

    missing[called] << name
  end
end

missing.sort_by { |k, _v| k }.each do |called, where|
  home = exported[called] ? "exported by #{exported[called]}" : 'NOT PUB anywhere'
  puts "#{called}  (#{home})\n    called from: #{where.first(4).join(', ')}#{where.length > 4 ? " +#{where.length - 4}" : ''}"
end
puts "unresolved cross-unit calls: #{missing.length}"
exit(missing.empty? ? 0 : 1)

# An EXTERN is declared per unit, not imported, so a unit that calls one it
# never declared is the same undefined-function blocker with a different cause.
externs = {}
Dir.glob(File.join(GEN, '**', '*.clear')).each do |path|
  File.readlines(path).each do |line|
    m = line.match(/^EXTERN FN\s+(\w+)\(/) or next
    externs[m[1]] ||= line.rstrip
  end
end
missing_externs = 0
Dir.glob(File.join(GEN, '**', '*.clear')).sort.each do |path|
  src = File.read(path)
  declared = src.scan(/^EXTERN FN\s+(\w+)\(/).flatten.to_set
  src.scan(/(?<![\w.])(\w+)\s*\(/).flatten.uniq.each do |called|
    next unless externs.key?(called) && !declared.include?(called)

    puts "#{path.sub("#{GEN}/", '')}: calls EXTERN #{called} without declaring it"
    missing_externs += 1
  end
end
puts "undeclared EXTERN calls: #{missing_externs}"
