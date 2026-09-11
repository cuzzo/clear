#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 2a measurement: run the CLEAR frontend over the LINKED annotator
# closure -- every unit compiled together, no stubs -- and report every
# blocker it reaches, grouped by file.
#
# The build halts on the first CompilerError, so a round used to yield one
# blocker and no denominator. tools/probe_multi_error.rb already accumulates
# errors across statements for the per-function probe; pointing the same patch
# at a whole-program parse+annotate turns the round into a work list.
#
#   ruby tools/selfhost_stage2.rb                 # table + total
#   ruby tools/selfhost_stage2.rb --json out.json # machine-readable
#
# The later errors are guidance, not verdicts: after a failure the session's
# state is whatever the failed statement left behind, so treat the count as an
# upper bound that shrinks. Dedupe by (file, code) before ranking.

$PROGRAM_NAME = 'selfhost_stage2_support'
require 'json'
require 'optparse'
ROOT = File.expand_path('..', __dir__)
require_relative 'parser_compat'

out_json = nil
limit = nil
zig_out = nil
OptionParser.new do |o|
  o.on('--json PATH') { |v| out_json = v }
  o.on('--limit N', Integer) { |v| limit = v }
  # 2c: emit the closure's Zig and hand it to `zig build-exe`. The frontend
  # alone stops after lowering, which answers 2b but not whether the emitted
  # program is a program.
  o.on('--zig PATH') { |v| zig_out = v }
end.parse!(ARGV)

GEN = File.join(ROOT, 'compiler', 'src')

# The closure is what the annotator harness links: every unit the entry point
# reaches. Reuse the parser harness's package map so this measures exactly what
# the real build compiles.
groups = ParserCompat.package_groups(GEN)
entry = groups.find { |_n, m| m.include?('annotator/annotator.clear') }
abort 'no package group contains annotator/annotator.clear' unless entry

source = +''
source << %(REQUIRE "pkg:#{entry.first}";\n)
source << <<~CLEAR
  FN main() RETURNS !Void ->
    MUTABLE annotator = TRY (semanticAnnotator__new(NIL, NIL, NIL, FALSE, ""));
    RETURN;
  END
CLEAR

# The importer keeps an incremental module cache keyed on each unit's
# transitive source digests, but only when these are set -- `./clear` sets
# them, this harness did not, so every round recompiled all 177 units and took
# 15 minutes. Keyed on compiler CONTENT: a mirror swap rewrites every mtime.
if ENV['CLEAR_MODULE_CACHE_DIR'].to_s.empty? && ENV['CLEAR_DISABLE_MODULE_CACHE'].to_s.empty?
  require 'digest'
  ruby_src = Dir.glob(File.join(ROOT, 'compiler', 'ruby', '**', '*.rb')).sort
  ENV['CLEAR_MODULE_CACHE_DIR'] = File.join(ROOT, 'tmp', 'stage2-modcache')
  ENV['CLEAR_MODULE_CACHE_KEY'] = Digest::SHA256.hexdigest(ruby_src.map { |f| File.read(f) }.join)
end

ENV['CLEAR_PROBE_ERROR_CAP'] = (limit || 5000).to_s
require_relative 'probe_multi_error'
# 2a asks whether the closure ANNOTATES, 2b whether it LOWERS. Without this the
# first function that cannot lower ends the run, and 2b has no denominator.
require_relative 'probe_lowering_survives'
# A cache hit skips a unit's diagnostics as well as its compilation; replaying
# them is what lets a 52s warm run answer the same question as a 10m cold one.
require_relative 'probe_error_replay'
require_relative '../compiler/ruby/compiler/compiler_frontend'

dir = File.join(ROOT, 'tmp', 'stage2')
FileUtils.mkdir_p(dir)
path = File.join(dir, 'stage2_entry.clear')
File.write(path, source)

# Every group is a multi-file package: a comma-separated value registers all
# its members as one unit, the same shape `--pkg name=a.clear,b.clear` builds.
pkg_paths = {}
groups.each do |name, members|
  pkg_paths[name] = members.map { |rel| File.join(GEN, rel) }.join(',')
end
ParserCompat.generated_relatives(GEN).each do |rel|
  pkg_paths[ParserCompat.package_name(rel)] = File.join(GEN, rel)
end
importer = ModuleImporter.new(base_dir: GEN, pkg_paths: pkg_paths, use_mir: true)

# Which unit is compiling when an error is raised. The token carries a line
# into the MERGED package text and names no file, so without this a blocker
# cannot be attributed past "somewhere in the closure".
module Stage2Unit
  def compile_package_group(pkg_name, members)
    previous = $CLEAR_PROBE_UNIT
    $CLEAR_PROBE_UNIT = pkg_name.to_s
    super
  ensure
    $CLEAR_PROBE_UNIT = previous
  end

  def compile_file(path, caller_dir: nil)
    previous = $CLEAR_PROBE_UNIT
    $CLEAR_PROBE_UNIT = path.to_s
    super
  ensure
    $CLEAR_PROBE_UNIT = previous
  end
end
ModuleImporter.prepend(Stage2Unit)

first_error = nil
zig_source = nil
begin
  if zig_out
    require_relative '../compiler/ruby/backends/transpiler'
    zig_source = ZigTranspiler.new.transpile(source, source_dir: GEN, pkg_paths: pkg_paths)
  else
    CompilerFrontend.compile(source, importer: importer, source_dir: GEN)
  end
