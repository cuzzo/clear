# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "compilation_session"

module Incremental
  class TimedCompilationResult < T::Struct
    const :result, CompilationResult
    const :elapsed_seconds, Float
  end

  # Owns the persistent frontend state used by `clear watch`. The CLI supplies
  # paths and renders telemetry; compilation policy remains testable here.
  class WatchCompiler
    extend T::Sig

    sig { params(config: ZigCompilerConfig, module_path: String, verify: T::Boolean).void }
    def initialize(config:, module_path:, verify: false)
      @session = T.let(
        CompilationSession.new(
          compiler: ZigCompiler.new(config),
          module_path: module_path,
          verify: verify,
        ),
        CompilationSession,
      )
    end

    sig { params(path: String).returns(TimedCompilationResult) }
    def compile_file(path)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = @session.compile(File.read(path))
      elapsed = Float(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
      TimedCompilationResult.new(result: result, elapsed_seconds: elapsed)
    end
  end
end
