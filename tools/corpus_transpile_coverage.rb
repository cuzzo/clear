#! /usr/bin/env ruby
# Transpile-only coverage driver for the examples/ + benchmarks/ corpus.
#
# We do NOT run these programs (running exercises the emitted Zig binary,
# not the Ruby compiler). We transpile each one in a single process so
# every .clear drives the real pass pipeline — CompilerFrontend.compile →
# MIRLowering → MIRChecker → MIREmitter — and SimpleCov records the
# branch arms each shape takes in compiler/ruby. One process, no Zig, no 100x
# Ruby startup. Per-file errors are collected so the entire corpus is reported,
# then strict mode (the default) exits non-zero if any active source failed.
# `--allow-failures` is available only for an explicitly diagnostic run.
#
# Usage: COVERAGE=1 ruby tools/corpus_transpile_coverage.rb
#        bundle exec ruby compiler/spec/collate_coverage.rb
#        ruby tools/branch_gap_report.rb

require 'bundler/setup'
require 'optparse'
require_relative '../compiler/spec/coverage_bootstrap'
CoverageBootstrap.start('corpus-transpile')

require_relative '../compiler/ruby/backends/transpiler'

ROOT = File.expand_path('..', __dir__)
opts = { shard: nil, strict: true }

# Historical MiniVM snapshots, retained as source/reference material. They are
# not active programs: _bc_runner.clear is the maintained runner and exercises
# the same compiler surface. Keep this list exact and visible; strict mode must
# still fail for every active example and benchmark rather than swallowing an
# open-ended set of errors.
REFERENCE_ONLY = %w[
  examples/minivm/_scheme_runner.clear
  examples/minivm/sus-int.clear
].freeze

OptionParser.new do |o|
  o.banner = "Usage: COVERAGE=1 ruby tools/corpus_transpile_coverage.rb [--shard I/N] [--allow-failures]"
  o.on("--strict") { opts[:strict] = true }
  o.on("--allow-failures") { opts[:strict] = false }
  o.on("--shard I/N") do |v|
    idx, total = v.split("/", 2).map(&:to_i)
    abort "--shard expects I/N with N > 0 and 0 <= I < N" unless total && total.positive? && idx && idx >= 0 && idx < total
    opts[:shard] = [idx, total]
  end
end.parse!

files = Dir.glob(File.join(ROOT, '{examples,benchmarks}', '**', '*.clear'))
              .reject { |f| File.basename(f).start_with?('._') }
              .reject { |f| f.split(File::SEPARATOR).include?('bench.profile') }
              .reject { |f| REFERENCE_ONLY.include?(f.sub(ROOT + '/', '')) }
              .sort
if opts[:shard]
  idx, total = opts[:shard]
  files = files.each_with_index.select { |_file, i| (i % total) == idx }.map(&:first)
end

ok = 0
fail = 0
files.each do |path|
  src_dir = File.dirname(path)
  code = File.read(path)
  begin
    importer = ModuleImporter.new(base_dir: src_dir, use_mir: true)
    result = CompilerFrontend.compile(code, importer: importer, source_dir: src_dir)
    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: src_dir,
      debug_mode: true
    ))
    program = lowering.lower_program(result.ast)
    MIRChecker.new.check_program!(program)
    emitter = MIREmitter.new
    program.items.each { |item| emitter.emit(item) }
    ok += 1
  rescue StandardError, ScriptError => e
    fail += 1
    warn "  skip #{path.sub(ROOT + '/', '')}: #{e.class}: #{e.message.lines.first&.strip}"
  end
end

puts "corpus transpile coverage: #{ok} transpiled, #{fail} skipped, #{files.size} total"
exit 1 if opts[:strict] && fail.positive?
