# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "tmpdir"

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
      Dir.mktmpdir("clear-incremental-oracle") do |cache_dir|
        cache_path = File.join(cache_dir, "root.clearc")
        session = incremental_session(source_dir, cache_path)
        baseline = session.compile(source)
        clean_baseline = clean_outcome(source, source_dir)
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

        MutationCatalog.mutations(source, limit: @limit).each do |mutation|
          mutated = mutation.apply(source)
          # Construct a new session for each revision. This exercises the
          # portable cache boundary rather than proving only in-memory reuse.
          session = incremental_session(source_dir, cache_path)
          incremental, status = incremental_outcome(session, mutated)
          clean = clean_outcome(mutated, source_dir)
          comparison = ResultComparator.compare(incremental, clean)
          cases << CaseResult.new(
            description: mutation.description,
            status: status,
            equal: comparison.equal,
            incremental_digest: comparison.incremental_digest,
            clean_digest: comparison.clean_digest,
          )

          session = incremental_session(source_dir, cache_path)
          reverted, revert_status = incremental_outcome(session, source)
          revert_comparison = ResultComparator.compare(reverted, clean_baseline)
          cases << CaseResult.new(
            description: "revert #{mutation.description}",
            status: revert_status,
            equal: revert_comparison.equal,
            incremental_digest: revert_comparison.incremental_digest,
            clean_digest: revert_comparison.clean_digest,
          )
        end

        return RunResult.new(source_path: @source_path, cases: cases)
      end
    end

    private

    sig { params(source: String, source_dir: String).returns(String) }
    def clean_outcome(source, source_dir)
      compiler = Incremental::ZigCompiler.new(
        Incremental::ZigCompilerConfig.new(source_dir: source_dir),
      )
      compiler.artifact(compiler.compile(source)).render
    rescue StandardError => error
      diagnostic_outcome(error)
    end

    sig { params(source_dir: String, cache_path: String).returns(Incremental::CompilationSession) }
    def incremental_session(source_dir, cache_path)
      compiler = Incremental::ZigCompiler.new(
        Incremental::ZigCompilerConfig.new(source_dir: source_dir),
      )
      cache = Incremental::PortableCache.new(
        path: cache_path,
        module_path: @source_path,
        compiler_fingerprint: "differential-oracle-v1",
      )
      Incremental::CompilationSession.new(
        compiler: compiler,
        module_path: @source_path,
        cache: cache,
      )
    end

    sig { params(session: Incremental::CompilationSession, source: String).returns([String, Symbol]) }
    def incremental_outcome(session, source)
      result = session.compile(source)
      [result.zig, result.status]
    rescue StandardError => error
      [diagnostic_outcome(error), :error]
    end

    sig { params(error: StandardError).returns(String) }
    def diagnostic_outcome(error)
      "ERROR\0#{error.class.name}\0#{error.message}"
    end
  end
end
