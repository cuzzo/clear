# frozen_string_literal: true

module FactMine
  module Syntax
    ProtocolMethodEffect = Struct.new(:file, :owner, :name, :line, :reads, :writes,
                                      keyword_init: true)
    ProtocolCall = Struct.new(:mid, :file, :owner, :defn, :line, :span, keyword_init: true)
    ProtocolMethodPath = Struct.new(:file, :owner, :name, :line, :calls, keyword_init: true)
    ProtocolPath = Struct.new(:calls, :terminal, keyword_init: true)
    ProtocolLexicon = Struct.new(
      :path_limit, :declarative_mids, :test_dsl_mids, :ignored_mids,
      :optional_diagnostic_mids, :mutating_mids, :non_mutating_operator_mids,
      :mutating_suffixes,
      keyword_init: true
    )

    EMPTY_PROTOCOL_LEXICON = ProtocolLexicon.new(
      path_limit: 64,
      declarative_mids: [].freeze,
      test_dsl_mids: [].freeze,
      ignored_mids: [].freeze,
      optional_diagnostic_mids: [].freeze,
      mutating_mids: [].freeze,
      non_mutating_operator_mids: [].freeze,
      mutating_suffixes: [].freeze
    ).freeze

    @protocol_lexicons = {}

    def self.register_protocol_lexicon(language, lexicon)
      @protocol_lexicons[language.to_sym] = lexicon
    end

    def self.protocol_lexicon_for(language)
      @protocol_lexicons.fetch(language.to_sym, EMPTY_PROTOCOL_LEXICON)
    end

    def self.protocol_ignored_mids(language)
      protocol_lexicon_for(language).ignored_mids
    end

    class Document
      def protocol_method_effects
        @protocol_method_effects ||= adapter.protocol_method_effects(self)
      end

      def protocol_call_paths
        @protocol_call_paths ||= adapter.protocol_call_paths(self)
      end
    end

    class TreeSitterLanguageAdapter
      def protocol_method_effects(document)
        behavior = Syntax::NormalizedExtractionBehavior.for(document.language)

        document.function_defs.map do |function_def|
          reads = document.state_reads.select do |read|
            read.owner == function_def.owner && read.function == function_def.name
          end.filter_map { |read| behavior.protocol_read_label_from_state(read) }

          reads.concat(document.call_sites.select do |call|
            call.owner == function_def.owner && call.function == function_def.name
          end.filter_map do |call|
            label = behavior.protocol_read_label_from_call(call)
            next nil if label.to_s.empty?

            label
          end)
          reads = reads.uniq.sort

          writes = document.state_writes.select do |write|
            write.owner == function_def.owner && write.function == function_def.name
          end.filter_map { |write| behavior.protocol_write_label(write) }.uniq.sort

          ProtocolMethodEffect.new(
            file: function_def.file,
            owner: function_def.owner,
            name: function_def.name.to_s.split(/[.:]/).last,
            line: function_def.line,
            reads: reads,
            writes: writes
          )
        end
      end

      def protocol_call_paths(document)
        document.function_defs.map do |function_def|
          calls = protocol_self_calls(document, function_def)

          protocol_call_variants(calls, function_def).map do |path_calls|
            ProtocolMethodPath.new(
              file: function_def.file,
              owner: function_def.owner,
              name: function_def.name.to_s.split(/[.:]/).last,
              line: function_def.line,
              calls: path_calls
            )
          end
        end.flatten
      end

      def protocol_self_calls(document, function_def)
        document.call_sites.select do |call|
            call.owner == function_def.owner &&
              call.function == function_def.name &&
              call.receiver.to_s == "self"
        end.map do |call|
          ProtocolCall.new(
            mid: call.message.to_s.split(/[.:]/).last,
            file: call.file,
            owner: call.owner,
            defn: call.function,
            line: call.line,
            span: call.span
          ).tap do |protocol_call|
            protocol_call.define_singleton_method(:conditional?) { call.conditional }
          end
        end
      end

      def protocol_call_variants(calls, function_def)
        return [[], []] if calls.empty? && protocol_conditional_body?(function_def.body)

        conditional_calls, always_calls = calls.partition do |call|
          call.respond_to?(:conditional?) && call.conditional?
        end
        return [calls] if conditional_calls.empty?

        conditional_calls.map { |call| (always_calls + [call]).sort_by(&:line) } +
          [always_calls.sort_by(&:line)]
      end

      def protocol_conditional_body?(node)
        return false unless node.is_a?(Hash)
        return true if %w[if unless case].include?(node["kind"].to_s)

        Array(node["children"]).any? { |child| protocol_conditional_body?(child) }
      end
    end

    class TreeSitterAdapter
      def protocol_method_effects(document)
        syntax_profile(document.language).protocol_method_effects(document)
      end

      def protocol_call_paths(document)
        syntax_profile(document.language).protocol_call_paths(document)
      end
    end
  end
end
