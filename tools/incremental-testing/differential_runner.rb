# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../compiler/ruby/incremental"
require_relative "mutation_catalog"
require_relative "result_comparator"

module IncrementalTesting
  class CaseResult < T::Struct
    const :description, String
    const :status, Symbol
    const :equal, T::Boolean
    const :incremental_digest, String
    const :clean_digest, String
  end

  class RunResult < T::Struct
    extend T::Sig

    const :source_path, String
    const :cases, T::Array[CaseResult]

    sig { returns(T::Boolean) }
    def success?
      cases.all?(&:equal)
    end
  end

  class DifferentialRunner
    extend T::Sig

    sig { params(source_path: String, limit: Integer).void }
    def initialize(source_path:, limit:)
      @source_path = T.let(File.expand_path(source_path), String)
      @limit = T.let(limit, Integer)
    end

    sig { returns(RunResult) }
    def run
      source = File.binread(@source_path)
      source_dir = File.dirname(@source_path)
      compiler = Incremental::ZigCompiler.new(
        Incremental::ZigCompilerConfig.new(source_dir: source_dir),
      )
      session = Incremental::CompilationSession.new(
        compiler: compiler,
        module_path: @source_path,
      )
      baseline = session.compile(source)
      clean_baseline = compiler.artifact(compiler.compile(source)).render
      baseline_comparison = ResultComparator.compare(baseline.zig, clean_baseline)
      cases = T.let([
        CaseResult.new(
          description: "initial clean compilation",
          status: baseline.status,
          equal: baseline_comparison.equal,
          incremental_digest: baseline_comparison.incremental_digest,
          clean_digest: baseline_comparison.clean_digest,
        ),
      ], T::Array[CaseResult])

      MutationCatalog.literal_mutations(source, limit: @limit).each do |mutation|
        mutated = mutation.apply(source)
        incremental = session.compile(mutated)
        clean = compiler.artifact(compiler.compile(mutated)).render
        comparison = ResultComparator.compare(incremental.zig, clean)
        cases << CaseResult.new(
          description: mutation.description,
          status: incremental.status,
          equal: comparison.equal,
          incremental_digest: comparison.incremental_digest,
          clean_digest: comparison.clean_digest,
        )

        reverted = session.compile(source)
        revert_comparison = ResultComparator.compare(reverted.zig, clean_baseline)
        cases << CaseResult.new(
          description: "revert #{mutation.description}",
          status: reverted.status,
          equal: revert_comparison.equal,
          incremental_digest: revert_comparison.incremental_digest,
          clean_digest: revert_comparison.clean_digest,
        )
      end

      RunResult.new(source_path: @source_path, cases: cases)
    end
  end
end
