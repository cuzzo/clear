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

      def type_systems
        []
      end

      def type_indexing?
        !type_systems.empty?
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
          "type_indexing" => type_indexing?,
          "type_systems" => type_systems.map(&:to_s).sort,
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

      def return_type_index(root:)
        nil
      end

      def field_type_index(root:)
        {}
      end

      def external_type_definitions(root:)
        []
      end

      def static_evidence(document:, facts:, rel_path:)
        state_declarations = Array(facts[:state_declarations]) +
          extra_state_declarations(document: document, facts: facts, rel_path: rel_path)
        state_param_origins = Array(facts[:state_param_origins]) +
          extra_state_param_origins(document: document, facts: facts, rel_path: rel_path)
        known_states = declared_states_by_owner(state_declarations)

        methods = []
        signatures = {}
        Array(facts[:function_defs]).each do |fn|
          record = method_record(document, rel_path, fn)
          methods << record
          signature = static_method_signature(fn)
          signatures[[fn.owner.to_s, fn.name.to_s].join("\u0000")] = signature unless signature.empty?
        end

        fields = []
        state_types = {}
        state_declarations.each do |state|
          field = declared_state_field(state.field)
          fields << field_record(document, rel_path, state, field)
          next if state.type.to_s.empty?

          state_types[state_key(state.owner, field)] = state.type.to_s
        end

        state_protocols = Hash.new { |hash, key| hash[key] = Set.new }
        state_param_origin_map = Hash.new { |hash, key| hash[key] = Set.new }

        state_param_origins.each do |origin|
          next unless owned_state_origin?(origin, known_states[origin.owner.to_s])
          next if self_receiver_names.include?(origin.param.to_s)

          field = canonical_state_field(origin.field, receiver: origin.receiver)
          state_param_origin_map[state_key(origin.owner, field)].add(origin.param.to_s)
        end

        Array(facts[:call_sites]).each do |call|
          state = receiver_state_field(call.receiver, known_states[call.owner.to_s])
          next unless state

          state_protocols[state_key(call.owner, state)].add(call.message.to_s)
        end

        {
          "methods" => methods,
          "fields" => fields,
          "state_types" => state_types,
          "state_protocols" => stringify_set_map(state_protocols),
          "state_param_origins" => stringify_set_map(state_param_origin_map),
          "signatures" => signatures,
          "type_definitions" => type_definitions(
            document: document,
            facts: facts,
            rel_path: rel_path,
            methods: methods,
            state_declarations: state_declarations
          ),
        }
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

      def extra_state_declarations(document:, facts:, rel_path:)
        []
      end

      def extra_state_param_origins(document:, facts:, rel_path:)
        []
      end

      def type_definitions(document:, facts:, rel_path:, methods:, state_declarations:)
        []
      end

      def static_method_signature(function_def)
        function_def.signature.to_s
      end

      def method_source(function_def)
        signature = static_method_signature(function_def)
        return {} if signature.empty?

        source = { "signature" => signature }
        systems = type_systems
        source["type_system"] = systems.first.to_s unless systems.empty?
        source
      end

      def method_record(document, rel_path, function_def)
        owner = function_def.owner.to_s
        name = function_def.name.to_s
        {
          "key" => [owner, name, function_def.kind.to_s],
          "owner" => owner,
          "name" => name,
          "kind" => function_def.kind.to_s,
          "path" => rel_path,
          "line" => function_def.line,
          "span" => function_def.span,
          "language" => document.language.to_s,
          "signature" => static_method_signature(function_def),
          "params" => Array(function_def.params).map(&:to_s),
          "source" => method_source(function_def),
        }
      end

      private

      def declared_states_by_owner(state_declarations)
        index = Hash.new { |hash, key| hash[key] = Set.new }
        state_declarations.each { |state| index[state.owner.to_s].add(declared_state_field(state.field)) }
        index
      end

      def state_key(owner, field)
        [owner.to_s, field.to_s].join("\u0000")
      end

      def field_record(document, rel_path, state, field)
        {
          "id" => [document.language, rel_path, state.owner, "field", field].map(&:to_s).join("\u0000"),
          "language" => document.language.to_s,
          "path" => rel_path,
          "owner" => state.owner.to_s,
          "name" => field.to_s,
          "line" => state.line,
          "span" => state.span,
          "declared_type" => state.type.to_s.empty? ? nil : state.type.to_s,
          "static_origin" => "state_declaration",
        }
      end

      def stringify_set_map(map)
        Hash[map.sort.map { |key, values| [key, values.to_a.map(&:to_s).sort.uniq] }]
      end

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
