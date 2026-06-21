# frozen_string_literal: true

module Decomplex
  module Syntax
    ProtocolMethodEffect = Struct.new(:file, :owner, :name, :line, :reads, :writes,
                                      keyword_init: true)
    ProtocolCall = Struct.new(:mid, :file, :owner, :defn, :line, :span, keyword_init: true)
    ProtocolMethodPath = Struct.new(:file, :owner, :name, :line, :calls, keyword_init: true)
    ProtocolPath = Struct.new(:calls, :terminal, keyword_init: true)
    PROTOCOL_PATH_LIMIT = 64
    PROTOCOL_DECLARATIVE_MIDS = %w[
      abstract! alias_method any attr_accessor attr_reader attr_writer bind
      cast checked enum extend final include interface! let must must_because
      nilable override overridable params prepend private private_class_method
      protected public require require_relative requires_ancestor sealed! sig
      type_member type_template untyped unsafe void
    ].freeze
    PROTOCOL_TEST_DSL_MIDS = %w[
      a_kind_of after around before be be_a be_an be_empty be_falsey be_nil
      be_truthy change contain_exactly context describe eq eql equal expect
      have_attributes have_key have_received it match not_to raise_error
      receive subject to
    ].freeze
    PROTOCOL_IGNORED_MIDS = (PROTOCOL_DECLARATIVE_MIDS + PROTOCOL_TEST_DSL_MIDS).freeze
    PROTOCOL_OPTIONAL_DIAGNOSTIC_MIDS = %w[
      error! fixable! read_interpolated_string warn!
    ].freeze
    PROTOCOL_MUTATING_MIDS = %w[
      << []= add append clear collect! compact! concat declare delete delete_if
      each_key= fill filter! keep_if mark merge! move push reject! replace
      resolve shift stamp store unshift update write
    ].freeze
    PROTOCOL_NON_MUTATING_OPERATOR_MIDS = %w[! != !~].freeze
    PROTOCOL_MUTATING_SUFFIXES = %w[!].freeze

    RUBY_PROTOCOL_PATH_LIMIT = PROTOCOL_PATH_LIMIT
    RUBY_PROTOCOL_DECLARATIVE_MIDS = PROTOCOL_DECLARATIVE_MIDS
    RUBY_PROTOCOL_TEST_DSL_MIDS = PROTOCOL_TEST_DSL_MIDS
    RUBY_PROTOCOL_IGNORED_MIDS = PROTOCOL_IGNORED_MIDS
    RUBY_PROTOCOL_OPTIONAL_DIAGNOSTIC_MIDS = PROTOCOL_OPTIONAL_DIAGNOSTIC_MIDS
    RUBY_PROTOCOL_MUTATING_MIDS = PROTOCOL_MUTATING_MIDS
    RUBY_PROTOCOL_NON_MUTATING_OPERATOR_MIDS = PROTOCOL_NON_MUTATING_OPERATOR_MIDS
    RUBY_PROTOCOL_MUTATING_SUFFIXES = PROTOCOL_MUTATING_SUFFIXES

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
        document.function_defs.map do |function_def|
          reads = document.state_reads.select do |read|
            read.owner == function_def.owner && read.function == function_def.name
          end.map(&:field).uniq.sort
          writes = document.state_writes.select do |write|
            write.owner == function_def.owner && write.function == function_def.name
          end.map(&:field).uniq.sort

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
          calls = document.call_sites.select do |call|
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
            )
          end

          ProtocolMethodPath.new(
            file: function_def.file,
            owner: function_def.owner,
            name: function_def.name.to_s.split(/[.:]/).last,
            line: function_def.line,
            calls: calls
          )
        end
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
