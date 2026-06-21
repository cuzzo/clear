# frozen_string_literal: true

module FactMine
  module Syntax
    # Language-specific normalized extraction behavior belongs in syntax/<lang>.rb.
    # The generic extractor calls this narrow surface instead of branching on
    # concrete languages.
    class NormalizedExtractionBehavior
      @registry = {}

      class << self
        def register(language, behavior_class)
          registry[language.to_sym] = behavior_class
        end

        def for(language)
          registry.fetch(language.to_sym, self).new
        end

        private

        def registry
          @registry ||= {}
        end
      end

      def yield_semantic_effect?(_node)
        true
      end

      def boolean_decision_members(members, _node)
        members
      end

      def state_write_span(_receiver, _field, _node, default_span:)
        default_span
      end

      def call_access_span(_node, computed_span:, full_span:)
        computed_span || full_span
      end

      def call_site_span(_node, _parts, full_span:, access_span:, current_function:)
        return access_span if access_span_call_site?(_parts&.fetch(:message, nil).to_s, current_function)

        full_span
      end

      def call_receiver(parts)
        parts.fetch(:receiver)
      end

      def project_call(_node, call)
        call
      end

      def suppress_call_site?(_node, _call)
        false
      end

      def local_assignment_writes(_field, _node, default_span:)
        []
      end

      def implicit_owner_fields?
        false
      end

      def embedded_member_reads(_node)
        []
      end

      def literal_state_reads(_node, normalized_text:, span:, source_text: nil)
        []
      end

      def initializer_field_reads(_node, owner:, owner_fields:, function_name:)
        []
      end

      def suppress_state_read_for_call?(_call, span_source:)
        false
      end

      def suppress_self_call_state_read?(_call)
        false
      end

      def state_read_span_key(_call)
        "access_span"
      end

      def suppress_branch_decision?(_node)
        false
      end

      def normalize_source_text(text)
        text
      end

      def source_message_text(message, _node)
        message
      end

      def self_member_receiver(message)
        "this.#{message}"
      end

      def owner_name_span(_name, _node, default_span:)
        nil
      end

      def owner_for_function(_name, node, current_owner:, file_owner:)
        return current_owner unless current_owner == file_owner

        text = node.text.to_s
        return text[/\Afunction\s+([A-Za-z_]\w*)[:]/, 1] || current_owner if text.start_with?("function ")

        current_owner
      end

      def receiver_aliases_for_function(_node)
        {}
      end

      def function_visibility(name, node, lines:)
        text = node.text.to_s.strip
        return "private" if text.match?(/\A(?:private|protected)\b/)
        return "public" if text.match?(/\Apublic\b/) || text.start_with?("pub ")
        return "private" if name.start_with?("#")

        "public"
      end

      def function_name_from_text(text)
        source = text.to_s.strip
        before_paren = source.split("(", 2).first.to_s.strip
        before_paren.split(/\s+/).last.to_s.sub(/\A[*&]+/, "")
      end

      def parameter_list_source(source)
        open_index = source.index("(")
        return "" unless open_index

        close_index = matching_paren_index(source, open_index)
        return "" unless close_index

        source[(open_index + 1)...close_index].to_s
      end

      def parameter_name_from_signature(param)
        text = param.to_s.strip
        return nil if text.empty?
        return text if text.match?(/\A&(?:mut\s+)?self\z/)

        text = text.sub(/\A(?:public|private|protected|readonly|mut|var|let|const|final)\s+/, "")
        text = text.sub(/=.*\z/, "").strip
        text = text.split(":", 2).first.strip if text.include?(":") && !text.include?("::")
        if text.include?("$")
          return text[/\$([A-Za-z_]\w*)/, 1]
        end

        text.scan(/[A-Za-z_]\w*[!?]?/).last&.delete_suffix("?")
      end

      def property_read_call?(node, parts)
        return false if node.type.to_s == "VCALL"
        return false unless parts.fetch(:arguments).empty?

        text = node.text.to_s
        return false if text.include?("(") && !(text.start_with?("(") && text.end_with?(")"))

        true
      end

      def case_pattern_values(pattern_values)
        pattern_values
      end

      def split_case_source(source)
        source.split(",").map(&:strip).reject(&:empty?).map { |pattern| case_pattern_display(pattern) }
      end

      def case_pattern_display(pattern)
        pattern
      end

      def case_predicate_text(text)
        text
      end

      def access_span_call_site?(_message, _current_function)
        false
      end

      def boolean_enclosing_span(_node, node_span:, decision_span:)
        decision_span || node_span
      end

      def method_state_ref?(_node, _parts)
        false
      end

      def literal_state_refs(_node, normalized_text:)
        []
      end

      def wrap_branch_predicate?(branch)
        branch.text.to_s.match?(/\b(?:if|switch|while|for)\s*\(/)
      end

      def explicit_self_state_ref(node, message)
        text = node.text.to_s.strip
        return "this.#{message}" if text.start_with?("this.")

        message
      end

      def stream_insertion_operator?(_node)
        false
      end

      private

      def matching_paren_index(source, open_index)
        depth = 0
        source.chars.each_with_index do |char, index|
          next if index < open_index

          depth += 1 if char == "("
          if char == ")"
            depth -= 1
            return index if depth.zero?
          end
        end
        nil
      end

      def span(node)
        [node.first_lineno, node.first_column, node.last_lineno, node.last_column]
      end

      def target_span_from_text(node, target)
        text = node.text.to_s
        index = text.index(target.to_s)
        return span(node) unless index && node.first_lineno == node.last_lineno

        [node.first_lineno, node.first_column + index, node.first_lineno, node.first_column + index + target.to_s.length]
      end

      def struct_keyword_span(node)
        text = node.text.to_s
        lines = text.lines
        start_offset = lines.index { |line| line.include?("struct") }
        return nil unless start_offset

        end_offset = lines.rindex { |line| line.include?("}") } || lines.length - 1
        start_line = node.first_lineno + start_offset
        end_line = node.first_lineno + end_offset
        start_column = (start_offset.zero? ? node.first_column : 0) + lines[start_offset].index("struct").to_i
        end_column = (end_offset.zero? ? node.first_column : 0) + lines[end_offset].index("}").to_i + 1
        [start_line, start_column, end_line, end_column]
      end

      def simple_identifier?(value)
        value.to_s.match?(/\A[_A-Za-z][_A-Za-z0-9!?]*\z/)
      end
    end
  end
end
