#!/usr/bin/env ruby
# frozen_string_literal: true

# Populate the module cache in dependency order, one wave at a time.
#
# A flat fan-out does NOT work: every worker starts cold and independently
# recompiles the shared base (ast/type, ast/ast, mir/mir), so 90 units cost
# 232 CPU-minutes and finish slower than compiling them in sequence.
#
# In dependency order the base is compiled once, in the first wave, and every
# later wave finds it already cached. Within a wave the units are independent
# by construction, so they parallelise cleanly.
$PROGRAM_NAME = 'selfhost_prewarm_support'
require 'set'
require 'etc'
require_relative 'parser_compat'

ROOT = File.expand_path('..', __dir__)
GEN = ENV['CLEAR_SELFHOST_SRC'] || File.join(ROOT, 'compiler', 'src')
JOBS = (ENV['JOBS'] || [Etc.nprocessors - 4, 1].max).to_i

groups = ParserCompat.package_groups(GEN)
in_group = groups.values.flatten.to_set
unit_of = {}
groups.each { |n, m| m.each { |r| unit_of[r] = n } }
singles = ParserCompat.generated_relatives(GEN).reject { |r| in_group.include?(r) }
singles.each { |r| unit_of[r] = r }

members = {}
groups.each { |n, m| members[n] = m }
singles.each { |r| members[r] = [r] }

# unit -> units it requires
deps = {}
members.each do |unit, mem|
  set = Set.new
  mem.each do |rel|
    text = File.read(File.join(GEN, rel))
    text.scan(/^REQUIRE "pkg:([A-Za-z0-9_]+)"/).flatten.each do |pkg|
      owner = groups.key?(pkg) ? pkg : nil
      if owner
        set << owner
      else
        rel_dep = ParserCompat.generated_relatives(GEN).find { |r| ParserCompat.package_name(r) == pkg }
        set << unit_of[rel_dep] if rel_dep
      end
    end
    text.scan(/^REQUIRE "(?!pkg:)([^"]+)"/).flatten.each do |path|
      abs = File.expand_path(File.join(File.dirname(File.join(GEN, rel)), path))
      r = abs.sub("#{GEN}/", '')
      set << unit_of[r] if unit_of[r]
    end
  end
  deps[unit] = (set - [unit])
end

# Kahn levels; a cycle among units lands in one wave together, which is correct
# -- they cannot be ordered relative to each other anyway.
waves = []
placed = Set.new
remaining = members.keys
until remaining.empty?
  ready = remaining.select { |u| (deps[u] - placed.to_a).empty? }
  ready = remaining.dup if ready.empty?
  waves << ready
  placed.merge(ready)
  remaining -= ready
end

warn "#{members.size} units in #{waves.length} waves: #{waves.map(&:length).inspect}"
script = File.join(__dir__, '..', 'tmp', 'prewarm_one.rb')
require 'fileutils'
FileUtils.mkdir_p(File.dirname(script))
File.write(script, <<~RB)
  $PROGRAM_NAME = 'selfhost_stage2_support'
  GEN = ENV.fetch('CLEAR_SELFHOST_SRC')
  require_relative '#{File.join(ROOT, 'tools', 'parser_compat')}'
  groups = ParserCompat.package_groups(GEN)
  pkg_paths = {}
  groups.each { |n, m| pkg_paths[n] = m.map { |r| File.join(GEN, r) }.join(',') }
  ParserCompat.generated_relatives(GEN).each { |r| pkg_paths[ParserCompat.package_name(r)] = File.join(GEN, r) }
  target = ARGV[0]
  target = ParserCompat.package_name(target) if target.end_with?('.clear')
  exit 0 unless pkg_paths[target]
  require_relative '#{File.join(ROOT, 'compiler', 'ruby', 'compiler', 'compiler_frontend')}'
  src = %(REQUIRE "pkg:\#{target}";\\nFN main() RETURNS !Void ->\\n  RETURN;\\nEND\\n)
  importer = ModuleImporter.new(base_dir: GEN, pkg_paths: pkg_paths, use_mir: true)
  begin
    CompilerFrontend.compile(src, importer: importer, source_dir: GEN)
  rescue StandardError
    # A unit that cannot compile still leaves its healthy dependencies cached.
  end
RB

done = 0
waves.each_with_index do |wave, i|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  wave.each_slice(JOBS) do |slice|
    pids = slice.map { |u| spawn(RbConfig.ruby, script, u, out: File::NULL, err: File::NULL) }
    pids.each { |pid| Process.wait(pid) }
  end
  done += wave.length
  warn format('wave %2d: %3d units, %6.1fs  (%d/%d done)', i + 1, wave.length,
              Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, done, members.size)
end
