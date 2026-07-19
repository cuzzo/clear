# typed: strict
# frozen_string_literal: true

require "set"
require "sorbet-runtime"

require_relative "item_reconciler"
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
  end

  # Persistent, single-module compilation coordinator.  Unsupported edits are
  # not errors: they take the ordinary clean path and atomically replace the
  # retained snapshot only after compilation succeeds.
  class CompilationSession
    extend T::Sig

    sig { params(compiler: ZigCompiler, module_path: String, verify: T::Boolean).void }
    def initialize(compiler:, module_path:, verify: false)
      @compiler = compiler
      @module_path = T.let(File.expand_path(module_path), String)
      @verify = verify
      @snapshot = T.let(nil, T.nilable(CompilationSnapshot))
    end

    sig { params(source: String).returns(CompilationResult) }
    def compile(source)
      previous = @snapshot
      return clean_compile(source, reason: "initial compilation") unless previous
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
      current = catalog(source)
      if current
        @snapshot = CompilationSnapshot.new(source: source, catalog: current, artifact: artifact)
      else
        @snapshot = nil
      end
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

      candidate = begin
        @compiler.compile(current.isolated_source(changed_name))
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
      unless same_function_contract?(baseline_function.code, replacement.code)
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
      @snapshot = CompilationSnapshot.new(source: source, catalog: current, artifact: artifact)
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

    sig { params(left: String, right: String).returns(T::Boolean) }
    def same_function_contract?(left, right)
      left.lines.first == right.lines.first
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
  end
end
