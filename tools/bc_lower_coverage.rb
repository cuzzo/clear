#! /usr/bin/env ruby
# Drive src/ branch coverage of the `@target == :bc` lowering arms by
# re-lowering the EXISTING corpus with target: :bc. Zero new programs.
#
# Feasibility: the `@target == :bc` branches in mir_lowering fire during
# MIRLowering#lower_program (Ruby), which runs BEFORE the bytecode VM.
# The MiniVM (_bc_runner) is incomplete, but that is irrelevant here --
# we never execute, never even require BcEmitter to succeed. A program
# that hits `raise Unimplemented` inside a :bc arm still EXECUTED that
# arm (coverage is recorded up to the raise). So every per-file failure
# is rescued and counted as "lowering attempted".
#
# Usage:
#   COVERAGE=1 ruby tools/bc_lower_coverage.rb
#   bundle exec ruby spec/collate_coverage.rb
#   ruby tools/branch_gap_triage.rb

require 'bundler/setup'
require 'optparse'
require_relative '../spec/coverage_bootstrap'
CoverageBootstrap.start('bc-lower')

require_relative '../src/backends/transpiler'

ROOT = File.expand_path('..', __dir__)
DEFAULT_MAX_LINES = 1_000

shard = nil
total_shards = nil
max_lines = DEFAULT_MAX_LINES
OptionParser.new do |opts|
  opts.on('--shard SHARD', 'Run one shard as N/M') do |value|
    parts = value.split('/', 2).map(&:to_i)
    abort "--shard must be N/M" unless parts.size == 2

    shard, total_shards = parts
    abort "--shard index must be >= 0" if shard.negative?
    abort "--shard total must be > 0" unless total_shards.positive?
    abort "--shard index must be less than total" unless shard < total_shards
  end
  opts.on('--include-large', 'Include application-scale .cht files') do
    max_lines = nil
  end
end.parse!

def line_count(path)
  count = 0
  File.foreach(path) { count += 1 }
  count
end

def balanced_shard(files, shard, total_shards)
  return files unless shard && total_shards

  buckets = Array.new(total_shards) { { lines: 0, files: [] } }
  files
    .map { |path| [path, line_count(path)] }
    .sort_by { |path, lines| [-lines, path] }
    .each do |path, lines|
      bucket = buckets.min_by { |entry| [entry[:lines], entry[:files].size] }
      bucket[:files] << path
      bucket[:lines] += lines
    end
  buckets.fetch(shard).fetch(:files).sort
end

all_files = (
  Dir.glob(File.join(ROOT, 'transpile-tests', '**', '*.cht')) +
  Dir.glob(File.join(ROOT, '{examples,benchmarks}', '**', '*.cht')) +
  Dir.glob(File.join(ROOT, 'transpile-tests', 'fuzz', '*.cht'))
).reject { |f| File.basename(f).start_with?('._') }
  .reject { |f| f.split(File::SEPARATOR).include?('bench.profile') }
  .uniq.sort
unfiltered_count = all_files.size
all_files = all_files.reject { |path| line_count(path) > max_lines } if max_lines
files = balanced_shard(all_files, shard, total_shards)

lowered = 0
raised = 0
files.each_with_index do |path, index|
  warn "bc-lower coverage shard #{shard}/#{total_shards}: #{index}/#{files.size}" if shard && (index % 25).zero?

  dir = File.dirname(path)
  begin
    imp = ModuleImporter.new(base_dir: dir, use_mir: true)
    fe  = CompilerFrontend.compile(File.read(path), importer: imp, source_dir: dir)
    lo  = MIRLowering.new(
      struct_schemas:   fe.struct_schemas,
      enum_schemas:     fe.enum_schemas,
      union_schemas:    fe.union_schemas,
      fn_sigs:          fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer:         imp,
      source_dir:       dir,
      target:           :bc
    )
    lo.lower_program(fe.ast)
    lowered += 1
  rescue StandardError, ScriptError
    # A raise inside a :bc arm still covered that arm -- that is the
    # point. Count and continue; do not let the incomplete VM / a
    # bc-Unimplemented stop the batch.
    raised += 1
  end
end

scope = shard ? " shard #{shard}/#{total_shards}" : ""
large_note = max_lines ? ", skipped #{unfiltered_count - all_files.size} files over #{max_lines} lines" : ""
puts "bc-lower coverage#{scope}: #{lowered} lowered cleanly, #{raised} raised " \
     "(still covered up to the raise), #{files.size}/#{all_files.size} total#{large_note}"
