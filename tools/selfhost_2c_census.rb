#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-file stage-2c census: does each function emit Zig and compile?
#
# The component sweep answers "does this closure type-check" and costs ~90
# minutes, because REQUIRE drags the whole dependency closure in. The function
# probe stubs every internal call, so a function's verification depends on that
# function alone -- which means 2c can be measured per file NOW, on the files
# whose components already clear 2b, instead of waiting for 90/90.
#
# Usage:
#   ruby tools/selfhost_2c_census.rb --files LIST [--jobs N] [--out PATH]
#   ruby tools/selfhost_2c_census.rb --passing STATUS.jsonl [--jobs N]
#
# --passing reads a component-status journal and censuses every single-file
# component that passed, newest verdict per component.

require 'json'
require 'optparse'
require 'open3'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'compiler', 'src')

def passing_files(journal)
  seen = {}
  File.foreach(journal) do |line|
    line = line.strip
    next if line.empty?
    row = JSON.parse(line) rescue next
    seen[row['component']] = row
  end
  seen.values.select { |r| r['ok'] && r['members'] == 1 }.filter_map do |r|
    name = r['component'].to_s
    next unless name.start_with?('rtoc_')
    [name.sub('rtoc_', '')].pack('H*') rescue nil
  end.compact.select { |rel| File.exist?(File.join(SRC, rel)) }
end

opts = { jobs: 6, out: File.join(ROOT, 'tmp', 'stage2c_census.json'), stage: 'zig' }
OptionParser.new do |p|
  p.on('--files LIST', 'comma-separated rel paths') { |v| opts[:files] = v.split(',') }
  p.on('--passing PATH', 'component status .jsonl') { |v| opts[:passing] = v }
  p.on('--jobs N', Integer) { |v| opts[:jobs] = v }
  p.on('--stage S', 'zig (default), binary, run') { |v| opts[:stage] = v }
  p.on('--out PATH') { |v| opts[:out] = v }
  p.on('--limit N', Integer) { |v| opts[:limit] = v }
end.parse!

files = opts[:files] || (opts[:passing] ? passing_files(opts[:passing]) : [])
abort "no files: pass --files or --passing" if files.empty?
files = files.sort_by { |f| File.size(File.join(SRC, f)) }   # cheapest first
files = files.first(opts[:limit]) if opts[:limit]

warn "stage-#{opts[:stage]} census over #{files.length} file(s)"
results = []
journal = "#{opts[:out]}.jsonl"
File.write(journal, '')

files.each_with_index do |rel, i|
  cmd = ['bundle', 'exec', 'ruby', File.join(ROOT, 'tools', 'selfhost_fn_probe.rb'),
         '--file', rel, '--stage', opts[:stage], '--jobs', opts[:jobs].to_s,
         '--out', File.join(File.dirname(opts[:out]), "probe_2c_#{i}.json")]
  # Disk is managed by the probe itself, which prunes cache entries and temp
  # dirs by AGE. Deleting them wholesale from here also deleted whatever a
  # concurrently running build was using -- an interactive `clear test`, a
  # second probe -- which surfaced as ENOENT and "failed to rename compilation
  # results" in the other process, not here.
  probe_out = File.join(File.dirname(opts[:out]), "probe_2c_#{i}.json")
  FileUtils.rm_f(probe_out)
  _out, _err, _st = Open3.capture3({ 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }, *cmd, chdir: ROOT)
  # Read the probe's own JSON rather than its stdout: the summary line only
  # names files that HAVE failures, so parsing text scored every 100%-clean
  # file as 'no verdict' -- inverting the census.
  rows = (JSON.parse(File.read(probe_out)) rescue nil)
  fail_n, total = rows ? [rows.count { |r| !r['ok'] }, rows.length] : [nil, nil]
  row = { 'file' => rel, 'fail' => fail_n, 'total' => total,
          'errors' => rows ? rows.reject { |r| r['ok'] }.map { |r| [r['fn'], r['error'].to_s[0, 160]] } : [] }
  results << row
  File.open(journal, 'a') { |f| f.puts(JSON.generate(row)) }
  warn format('  %3d/%-3d %-54s %s', i + 1, files.length, rel,
              fail_n ? "#{fail_n}/#{total} fail" : 'no verdict')
end

ok = results.count { |r| r['fail'] == 0 }
File.write(opts[:out], JSON.pretty_generate(
  'stage' => opts[:stage], 'files' => results.length, 'clean' => ok, 'results' => results
))
warn "\nstage-#{opts[:stage]}: #{ok}/#{results.length} files with every function clean"
