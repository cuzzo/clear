# typed: strict
# frozen_string_literal: true

require "digest"
require "sorbet-runtime"

require_relative "../backends/transpiler"
require_relative "../ffi/c_header_importer"
require_relative "dependency_snapshot"
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

  # Thin adapter around the ordinary checked compiler boundary. Transpilers are
  # revision-local, while imported modules are retained behind content-hash
  # invalidation. Root annotator state is never reused.
  class ZigCompiler
    extend T::Sig

    sig { params(config: ZigCompilerConfig).void }
    def initialize(config)
      @config = config
      @importer = T.let(build_importer, ModuleImporter)
      @dependency_snapshot = T.let(nil, T.nilable(DependencySnapshot))
    end

    sig { params(source: String).returns(T.nilable(String)) }
    def prepare_revision(source)
      source # reserved for source-declared dependency policies
      snapshot = @dependency_snapshot
      return nil unless snapshot

      changed = snapshot.changed_paths
      return nil if changed.empty?

      reset_importer!
      "dependency changed: #{changed.map { |path| File.basename(path) }.join(', ')}"
    end

    sig { params(source: String).void }
    def publish_dependencies!(source)
      paths = @importer.module_cache.keys.map(&:to_s)
      paths.concat(c_header_paths(source))
      @dependency_snapshot = DependencySnapshot.capture(paths)
    end

    sig { params(source: String, function_counter_seeds: T::Hash[String, MIRLoweringCounterSnapshot]).returns(ZigTranspiler::MIRCompilation) }
    def compile(source, function_counter_seeds: {})
      transpiler = ZigTranspiler.new(importer: @importer, source_dir: @config.source_dir)
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
        function_counter_seeds: function_counter_seeds,
      )
    end

    sig { returns(T::Array[String]) }
    def dependency_paths
      snapshot = @dependency_snapshot
      snapshot ? snapshot.entries.map(&:path) : []
    end

    sig { returns(DependencySnapshot) }
    def dependency_snapshot
      @dependency_snapshot || DependencySnapshot.new([])
    end

    sig { params(snapshot: DependencySnapshot).void }
    def restore_dependency_snapshot!(snapshot)
      @dependency_snapshot = snapshot
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
        contract_fingerprint: Digest::SHA256.hexdigest([
          compilation.frontend.derived_program.functions[name]&.fingerprint,
          compilation.frontend.program_mir_facts.functions[name]&.fingerprint,
        ].join("|")),
        state_before: state_before,
        state_after: emitter.emission_state,
      )
    end

    private

    sig { returns(ModuleImporter) }
    def build_importer
      ModuleImporter.new(
        base_dir: @config.source_dir,
        pkg_paths: @config.pkg_paths,
        use_mir: true,
      )
    end

    sig { void }
    def reset_importer!
      @importer = build_importer
      @dependency_snapshot = nil
    end

    sig { params(source: String).returns(T::Array[String]) }
    def c_header_paths(source)
      source.scan(CHeaderImporter::DIRECTIVE).map do |match|
        File.expand_path(T.must(match[0]), @config.source_dir)
      end
    end
  end
end