rescue StandardError => e
  first_error = e
end

# The closure compiles as ONE unit: PackageSource.merge concatenates every
# member, so a diagnostic's line is an offset into that merge and names no
# file. The merge marks each member with `# FILE: <path>`, which is enough to
# translate a line back to the file and line a person can open.
def build_marker_index(members, pkg_paths, gen)
  merged = PackageSource.merge(members, resolve_pkg: ->(name) { pkg_paths[name] })
  index = []
  current = nil
  offset = 0
  merged_lines = merged.source.split("\n", -1)
  merged_lines.each_with_index do |line, idx|
    m = line.match(/\A# FILE: (.+)\z/)
    if m
      current = m[1]
      # The merge drops each member's REQUIRE lines, so the block does not
      # start at the file's line 1. Anchor on the first surviving line.
      first_body = merged_lines[idx + 1]
      real = File.exist?(current) ? File.readlines(current, chomp: true) : []
      dropped = real.index(first_body) || 0
      offset = idx + 1 - dropped
    end
    index << (current ? [current.sub("#{gen}/", ''), idx + 1 - offset] : nil)
  end
  index
end

MARKERS = {}
groups.each do |name, members|
  MARKERS[name] = build_marker_index(members.map { |rel| File.join(GEN, rel) }, pkg_paths, GEN)
end

records = ProbeMultiError::RECORDED.each_with_index.map do |e, i|
  unit = ProbeMultiError::UNITS[i]
  text = e.message.to_s.gsub(/\e\[[0-9;]*m/, '')
  line = text.lines.map(&:strip).reject(&:empty?).first.to_s
  code = line[/\[([A-Z_]+)\]/, 1] || 'UNCODED'
  tok = e.respond_to?(:token) ? e.token : nil
  index = unit && MARKERS[unit]
  where = if index && tok&.line
    index[tok.line - 1]
  elsif unit && File.exist?(unit.to_s)
    [unit.to_s.sub("#{GEN}/", ''), tok&.line]
  end
  { 'code' => code, 'message' => line, 'line' => tok&.line, 'column' => tok&.column,
    'file' => where && where[0], 'file_line' => where && where[1] }
end
ProbeMultiError::RECORDED.clear
ProbeMultiError::UNITS.clear

# A raise from a later pass names the merged package text it was lexed from.
# Every such site is `pkg:<name>:<line>:<col>`; the marker index already knows
# how to turn that back into a file a person can open.
def resolve_pkg_sites(text)
  text.gsub(/pkg:([A-Za-z0-9_]+):(\d+)/) do
    where = MARKERS[Regexp.last_match(1)]&.[](Regexp.last_match(2).to_i - 1)
    where ? "#{where[0]}:#{where[1]}" : Regexp.last_match(0)
  end
end

# ALWAYS, not only when nothing accumulated: gating this on `records.empty?`
# hid the raise behind any annotation blocker and made two runs that failed
# identically look like one clean and one broken.
if first_error
  warn 'stage 2a: the frontend raised:'
  warn resolve_pkg_sites(first_error.message.to_s.gsub(/\e\[[0-9;]*m/, '').lines.first(6).join)
  if ENV['STAGE2_BACKTRACE']
    warn first_error.backtrace.to_a.grep(%r{compiler/ruby|tools/}).first(45).join("\n")
  end
end

lowering = ProbeLoweringSurvives::RECORDED.map do |r|
  where = r['file'].to_s.start_with?('pkg:') ? resolve_pkg_sites("#{r['file']}:#{r['line']}") : nil
  r.merge('site' => where || "#{r['file'] || r['unit']}:#{r['line']}")
end
ProbeLoweringSurvives::RECORDED.clear

by_code = records.group_by { |r| r['code'] }.transform_values(&:length).sort_by { |_c, n| -n }
by_file = records.group_by { |r| r['file'] || '?' }.transform_values(&:length).sort_by { |_f, n| -n }
puts "stage 2a blockers: #{records.length}"
by_code.first(15).each { |c, n| puts format('%5d  %s', n, c) }
puts
by_file.first(15).each { |f, n| puts format('%5d  %s', n, f) }
puts
records.first(20).each do |r|
  puts format('  %s:%s  %s', r['file'] || '?', r['file_line'] || r['line'], r['message'][0, 150])
end
puts
stub_failed = lowering.count { |r| r['stub_failed'] }
passes = lowering.group_by { |r| r['pass'] }.transform_values(&:length).sort
puts "stage 2b failures by lowering pass: #{passes.inspect}"
puts "stage 2b unlowered functions: #{lowering.length} (#{stub_failed} could not even stub)"
lowering.group_by { |r| r['message'][0, 80] }.sort_by { |_m, g| -g.length }.first(10).each do |m, g|
  puts format('%5d  %s', g.length, m)
end
lowering.first(10).each { |r| puts format('  %s  %s  %s', r['site'], r['fn'], r['message'][0, 110]) }

if zig_out
  if zig_source
    File.write(zig_out, zig_source)
    puts
    puts "stage 2c: wrote #{zig_source.length} bytes of Zig to #{zig_out}"
  else
    puts
    puts 'stage 2c: no Zig emitted (the transpiler raised; see 2a/2b above)'
  end
end

File.write(out_json, JSON.pretty_generate({ 'annotate' => records, 'lower' => lowering })) if out_json
exit(records.empty? && lowering.empty? && first_error.nil? ? 0 : 1)
