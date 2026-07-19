# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../backends/transpiler"
require_relative "program_artifact"

module Incremental
  class ZigCompilerConfig < T::Struct
    const :source_dir, String
    const :pkg_paths, T::Hash[String, String], factory: -> { {} }
    const :use_c_allocator, T::Boolean, default: false
    const :use_debug_allocator, T::Boolean, default: false
    const :test_mode, T::Boolean, default: false
    const :strict_test, T::Boolean, default: false
    const :default_stack, T.nilable(String), default: nil
    const :ownership_mode, Symbol, default: :default
  end

  # Thin adapter around the ordinary checked compiler boundary.  It owns no
  # invalidation policy and deliberately constructs a fresh transpiler for each
  # revision so importer and annotator state cannot leak between revisions.
  class ZigCompiler
    extend T::Sig

    sig { params(config: ZigCompilerConfig).void }
    def initialize(config)
      @config = config
    end

    sig { params(source: String).returns(ZigTranspiler::MIRCompilation) }
    def compile(source)
      transpiler = ZigTranspiler.new
      transpiler.compile_mir_program(
        source,
        source_dir: @config.source_dir,
        pkg_paths: @config.pkg_paths,
        use_c_allocator: @config.use_c_allocator,
        use_debug_allocator: @config.use_debug_allocator,
        test_mode: @config.test_mode,
        strict_test: @config.strict_test,
        exact_tiers: {},
        main_tier: nil,
        default_stack: @config.default_stack,
        ownership_mode: @config.ownership_mode,
      )
    end

    sig { params(compilation: ZigTranspiler::MIRCompilation).returns(ProgramArtifact) }
    def artifact(compilation)
      footer = ZigTranspiler.new.runtime_footer(compilation.main_stack_variant)
      ProgramArtifact.from_compilation(compilation, footer: footer)
    end

    sig do
      params(
        compilation: ZigTranspiler::MIRCompilation,
        name: String,
        state_before: MIREmitter::EmissionState,
      ).returns(T.nilable(EmittedItem))
    end
    def function_artifact(compilation, name:, state_before:)
      functions = compilation.program.items.grep(MIR::FnDef).select { |fn| fn.name == name }
      return nil unless functions.one?

      emitter = MIREmitter.new(state: state_before)
      code = emitter.emit(T.must(functions.first))
      return nil unless code

      EmittedItem.new(
        key: "function:#{name}:candidate",
        kind: :function,
        name: name,
        code: code,
        state_before: state_before,
        state_after: emitter.emission_state,
      )
    end
  end
end
