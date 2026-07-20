# typed: strict
# frozen_string_literal: true

require "digest"
require "sorbet-runtime"
require "set"

require_relative "../backends/mir_emitter"
require_relative "../backends/transpiler"

module Incremental
  class EmittedItem < T::Struct
    const :key, String
    const :kind, Symbol
    const :name, T.nilable(String)
    const :code, String
    const :contract_fingerprint, T.nilable(String), default: nil
    const :state_before, MIREmitter::EmissionState
    const :state_after, MIREmitter::EmissionState
  end

  # A checked program represented at deterministic MIR emission boundaries.
  # The artifact never deserializes MIR or ownership data; a replacement can
  # enter only after the ordinary lowerer and MIRChecker have accepted it.
  class ProgramArtifact
    extend T::Sig

    sig { returns(String) }
    attr_reader :error_name_enum, :footer

    sig { returns(T::Array[EmittedItem]) }
    attr_reader :items

    sig { returns(MIREmitter::EmissionState) }
    attr_reader :final_state

    sig do
      params(
        error_name_enum: String,
        footer: String,
        items: T::Array[EmittedItem],
        final_state: MIREmitter::EmissionState,
      ).void
    end
    def initialize(error_name_enum:, footer:, items:, final_state:)
      @error_name_enum = error_name_enum
      @footer = footer
      @items = T.let(items.freeze, T::Array[EmittedItem])
      @final_state = final_state
    end

    sig { params(compilation: ZigTranspiler::MIRCompilation, footer: String).returns(ProgramArtifact) }
    def self.from_compilation(compilation, footer:)
      emitter = MIREmitter.new
      occurrence = T.let(Hash.new(0), T::Hash[String, Integer])
      items = compilation.program.items.filter_map do |node|
        before = emitter.emission_state
        code = emitter.emit(node)
        next if code.nil?

        kind, name = identity(node)
        identity_base = "#{kind}:#{name || node.class.name}"
        count = occurrence.fetch(identity_base, 0) + 1
        occurrence[identity_base] = count
        EmittedItem.new(
          key: "#{identity_base}:#{count}",
          kind: kind,
          name: name,
          code: code,
          contract_fingerprint: name && Digest::SHA256.hexdigest([
            compilation.frontend.derived_program.functions[name]&.fingerprint,
            compilation.frontend.program_mir_facts.functions[name]&.fingerprint,
          ].join("|")),
          state_before: before,
          state_after: emitter.emission_state,
        )
      end
      new(
        error_name_enum: compilation.error_name_enum,
        footer: footer,
        items: items,
        final_state: emitter.emission_state,
      )
    end

    sig { params(name: String).returns(T.nilable(EmittedItem)) }
    def function(name)
      matches = @items.select { |item| item.kind == :function && item.name == name }
      matches.one? ? matches.first : nil
    end

    sig { returns(T::Set[String]) }
    def support_code
      @items.filter_map { |item| item.code if item.kind == :support }.to_set
    end

    sig do
      params(
        replacement: EmittedItem,
        shift_source_lines_after: T.nilable(Integer),
        source_line_delta: Integer,
        relocatable_function_names: T::Set[String],
      ).returns(ProgramArtifact)
    end
    def replace_function(
      replacement,
      shift_source_lines_after: nil,
      source_line_delta: 0,
      relocatable_function_names: Set.new
    )
      replaced = T.let(false, T::Boolean)
      next_items = @items.each_with_index.map do |item, index|
        if item.kind == :function && item.name == replacement.name
          raise ArgumentError, "duplicate function artifact #{replacement.name}" if replaced

          replaced = true
          EmittedItem.new(
            key: item.key,
            kind: item.kind,
            name: item.name,
            code: replacement.code,
            contract_fingerprint: replacement.contract_fingerprint,
            state_before: item.state_before,
            state_after: item.state_after,
          )
        elsif root_function_artifact?(item, index, relocatable_function_names)
          relocate_source_lines(item, after: shift_source_lines_after, by: source_line_delta)
        else
          item
        end
      end
      raise ArgumentError, "missing function artifact #{replacement.name}" unless replaced

      ProgramArtifact.new(
        error_name_enum: @error_name_enum,
        footer: @footer,
        items: next_items,
        final_state: @final_state,
      )
    end

    sig { returns(String) }
    def render
      parts = @items.map(&:code)
      symbol_pool = MIREmitter.new(state: @final_state).symbol_pool_declarations
      parts.unshift(symbol_pool) unless symbol_pool.empty?
      body = T.let([], T::Array[String])
      parts.each_with_index do |part, index|
        if index.zero?
          body << part
        elsif T.must(parts[index - 1]).start_with?("// CLR:")
          body << "\n#{part}"
        else
          body << "\n\n#{part}"
        end
      end

      <<~ZIG
        #{@error_name_enum}

        #{body.join}

        // -------------------------------------------------------------------------
        // 3. Main Entry (Test Harness)
        // -------------------------------------------------------------------------
        #{@footer}
      ZIG
    end

    class << self
      extend T::Sig

      private

      sig { params(node: MIR::Emittable).returns([Symbol, T.nilable(String)]) }
      def identity(node)
        case node
        when MIR::FnDef
          [:function, node.name]
        when MIR::Comment
          [:comment, node.text]
        else
          [:support, node.respond_to?(:name) ? T.unsafe(node).name.to_s : nil]
        end
      end
    end

    private

    sig { params(item: EmittedItem, index: Integer, names: T::Set[String]).returns(T::Boolean) }
    def root_function_artifact?(item, index, names)
      return names.include?(item.name.to_s) if item.kind == :function
      return false unless item.kind == :comment

      following = @items[index + 1]
      following ? following.kind == :function && names.include?(following.name.to_s) : false
    end

    sig { params(item: EmittedItem, after: T.nilable(Integer), by: Integer).returns(EmittedItem) }
    def relocate_source_lines(item, after:, by:)
      return item unless after && !by.zero?

      relocated = item.code.gsub(/^([ \t]*\/\/ CLR:)(\d+)([ \t]*)$/) do
        line = Regexp.last_match(2).to_i
        line > after ? "#{Regexp.last_match(1)}#{line + by}#{Regexp.last_match(3)}" : Regexp.last_match(0)
      end
      relocated = relocated.gsub(/(\.setError\([^\n]*,\s*)(\d+)(\);)/) do
        line = Regexp.last_match(2).to_i
        line > after ? "#{Regexp.last_match(1)}#{line + by}#{Regexp.last_match(3)}" : Regexp.last_match(0)
      end
      relocated = relocated.gsub(/(CLEAR_PROFILE_TASK_SITE[^\n]*\bline=)(\d+)/) do
        line = Regexp.last_match(2).to_i
        line > after ? "#{Regexp.last_match(1)}#{line + by}" : Regexp.last_match(0)
      end
      relocated = relocated.gsub(/(\.clear_line\s*=\s*)(\d+)/) do
        line = Regexp.last_match(2).to_i
        line > after ? "#{Regexp.last_match(1)}#{line + by}" : Regexp.last_match(0)
      end
      return item if relocated == item.code

      EmittedItem.new(
        key: item.key,
        kind: item.kind,
        name: item.name,
        code: relocated,
        contract_fingerprint: item.contract_fingerprint,
        state_before: item.state_before,
        state_after: item.state_after,
      )
    end
  end
end
