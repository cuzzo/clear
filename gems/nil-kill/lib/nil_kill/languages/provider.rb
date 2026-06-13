# typed: false
# frozen_string_literal: true

require "set"

module NilKill
  module Languages
    class UnsupportedRuntimeTracer < StandardError; end

    class Provider
      def language
        raise NotImplementedError
      end

      def aliases
        []
      end

      def display_name
        language.to_s
      end

      def extensions
        []
      end

      def static_analysis?
        true
      end

      def static_parser
        "tree_sitter"
      end

      def runtime_tracing?
        false
      end

      def runtime_trace_events
        []
      end

      def runtime_capabilities
        {
          "method_calls" => false,
          "params" => false,
          "returns" => false,
          "exceptions" => false,
          "fields" => false,
          "collections" => false,
          "hash_shapes" => false,
          "call_edges" => false,
          "line_coverage" => false,
        }
      end

      def autofix?
        false
      end

      def notes
        []
      end

      def capability
        {
          "language" => language.to_s,
          "display_name" => display_name,
          "aliases" => aliases.map(&:to_s),
          "extensions" => extensions.map(&:to_s).sort,
          "static_analysis" => static_analysis?,
          "static_parser" => static_parser,
          "runtime_tracing" => runtime_tracing?,
          "runtime_trace_events" => runtime_trace_events.map(&:to_s).sort,
          "runtime_capabilities" => runtime_capabilities,
          "autofix" => autofix?,
          "notes" => notes.map(&:to_s),
        }
      end

      def collect_runtime(argv:, root:, output:, targets:, append: false)
        raise UnsupportedRuntimeTracer, "#{display_name} does not have a Nil-Kill runtime tracer provider"
      end

      def canonical_state_field(field, receiver: nil)
        field.to_s
      end

      def declared_state_field(field)
        canonical_state_field(field)
      end

      def owned_state_origin?(origin, known_states)
        known = normalize_known_states(known_states)
        field = canonical_state_field(origin.field, receiver: origin.receiver)
        return true if known.include?(field)

        receiver = normalize_receiver(origin.receiver)
        return false if receiver == ".literal"

        self_receiver?(receiver) || owned_receiver?(receiver)
      end

      def receiver_state_field(receiver, known_states)
        known = normalize_known_states(known_states)
        text = normalize_receiver(receiver).sub(/\A\*/, "")
        return nil if text.empty? || self_receiver?(text)

        if instance_field_receiver?(text)
          return canonical_state_field(text.split(".").first, receiver: text)
        end

        self_receiver_names.each do |name|
          prefix = "#{name}."
          next unless text.start_with?(prefix)

          return canonical_state_field(text.split(".")[1], receiver: text)
        end

        first = canonical_state_field(text.split(".").first, receiver: text)
        known.include?(first) ? first : nil
      end

      private

      def normalize_known_states(states)
        Set.new(Array(states).map { |field| canonical_state_field(field) })
      end

      def normalize_receiver(receiver)
        receiver.to_s
      end

      def self_receiver_names
        %w[self this]
      end

      def self_receiver?(receiver)
        self_receiver_names.include?(receiver.to_s)
      end

      def owned_receiver?(receiver)
        receiver = receiver.to_s
        instance_field_receiver?(receiver) || self_receiver_names.any? { |name| receiver.start_with?("#{name}.") }
      end

      def instance_field_receiver?(receiver)
        receiver.to_s.match?(/\A@[A-Za-z_]\w*(?:\.|\z)/)
      end
    end

    class GenericTreeSitterProvider < Provider
      def initialize(language)
        @language = language.to_s
      end

      def language
        @language
      end
    end
  end
end
