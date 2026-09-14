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
require 'digest'
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

  # A component's verdict depends on its own sources AND on its dependencies'
  # sources, because what it is being checked against is their SIGNATURES. So
  # the reuse key is a digest over the whole dependency closure -- the same
  # thing the module cache keys its records on. Changing a level-0 file
  # legitimately invalidates everything above it; changing a leaf invalidates
  # only itself.
  def file_digest(path)
    @file_digests ||= {}
    @file_digests[path] ||= Digest::SHA256.file(path).hexdigest
  rescue Errno::ENOENT
    'missing'
  end

  def transitive_deps(deps, name, memo = {}, stack = Set.new)
    return memo[name] if memo.key?(name)
    return Set.new unless stack.add?(name)

    acc = Set.new
    deps[name].each do |d|
      acc << d
      acc.merge(transitive_deps(deps, d, memo, stack))
    end
    stack.delete(name)
    memo[name] = acc
  end

  # The COMPILER is an input too. A verdict says "this component compiles with
  # this compiler"; fixing a lowering bug in compiler/ruby or a helper in the Zig
  # runtime can turn a failure into a pass, and keying only on compiler/src
  # would keep serving the stale verdict. Hashing every compiler source on each
  # run is far too slow, so use the newest mtime across the compiler trees --
  # cheap, and it moves whenever anything there is edited.
  def compiler_stamp
    @compiler_stamp ||= begin
      newest = %w[compiler/ruby zig/lib zig/runtime].flat_map do |dir|
        Dir.glob(File.join(ROOT, dir, '**', '*.{rb,zig}'))
      end.map { |f| File.mtime(f).to_i }.max || 0
      newest.to_s
    end
  end

  def closure_digest(comps, deps, name, memo = {})
    names = [name] + transitive_deps(deps, name, memo).to_a
    files = names.flat_map { |n| comps[n] || [] }.uniq.sort
    parts = files.map { |r| "#{r}:#{file_digest(File.join(GEN, r))}" }
    parts << "compiler:#{compiler_stamp}"
    Digest::SHA256.hexdigest(parts.join("\n"))
  end

  # Prior verdicts, newest wins (the journal is append-only).
  def load_prior(journal)
    return {} unless File.exist?(journal)

    File.readlines(journal).each_with_object({}) do |line, acc|
      row = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      acc[row['component']] = row if row['component']
    end
  end

  def check(component, members)
    rel = members.first
    out, status = nil
    # Through bundler: the child requires parser_compat, which needs msgpack from
    # the bundle. A bare ruby child dies on LoadError instead of checking anything.
    child_env = { 'CLEAR_UNIT_STAGE' => ENV.fetch('CLEAR_UNIT_STAGE', '2b') }
    cmd = ['bundle', 'exec', 'ruby', File.join(ROOT, 'tools', 'selfhost_check_unit.rb'), rel]
    Open3.popen2e(child_env, *cmd, chdir: ROOT) do |i, oe, t|
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
      p.on('--force', 'Re-check every component, ignoring unchanged verdicts') { opts[:force] = true }
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

    # A worker QUEUE, not batches: each_slice joins a whole slice, so one giant
    # SCC (scc_annotator_54 is 54 files, ~30 min) stalls every fast component
    # sharing its slice and nothing is reported until it lands. Shallow levels
    # first, so the foundation reports while the blobs grind.
    targets = targets.sort_by { |n| [level[n], -comps[n].length] }

    journal = "#{opts[:out]}.jsonl"
    prior = opts[:force] ? {} : load_prior(journal)
    digest_memo = {}
    digests = targets.to_h { |n| [n, closure_digest(comps, deps, n, digest_memo)] }
    reused = []
    stale = targets.reject do |n|
      old_row = prior[n]
      next false unless old_row && old_row['digest'] == digests[n]

      reused << old_row
      true
    end
    warn "  #{reused.length} unchanged (reused), #{stale.length} to check" unless opts[:force]

    queue = Queue.new
    stale.each { |n| queue << n }
    results = reused.dup
    lock = Mutex.new
    File.write(journal, reused.map { |r| "#{JSON.generate(r)}\n" }.join)
    stage = ENV.fetch('CLEAR_UNIT_STAGE', '2b')
    workers = Array.new(opts[:jobs].clamp(1, targets.length)) do
      Thread.new do
        while (name = (begin
          queue.pop(true)
        rescue ThreadError
          nil
        end))
          r = check(name, comps[name])
          lock.synchronize do
            results << r
            # Append as it completes: a killed sweep still leaves its denominator.
            File.open(journal, 'a') do |f|
              f.puts(JSON.generate(r.merge('level' => level[name], 'digest' => digests[name])))
            end
            warn "  #{results.length}/#{targets.length} (#{reused.length} reused), " \
                 "#{results.count { |x| x['ok'] }} clear #{stage}  " \
                 "(last: L#{level[name]} #{name[0, 30]} #{r['ok'] ? 'ok' : 'FAIL'})"
          end
        end
      end
    end
    workers.each(&:join)

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
