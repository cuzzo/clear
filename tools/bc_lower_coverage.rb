#! /usr/bin/env ruby
# Drive compiler/ruby branch coverage of the `@target == :bc` lowering arms by
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
#   COVERAGE=1 ruby tools/bc_lower_coverage.rb --jobs 32
#   bundle exec ruby compiler/spec/collate_coverage.rb
#   ruby tools/branch_gap_triage.rb

require 'bundler/setup'
require 'fileutils'
require 'json'
require 'optparse'
require 'rbconfig'

ROOT = File.expand_path('..', __dir__)
DEFAULT_MAX_LINES = 1_000

shard = nil
total_shards = nil
max_lines = DEFAULT_MAX_LINES
jobs = nil
OptionParser.new do |opts|
  opts.on('--jobs N', Integer, 'Run N local shards in parallel and merge their SimpleCov resultsets') do |value|
    jobs = value
    abort "--jobs must be > 0" unless jobs.positive?
  end
  opts.on('--shard SHARD', 'Run one shard as N/M') do |value|
    parts = value.split('/', 2).map(&:to_i)
    abort "--shard must be N/M" unless parts.size == 2

    shard, total_shards = parts
    abort "--shard index must be >= 0" if shard.negative?
    abort "--shard total must be > 0" unless total_shards.positive?
    abort "--shard index must be less than total" unless shard < total_shards
  end
  opts.on('--include-large', 'Include application-scale .clear files') do
    max_lines = nil
  end
end.parse!

if jobs
  abort "--jobs cannot be combined with --shard" if shard || total_shards

  coverage_root = File.expand_path(ENV.fetch("COVERAGE_DIR", "coverage"), ROOT)
  shard_root = File.join(coverage_root, "bc-lower-shards")
  FileUtils.rm_rf(shard_root)
  FileUtils.mkdir_p(shard_root)

  children = jobs.times.map do |index|
    shard_dir = File.join(shard_root, index.to_s)
    log_path = File.join(shard_root, "shard-#{index}.log")
    FileUtils.mkdir_p(shard_dir)

    env = ENV.to_h.merge(
      "COVERAGE" => "1",
      "COVERAGE_DIR" => shard_dir
    )
    args = [
      RbConfig.ruby,
      __FILE__,
      "--shard", "#{index}/#{jobs}"
    ]
    args << "--include-large" unless max_lines

    out = File.open(log_path, "w")
    pid = Process.spawn(env, *args, out: out, err: out, chdir: ROOT)
    out.close
    [index, pid, log_path, File.join(shard_dir, ".resultset.json")]
  end

  failures = []
  children.each do |index, pid, log_path, _resultset|
    _, status = Process.wait2(pid)
    unless status.success?
      failures << [index, status.exitstatus, log_path]
      warn "bc-lower coverage shard #{index}/#{jobs} failed; see #{log_path}"
    end
  end
  unless failures.empty?
    failures.each do |index, status, log_path|
      warn "=== bc-lower shard #{index}/#{jobs} status #{status} ==="
      warn File.read(log_path).lines.last(80).join if File.exist?(log_path)
    end
    exit 1
  end

  FileUtils.mkdir_p(coverage_root)
  merged_path = File.join(coverage_root, ".resultset.json")
  merged = File.exist?(merged_path) ? JSON.parse(File.read(merged_path)) : {}
  children.each do |_index, _pid, _log_path, resultset|
    abort "missing shard coverage resultset: #{resultset}" unless File.exist?(resultset)

    JSON.parse(File.read(resultset)).each do |key, value|
      unique_key = key
      suffix = 1
      while merged.key?(unique_key)
        suffix += 1
        unique_key = "#{key}-#{suffix}"
      end
      merged[unique_key] = value
    end
  end
  File.write(merged_path, JSON.pretty_generate(merged))

  children.each do |index, _pid, log_path, _resultset|
    summary = File.exist?(log_path) ? File.read(log_path).lines.grep(/^bc-lower coverage shard /).last : nil
    puts(summary || "bc-lower coverage shard #{index}/#{jobs}: completed")
  end
  puts "bc-lower coverage: merged #{children.size} shard resultsets into #{merged_path}"
  exit 0
end

require_relative '../compiler/spec/coverage_bootstrap'
CoverageBootstrap.start('bc-lower')

require_relative '../compiler/ruby/backends/transpiler'

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
  Dir.glob(File.join(ROOT, 'transpile-tests', '**', '*.clear')) +
  Dir.glob(File.join(ROOT, '{examples,benchmarks}', '**', '*.clear')) +
  Dir.glob(File.join(ROOT, 'transpile-tests', 'fuzz', '*.clear'))
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
    lo  = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas:   fe.struct_schemas,
      enum_schemas:     fe.enum_schemas,
      union_schemas:    fe.union_schemas,
      fn_sigs:          fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer:         imp,
      source_dir:       dir,
      target:           :bc
    ))
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
