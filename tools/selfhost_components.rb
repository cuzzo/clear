#!/usr/bin/env ruby
# frozen_string_literal: true

# Dependency-ordered component status for stages 2b / 2c / 3.
#
# The whole-closure build answers "is there an error" and gives no denominator:
# one failing function hides every function behind it, so "1 error" reads as a
# countdown when it is a walk. Stage 1 avoided that by compiling per function,
# but it STUBBED callees -- which removes the callee SIGNATURES, and the
# signatures are exactly what 2b tests. Every 2b defect fixed so far is a
# cross-boundary mismatch (a union widened at a field, a MUTABLE parameter
# cascading up three calls, an optional map value). Stub the callee and the
# error vanishes falsely.
#
# So: keep real signatures, and cut the program at the one place the dependency
# graph genuinely separates -- the package DAG. A package whose dependencies all
# compile can be compiled on its own, through the real importer, with every real
# signature in scope. That yields a monotonic denominator: X of N components
# clear 2b, each failure attributable to one component.
#
# SCCs cannot be split: scc_annotator_54 is 54 mutually recursive files. They
# condense into single components, which is why N is ~125 and not 177.
$PROGRAM_NAME = 'selfhost_components_support'
require 'json'
require 'open3'
require 'optparse'
require_relative 'parser_compat'

module SelfhostComponents
  extend self

  ROOT = File.expand_path('..', __dir__)
  GEN = File.join(ROOT, 'compiler', 'src')

  # component name => member relative paths
  def components
    groups = ParserCompat.package_groups(GEN)
    in_group = groups.values.flatten.to_set
    out = {}
    groups.each { |name, members| out[name] = members }
    ParserCompat.generated_relatives(GEN).reject { |r| in_group.include?(r) }.each do |r|
      out[ParserCompat.package_name(r)] = [r]
    end
    out
  end

  # package name => owning component
  def owner_index(comps)
    idx = {}
    comps.each do |name, members|
      idx[name] = name
      members.each { |r| idx[ParserCompat.package_name(r)] = name }
    end
    idx
  end

  def edges(comps, owners)
    deps = Hash.new { |h, k| h[k] = Set.new }
    comps.each do |name, members|
      members.each do |rel|
        File.read(File.join(GEN, rel)).scan(/^REQUIRE "pkg:([A-Za-z0-9_]+)"/).flatten.each do |pkg|
          target = owners[pkg]
          next if target.nil? || target == name

          deps[name] << target
        end
      end
    end
    deps
  end

  # Longest-path level: a component sits one below its deepest dependency, so
  # level 0 is everything with no in-tree dependencies.
  def levels(comps, deps)
    level = {}
    visiting = Set.new
    resolve = lambda do |name|
      return level[name] if level.key?(name)
      # A cycle here would mean the SCC condensation missed one; treat as level 0
      # rather than looping forever, and say so.
      if visiting.include?(name)
        warn "cycle through #{name} -- SCC condensation incomplete"
        return 0
      end

      visiting << name
      depth = deps[name].map { |d| resolve.call(d) + 1 }.max || 0
      visiting.delete(name)
      level[name] = depth
    end
    comps.each_key { |n| resolve.call(n) }
    level
  end

  def check(component, members)
    rel = members.first
    out, status = nil
    child_env = { 'CLEAR_UNIT_STAGE' => ENV.fetch('CLEAR_UNIT_STAGE', '2b') }
    Open3.popen2e(child_env, RbConfig.ruby, File.join(ROOT, 'tools', 'selfhost_check_unit.rb'), rel, chdir: ROOT) do |i, oe, t|
      i.close
      out = oe.read
      status = t.value
    end
    first = out.to_s.gsub(/\e\[[0-9;]*m/, '').lines.map(&:strip)
               .find { |l| l =~ /\[(Compiler|Parser) Error\]/ }
    { 'component' => component, 'members' => members.length,
      'ok' => status.success?, 'error' => first.to_s[0, 200] }
  end

  def main(argv)
    opts = { jobs: 8, out: File.join(ROOT, 'tmp', 'component_status.json') }
    OptionParser.new do |p|
      p.on('--list', 'Print the dependency levels and stop') { opts[:list] = true }
      p.on('--jobs N', Integer) { |v| opts[:jobs] = v }
      p.on('--max-level N', Integer, 'Only check components at or below this level') { |v| opts[:max_level] = v }
      p.on('--only NAME', 'Check a single component') { |v| opts[:only] = v }
      p.on('--out PATH') { |v| opts[:out] = v }
      p.on('--stage S', '2b (transpile only, default) or 2c (build an executable)') { |v| ENV['CLEAR_UNIT_STAGE'] = v }
    end.parse!(argv)

    comps = components
    owners = owner_index(comps)
    deps = edges(comps, owners)
    level = levels(comps, deps)
    by_level = comps.keys.group_by { |n| level[n] }.sort

    if opts[:list]
      puts "components=#{comps.length} (from #{ParserCompat.generated_relatives(GEN).length} files)"
      by_level.each do |lv, names|
        multi = names.count { |n| comps[n].length > 1 }
        puts "  level #{lv}: #{names.length} components#{multi.positive? ? " (#{multi} SCC)" : ''}"
      end
      puts "deepest level: #{by_level.last.first}"
      return 0
    end

    targets = comps.keys
    targets = targets.select { |n| level[n] <= opts[:max_level] } if opts[:max_level]
    targets = [opts[:only]] if opts[:only]

    results = []
    targets.each_slice(opts[:jobs]) do |batch|
      batch.map { |name| Thread.new { check(name, comps[name]) } }.each { |t| results << t.value }
      done = results.length
      ok = results.count { |r| r['ok'] }
      warn "  #{done}/#{targets.length} checked, #{ok} clear 2b"
    end

    ok = results.count { |r| r['ok'] }
    payload = { 'total' => targets.length, 'passing' => ok,
                'rate' => (targets.empty? ? 0 : (ok * 100.0 / targets.length).round(2)),
                'levels' => level, 'results' => results.sort_by { |r| [level[r['component']], r['component']] } }
    File.write(opts[:out], JSON.pretty_generate(payload))
    puts "@@COMPONENTS #{ENV.fetch('CLEAR_UNIT_STAGE', '2b')} #{ok}/#{targets.length} (#{payload['rate']}%)  -> #{opts[:out]}"
    results.reject { |r| r['ok'] }.sort_by { |r| level[r['component']] }.first(25).each do |r|
      puts "  L#{level[r['component']]} #{r['component']} (#{r['members']}f) :: #{r['error'][0, 120]}"
    end
    0
  end
end

exit(SelfhostComponents.main(ARGV)) if caller.empty?
