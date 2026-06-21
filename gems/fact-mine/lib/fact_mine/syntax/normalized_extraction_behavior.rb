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

      def preserve_constant_receiver_call?(_call)
        false
      end

      def emit_index_call_site?(_node, _call)
        false
      end

      def emit_index_assignment_mutation?(_node, _field)
        false
      end

      def emit_attribute_assignment_mutation?(_node, _field)
        false
      end

      def local_assignment_writes(_field, _node, default_span:)
        []
      end

      def implicit_owner_fields?
        false
      end

      def field_name_from_declaration(_node)
        nil
      end

      def state_declaration_from_node(_node, owner:)
        nil
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

      def ternary_children_conditional?(_node)
        true
      end

      def normalize_source_text(text)
        text
      end

      def source_message_text(message, _node)
        message
      end

      def self_member_receiver(message)
        message
      end

      def owner_name_span(_name, _node, default_span:)
        nil
      end

      def owner_name_from_text(_node)
        nil
      end

      def owner_kind(_node, default_kind:)
        default_kind
      end

      def declarative_owner(_node, current_owner:)
        nil
      end

      def owner_for_function(_name, _node, current_owner:, file_owner:)
        current_owner
      end

      def body_owner_for_function(_name, _node, current_owner:, file_owner:)
        nil
      end

      def receiver_aliases_for_function(_node)
        {}
      end

      def function_visibility(_name, _node, lines:)
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

        text = text.sub(/=.*\z/, "").strip
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

      def wrap_branch_predicate?(_branch)
        false
      end

      def explicit_self_state_ref(_node, message)
        message
      end

      def stream_insertion_operator?(_node)
        false
      end

      def mutating_receiver_message?(_message)
        false
      end

      def branch_state_ref(_node, parts, default_ref:)
        receiver = parts.fetch(:receiver).to_s
        return nil if receiver.match?(/\A[:A-Z]/) && !receiver.include?("(")

        default_ref
      end

      def protocol_read_label_from_state(read)
        read.field.to_s
      end

      def protocol_read_label_from_call(call)
        return nil unless call.receiver.to_s == "self"

        call.message.to_s
      end

      def protocol_write_label(write)
        write.field.to_s
      end

      def normalize_comparison_source(source)
        normalize_source_text(source.to_s.strip)
      end

      def structural_semantic_effects(_node, function_name:)
        []
      end

      def visibility_events_from_calls(_calls)
        []
      end

      def nil_guard_fact(_message, _subject)
        nil
      end

      def terminating_call_message?(_message)
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

      def keyword_block_span(node, keyword)
        text = node.text.to_s
        lines = text.lines
        keyword = keyword.to_s
        start_offset = lines.index { |line| line.include?(keyword) }
        return nil unless start_offset

        end_offset = lines.rindex { |line| line.include?("}") } || lines.length - 1
        start_line = node.first_lineno + start_offset
        end_line = node.first_lineno + end_offset
        start_column = (start_offset.zero? ? node.first_column : 0) + lines[start_offset].index(keyword).to_i
        end_column = (end_offset.zero? ? node.first_column : 0) + lines[end_offset].index("}").to_i + 1
        [start_line, start_column, end_line, end_column]
      end

      def simple_identifier?(value)
        value.to_s.match?(/\A[_A-Za-z][_A-Za-z0-9!?]*\z/)
      end
    end
  end
end
