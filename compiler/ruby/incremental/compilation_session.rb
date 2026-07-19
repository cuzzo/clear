# typed: strict
# frozen_string_literal: true

require "set"
require "sorbet-runtime"

require_relative "item_reconciler"
require_relative "portable_cache"
require_relative "program_artifact"
require_relative "zig_compiler"

module Incremental
  class CompilationResult < T::Struct
    const :zig, String
    const :status, Symbol
    const :reason, String
    const :changed_function, T.nilable(String), default: nil
  end

  class CompilationSnapshot < T::Struct
    const :source, String
    const :catalog, SourceCatalog
    const :artifact, ProgramArtifact
    const :function_counter_snapshots, T::Hash[String, MIRLoweringCounterSnapshot], factory: -> { {} }
    const :proven_contexts, T::Set[String], factory: -> { Set.new }
  end

  # Persistent, single-module compilation coordinator.  Unsupported edits are
  # not errors: they take the ordinary clean path and atomically replace the
  # retained snapshot only after compilation succeeds.
  class CompilationSession
    extend T::Sig

    sig { params(compiler: ZigCompiler, module_path: String, verify: T::Boolean, cache: T.nilable(PortableCache)).void }
    def initialize(compiler:, module_path:, verify: false, cache: nil)
      @compiler = compiler
      @module_path = T.let(File.expand_path(module_path), String)
      @verify = verify
      @cache = T.let(cache, T.nilable(PortableCache))
      @snapshot = T.let(nil, T.nilable(CompilationSnapshot))
      restore_portable_snapshot!
    end

    sig { params(source: String).returns(CompilationResult) }
    def compile(source)
      previous = @snapshot
      return clean_compile(source, reason: "initial compilation") unless previous
      dependency_reason = @compiler.prepare_revision(source)
      return clean_compile(source, reason: dependency_reason) if dependency_reason
      if source == previous.source
        return CompilationResult.new(
          zig: previous.artifact.render,
          status: :exact_hit,
          reason: "source is byte-identical",
        )
      end

      current = catalog(source)
      return clean_compile(source, reason: "source catalog unavailable") unless current

      decision = ItemReconciler.reconcile(previous.catalog, current)
      return clean_compile(source, reason: decision.reason) unless decision.fast_path
      return CompilationResult.new(
        zig: previous.artifact.render,
        status: :exact_hit,
        reason: decision.reason,
      ) unless decision.changed_function

      incremental_compile(source, current, T.must(decision.changed_function), previous)
    end

    private

    sig { params(source: String, reason: String).returns(CompilationResult) }
    def clean_compile(source, reason:)
      compilation = @compiler.compile(source)
      artifact = @compiler.artifact(compilation)
      @compiler.publish_dependencies!(source)
      current = catalog(source)
      if current
        @snapshot = CompilationSnapshot.new(
          source: source,
          catalog: current,
          artifact: artifact,
          function_counter_snapshots: compilation.function_counter_snapshots,
        )
      else
        @snapshot = nil
      end
      persist_snapshot!
      CompilationResult.new(zig: artifact.render, status: :clean, reason: reason)
    end

    sig do
      params(
        source: String,
        current: SourceCatalog,
        changed_name: String,
        previous: CompilationSnapshot,
      ).returns(CompilationResult)
    end
    def incremental_compile(source, current, changed_name, previous)
      baseline_function = previous.artifact.function(changed_name)
      return clean_compile(source, reason: "function emission is not independently addressable") unless baseline_function

      seed = previous.function_counter_snapshots[changed_name]
      seeds = seed ? { changed_name => seed } : {}
      proven_contexts = previous.proven_contexts.dup
      if context_sensitive?(previous.catalog, changed_name) && !proven_contexts.include?(changed_name)
        baseline_candidate = begin
          @compiler.compile(previous.catalog.isolated_source(changed_name), function_counter_seeds: seeds)
        rescue StandardError
          return clean_compile(source, reason: "reduced semantic context could not be verified")
        end
        baseline_replacement = @compiler.function_artifact(
          baseline_candidate,
          name: changed_name,
          state_before: baseline_function.state_before,
        )
        unless baseline_replacement && baseline_replacement.code == baseline_function.code
          return clean_compile(source, reason: "reduced semantic context changed function emission")
        end
        proven_contexts.add(changed_name)
      end

      candidate = begin
        @compiler.compile(current.isolated_source(changed_name), function_counter_seeds: seeds)
      rescue StandardError
        return clean_compile(source, reason: "isolated candidate compilation failed")
      end
      replacement = @compiler.function_artifact(
        candidate,
        name: changed_name,
        state_before: baseline_function.state_before,
      )
      return clean_compile(source, reason: "candidate did not emit one function") unless replacement
      unless same_state?(replacement.state_after, baseline_function.state_after)
        return clean_compile(source, reason: "function changed global emission state")
      end
      unless baseline_function.contract_fingerprint == replacement.contract_fingerprint
        return clean_compile(source, reason: "derived function contract changed")
      end
      unless error_names(candidate.error_name_enum).subset?(error_names(previous.artifact.error_name_enum))
        return clean_compile(source, reason: "function introduced a program error type")
      end
      candidate_program = @compiler.artifact(candidate)
      unless candidate_program.support_code.subset?(previous.artifact.support_code)
        return clean_compile(source, reason: "function introduced program-level Zig support")
      end

      artifact = previous.artifact.replace_function(replacement)
      zig = artifact.render
      verify_clean!(source, zig) if @verify
      @snapshot = CompilationSnapshot.new(
        source: source,
        catalog: current,
        artifact: artifact,
        function_counter_snapshots: previous.function_counter_snapshots,
        proven_contexts: proven_contexts,
      )
      @compiler.publish_dependencies!(source)
      persist_snapshot!
      CompilationResult.new(
        zig: zig,
        status: :incremental,
        reason: "checked isolated function artifact reused",
        changed_function: changed_name,
      )
    end

    sig { params(source: String, incremental_zig: String).void }
    def verify_clean!(source, incremental_zig)
      clean = @compiler.artifact(@compiler.compile(source)).render
      return if clean == incremental_zig

      raise "incremental compiler produced Zig that differs from a clean compilation"
    end

    sig { params(source: String).returns(T.nilable(SourceCatalog)) }
    def catalog(source)
      SourceCatalog.build(source, module_path: @module_path)
    rescue Lexer::Error, ParserError
      nil
    end

    sig { params(catalog: SourceCatalog, name: String).returns(T::Boolean) }
    def context_sensitive?(catalog, name)
      item = catalog.fetch(name)
      !T.must(item).called_functions.empty? || catalog.called_by_user_function?(name)
    end

    sig { params(value: String).returns(T::Set[String]) }
    def error_names(value)
      value.lines.filter_map do |line|
        match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/.match(line)
        match && match[1]
      end.to_set
    end

    sig { params(left: MIREmitter::EmissionState, right: MIREmitter::EmissionState).returns(T::Boolean) }
    def same_state?(left, right)
      left.symbol_literals == right.symbol_literals &&
        left.uses_c_callback == right.uses_c_callback &&
        left.if_bind_counter == right.if_bind_counter &&
        left.discard_counter == right.discard_counter &&
        left.deep_copy_counter == right.deep_copy_counter &&
        left.items_block_counter == right.items_block_counter &&
        left.owned_slice_counter == right.owned_slice_counter
    end

    sig { void }
    def restore_portable_snapshot!
      cached = @cache&.load
      return unless cached

      current = catalog(cached.source)
      return unless current

      @compiler.restore_dependency_snapshot!(cached.dependency_snapshot)
      @snapshot = CompilationSnapshot.new(
        source: cached.source,
        catalog: current,
        artifact: cached.artifact,
        function_counter_snapshots: cached.function_counter_snapshots,
      )
    end

    sig { void }
    def persist_snapshot!
      snapshot = @snapshot
      return unless snapshot && @cache

      @cache.write(
        source: snapshot.source,
        artifact: snapshot.artifact,
        function_counter_snapshots: snapshot.function_counter_snapshots,
        dependencies: @compiler.dependency_snapshot,
      )
    end
  end
end
