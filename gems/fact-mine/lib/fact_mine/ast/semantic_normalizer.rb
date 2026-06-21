# frozen_string_literal: true

require_relative "semantic_node"

module FactMine
  module Ast
    class SemanticNormalizer
      FACT_COLLECTIONS = {
        owner_defs: :owner,
        function_defs: :function,
        call_sites: :call,
        state_declarations: :state_declaration,
        state_param_origins: :state_param_origin,
        state_reads: :state_read,
        state_writes: :state_write,
        decision_sites: :decision,
        branch_arms: :branch_arm
      }.freeze

      attr_reader :document

      def initialize(document)
        @document = document
      end

      def normalize
        SemanticNode.new(
          type: :root,
          children: semantic_facts,
          span: root_span,
          text: document.source.to_s,
          language: document.language&.to_sym,
          metadata: {
            file: document.file,
            language: document.language&.to_sym
          }
        )
      end

      private

      def semantic_facts
        FACT_COLLECTIONS.flat_map do |collection, type|
          Array(document.public_send(collection)).map { |fact| semantic_fact(type, fact) }
        end.sort_by { |node| [node.span[0], node.span[1], node.type.to_s, node.text.to_s] }
      end

      def semantic_fact(type, fact)
        metadata = fact.to_h
        source_text = source_text(metadata[:span])
        metadata[:enclosing_span] = enclosing_decision_span(metadata) if type == :decision
        SemanticNode.new(
          type: type,
          children: [],
          span: metadata[:span] || line_span(metadata[:line]),
          text: source_text.empty? ? fact_text(type, metadata) : source_text,
          language: document.language&.to_sym,
          metadata: metadata.merge(language: document.language&.to_sym, source_text: source_text)
        )
      end

      def fact_text(type, metadata)
        case type
        when :function
          metadata[:signature] || metadata[:name].to_s
        when :call
          compact_text(metadata[:receiver], metadata[:message]).join(".")
        when :decision
          metadata[:predicate].to_s
        when :branch_arm
          metadata[:body].to_s
        when :state_read, :state_write, :state_declaration, :state_param_origin
          compact_text(metadata[:receiver], metadata[:field]).join(".")
        else
          metadata[:name].to_s
        end
      end

      def compact_text(*values)
        values.compact.map(&:to_s).reject(&:empty?)
      end

      def root_span
        last_line = document.lines.length
        last_column = document.lines.last.to_s.length
        [1, 0, [last_line, 1].max, last_column]
      end

      def line_span(line)
        line_number = line || 1
        [line_number, 0, line_number, 0]
      end

      def enclosing_decision_span(metadata)
        span = metadata[:span]
        return span unless span

        line = span[0]
        source_line = document.lines[line - 1].to_s
        keyword_column = source_line.index(/\b(if|unless|while|until)\b/)
        return span unless keyword_column && keyword_column <= span[1]

        end_line, end_column = matching_end_point(line, keyword_column)
        [line, keyword_column, end_line, end_column]
      end

      def matching_end_point(start_line, keyword_column)
        depth = 0
        document.lines[(start_line - 1)..].to_a.each_with_index do |line_text, offset|
          stripped = line_text.strip
          depth += 1 if stripped.match?(/\A(?:if|unless|while|until)\b/)
          if stripped == "end" && line_text.index(/\S/).to_i == keyword_column
            depth -= 1
            return [start_line + offset, keyword_column + stripped.length] if depth <= 0
          end
        end
        [start_line, document.lines[start_line - 1].to_s.length]
      end

      def source_text(span)
        return "" unless span

        first_line, first_column, last_line, last_column = span
        if first_line == last_line
          return document.lines[first_line - 1].to_s[first_column...last_column].to_s
        end

        parts = []
        parts << document.lines[first_line - 1].to_s[first_column..].to_s
        parts.concat(document.lines[first_line...(last_line - 1)] || [])
        parts << document.lines[last_line - 1].to_s[0...last_column].to_s
        parts.join
      end
    end
  end
end
