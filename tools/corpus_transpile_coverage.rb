#! /usr/bin/env ruby
# Transpile-only coverage driver for the examples/ + benchmarks/ corpus.
#
# We do NOT run these programs (running exercises the emitted Zig binary,
# not the Ruby compiler). We transpile each one in a single process so
# every .cht drives the real pass pipeline — CompilerFrontend.compile →
# MIRLowering → MIRChecker → MIREmitter — and SimpleCov records the
# branch arms each shape takes in src/. One process, no Zig, no 100x
# Ruby startup. Per-file errors are swallowed: many examples are module
# or package fragments that don't transpile standalone, and even a
# failed compile exercises parser/annotator/escape paths we want counted.
#
# Usage: COVERAGE=1 ruby tools/corpus_transpile_coverage.rb
#        bundle exec ruby spec/collate_coverage.rb
#        ruby tools/branch_gap_report.rb

require 'bundler/setup'
require_relative '../spec/coverage_bootstrap'
CoverageBootstrap.start('corpus-transpile')

require_relative '../src/backends/transpiler'

ROOT = File.expand_path('..', __dir__)
files = Dir.glob(File.join(ROOT, '{examples,benchmarks}', '**', '*.cht'))
              .reject { |f| File.basename(f).start_with?('._') }
              .reject { |f| f.split(File::SEPARATOR).include?('bench.profile') }
              .sort

ok = 0
fail = 0
files.each do |path|
  src_dir = File.dirname(path)
  code = File.read(path)
  begin
    importer = ModuleImporter.new(base_dir: src_dir, use_mir: true)
    result = CompilerFrontend.compile(code, importer: importer, source_dir: src_dir)
    lowering = MIRLowering.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: src_dir,
      debug_mode: true
    )
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
