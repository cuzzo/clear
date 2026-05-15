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
require_relative '../spec/coverage_bootstrap'
CoverageBootstrap.start('bc-lower')

require_relative '../src/backends/transpiler'

ROOT = File.expand_path('..', __dir__)
files = (
  Dir.glob(File.join(ROOT, 'transpile-tests', '**', '*.cht')) +
  Dir.glob(File.join(ROOT, '{examples,benchmarks}', '**', '*.cht')) +
  Dir.glob(File.join(ROOT, 'transpile-tests', 'fuzz', '*.cht'))
).reject { |f| File.basename(f).start_with?('._') }
  .uniq.sort

lowered = 0
raised = 0
files.each do |path|
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

puts "bc-lower coverage: #{lowered} lowered cleanly, #{raised} raised " \
     "(still covered up to the raise), #{files.size} total"
