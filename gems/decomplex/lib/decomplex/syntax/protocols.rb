# frozen_string_literal: true

module Decomplex
  module Syntax
    ProtocolMethodEffect = Struct.new(:file, :owner, :name, :line, :reads, :writes,
                                      keyword_init: true)
    ProtocolCall = Struct.new(:mid, :file, :owner, :defn, :line, :span, keyword_init: true)
    ProtocolMethodPath = Struct.new(:file, :owner, :name, :line, :calls, keyword_init: true)
    ProtocolPath = Struct.new(:calls, :terminal, keyword_init: true)

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

require_relative "ruby_protocols"
