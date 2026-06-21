# frozen_string_literal: true

module FactMine
  module Syntax
    class FactDocument
      attr_reader :file, :language, :source, :lines, :root, :normalized_root

      SECTION_KEYS = {
        branch_arms: %w[branch_arms],
        branch_decisions: %w[branch_decisions],
        call_sites: %w[calls call_sites],
        clone_candidates: %w[clone_candidates],
        comparison_sites: %w[comparisons comparison_sites comparison_uses],
        decision_sites: %w[decisions decision_sites],
        dispatch_sites: %w[dispatch_sites],
        function_defs: %w[functions function_defs],
        local_methods: %w[local_methods],
        owner_defs: %w[owners owner_defs],
        path_condition_sites: %w[path_conditions path_condition_sites],
        predicate_aliases: %w[predicate_aliases],
        predicate_defs: %w[predicate_bodies predicate_defs],
        protocol_call_paths: %w[protocol_call_paths],
        protocol_method_effects: %w[protocol_method_effects],
        redundant_nil_guard_findings: %w[redundant_nil_guards redundant_nil_guard_findings],
        semantic_effect_sites: %w[semantic_effects semantic_effect_sites],
        state_declarations: %w[state_declarations],
        state_param_origins: %w[state_param_origins],
        state_reads: %w[state_reads],
        state_writes: %w[state_writes]
      }.freeze

      FACT_ARRAY_METHODS = (SECTION_KEYS.keys - [:branch_decisions]).freeze

      def initialize(row, file: nil, language: nil, source: nil, lines: nil)
        @row = row
        @file = file || row.fetch("file")
        @language = (language || row.fetch("language", "ruby")).to_sym
        @source = source || row.fetch("source", "")
        @lines = lines || row.fetch("lines", @source.lines)
        @root = objectify(row.fetch("root", empty_fact_node("program")))
        @normalized_root = objectify(row.fetch("normalized_root", empty_normalized_root))
        @facts = SECTION_KEYS.to_h do |method_name, keys|
          [method_name, fact_array(first_section(keys), method_name)]
        end
        @immutable_struct_readers = object_hash(row.fetch("immutable_struct_readers", {}))
        @immutable_struct_reader_types = object_hash(row.fetch("immutable_struct_reader_types", {}))
        @type_aliases = object_hash(row.fetch("type_aliases", {}))
        @method_param_types = object_hash(row.fetch("method_param_types", {}))
        @local_complexity_scores = local_complexity_scores_from(row.fetch("local_complexity_scores", {}))
        @local_contract_assignments = object_hash(row.fetch("local_contract_assignments", {}))
      end

      FACT_ARRAY_METHODS.each do |name|
        define_method(name) { @facts.fetch(name) }
      end

      def branch_decisions(immutable_readers:, immutable_reader_types:, type_aliases:)
        immutable_readers = merge_hash_sets(@immutable_struct_readers, immutable_readers)
        immutable_reader_types = deep_merge_hash(@immutable_struct_reader_types, immutable_reader_types)
        type_aliases = @type_aliases.merge(string_key_hash(type_aliases))
        @facts.fetch(:branch_decisions).filter_map do |decision|
          refs = Array(decision.state_refs).reject do |ref|
            immutable_state_ref?(ref, decision.function, immutable_readers, immutable_reader_types, type_aliases)
          end
          next if refs.empty?

          row = decision.to_h.transform_keys(&:to_s)
          row["state_refs"] = refs
          objectify_fact(:branch_decisions, row)
        end
      end

      def immutable_struct_readers
        @immutable_struct_readers
      end

      def immutable_struct_reader_types
        @immutable_struct_reader_types
      end

      def type_aliases
        @type_aliases
      end

      def method_param_types
        @method_param_types
      end

      def local_complexity_scores
        @local_complexity_scores
      end

      def local_contract_assignments(method)
        embedded = method.public_send(:local_contract_assignments) if method.respond_to?(:local_contract_assignments)
        embedded = embedded.to_h if embedded.respond_to?(:to_h)
        return object_hash(embedded) if embedded && !embedded.empty?

        @local_contract_assignments.fetch(method.name.to_s, {})
      end

      private

      def first_section(keys)
        key = keys.find { |candidate| @row.key?(candidate) }
        key ? @row.fetch(key) : []
      end

      def fact_array(value, method_name)
        Array(value).map { |item| objectify_fact(method_name, item) }
                    .sort_by { |fact| fact_sort_key(fact) }
      end

      def objectify_fact(method_name, value)
        enriched = enrich_fact_row(method_name, value)
        return nil_guard_finding(enriched) if method_name == :redundant_nil_guard_findings

        objectify(enriched)
      end

      def enrich_fact_row(method_name, value)
        return value unless value.is_a?(Hash)

        row = value.key?("file") ? value.dup : value.merge("file" => @file)
        if method_name == :protocol_call_paths && row["calls"].is_a?(Array)
          row["calls"] = row["calls"].map do |call|
            call.is_a?(Hash) && !call.key?("file") ? call.merge("file" => @file) : call
          end
        end
        row
      end

      def nil_guard_finding(row)
        return objectify(row) unless defined?(NilGuardFinding)

        NilGuardFinding.new(
          file: row["file"],
          defn: row["defn"],
          line: row["line"],
          span: row["span"],
          local: row["local"],
          guard: row["guard"],
          proof: row["proof"]
        )
      end

      def fact_sort_key(fact)
        [
          fact_value(fact, :file).to_s,
          fact_value(fact, :line).to_i,
          Array(fact_value(fact, :span)),
          fact_value(fact, :function).to_s,
          fact_value(fact, :owner).to_s,
          fact_value(fact, :name).to_s,
          fact_value(fact, :receiver).to_s,
          fact_value(fact, :message).to_s,
          stable_fact_key(fact)
        ]
      end

      def fact_value(fact, name)
        return fact.public_send(name) if fact.respond_to?(name)

        nil
      end

      def stable_fact_key(fact)
        fact.respond_to?(:to_h) ? fact.to_h.to_s : fact.inspect
      end

      def empty_fact_node(kind)
        {
          "kind" => kind,
          "text" => "",
          "span" => [1, 0, 1, 0],
          "named" => true,
          "field_name" => nil,
          "children" => []
        }
      end

      def empty_normalized_root
        {
          "type" => "ROOT",
          "children" => [],
          "first_lineno" => 1,
          "first_column" => 0,
          "last_lineno" => 1,
          "last_column" => 0,
          "text" => ""
        }
      end

      def object_hash(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h { |key, child| [key.to_s, raw_hash_value(child)] }
      end

      def merge_hash_sets(left, right)
        out = {}
        left.each { |key, values| out[key.to_s] = Array(values).map(&:to_s) }
        string_key_hash(right).each do |key, values|
          out[key.to_s] = (Array(out[key.to_s]) + Array(values).map(&:to_s)).uniq
        end
        out
      end

      def deep_merge_hash(left, right)
        out = left.to_h { |key, value| [key.to_s, string_key_hash(value)] }
        string_key_hash(right).each do |key, value|
          out[key.to_s] = string_key_hash(out[key.to_s]).merge(string_key_hash(value))
        end
        out
      end

      def string_key_hash(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h { |key, child| [key.to_s, raw_hash_value(child)] }
      end

      def immutable_state_ref?(state_ref, function, immutable_readers, immutable_reader_types, type_aliases)
        parts = state_ref.to_s.split(".")
        return false if parts.size < 2

        param = parts.shift
        type = @method_param_types.fetch(function.to_s, {}).fetch(param, nil)
        return false unless type

        while parts.size > 1
          reader = parts.shift
          type = immutable_reader_result_type(type, reader, immutable_reader_types, type_aliases)
          return false unless type
        end

        immutable_reader?(type, parts.first, immutable_readers, type_aliases)
      end

      def immutable_reader?(type_name, field, immutable_readers, type_aliases)
        resolved = resolve_type_alias(type_name, type_aliases)
        short = resolved.split("::").last
        readers = immutable_readers[resolved] || immutable_readers[short] || []
        readers.map(&:to_s).include?(field.to_s.delete_suffix("?"))
      end

      def immutable_reader_result_type(type_name, field, immutable_reader_types, type_aliases)
        resolved = resolve_type_alias(type_name, type_aliases)
        short = resolved.split("::").last
        reader_types = immutable_reader_types[resolved] || immutable_reader_types[short] || {}
        reader_types[field.to_s.delete_suffix("?")]
      end

      def resolve_type_alias(type_name, type_aliases)
        seen = {}
        current = type_name.to_s
        loop do
          return current if seen[current]

          seen[current] = true
          target = type_aliases[current] || type_aliases[current.split("::").last]
          return current unless target

          current = target.to_s
        end
      end

      def raw_hash_value(value)
        case value
        when Hash
          object_hash(value)
        when Array
          value.map { |child| raw_hash_value(child) }
        else
          value
        end
      end

      def objectify(value)
        case value
        when Hash
          if value.key?("kind") && value.key?("span") && value.key?("children")
            return FactNode.new(value, method(:objectify_field))
          end

          OpenStruct.new(value.to_h { |key, child| [key.to_s, objectify_field(key.to_s, child)] })
        when Array
          value.map { |child| objectify(child) }
        else
          value
        end
      end

      def objectify_field(key, value)
        if enum_symbol_field?(key, value)
          return value.to_sym
        end
        if key == "local_contract_assignments"
          return object_hash(value)
        end
        if key == "arm_members"
          return object_hash(value)
        end

        objectify(value)
      end

      def enum_symbol_field?(key, value)
        return false unless value.is_a?(String)

        case key
        when "control"
          %w[conditional iterates always].include?(value)
        when "visibility"
          %w[public protected private].include?(value)
        when "kind"
          %w[
            case_dispatch conjunction if case protocol_pressure
            hidden_mutation hidden_io dynamic_dispatch context_dependency
            callback_inversion metaprogramming
            comment blank
          ].include?(value)
        else
          false
        end
      end

      def local_complexity_scores_from(value)
        if value.is_a?(Array)
          return value.to_h do |row|
            id = row.fetch("id").to_s
            score = {
              score: row.fetch("score"),
              signals: symbolized_value(row.fetch("signals", {}))
            }
            [id, score]
          end
        end

        value.to_h { |id, score| [id.to_s, symbolized_value(score)] }
      end

      def symbolized_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_sym, symbolized_value(child)] }
        when Array
          value.map { |child| symbolized_value(child) }
        else
          value
        end
      end
    end

    class FactPoint
      attr_reader :row, :column

      def initialize(row, column)
        @row = row
        @column = column
      end
    end

    class FactNode
      attr_reader :kind, :text, :span, :field_name, :children, :start_point, :end_point
      attr_reader :start_byte, :end_byte
      attr_accessor :parent, :prev_sibling, :next_sibling

      def initialize(row, objectifier)
        @kind = row.fetch("kind")
        @text = row.fetch("text", "")
        @span = row.fetch("span")
        @field_name = row["field_name"]
        @named = row.fetch("named", true)
        @start_byte = row.fetch("start_byte", byte_offset(@span[0], @span[1]))
        @end_byte = row.fetch("end_byte", byte_offset(@span[2], @span[3]))
        @children = Array(row.fetch("children", [])).map { |child| objectifier.call("node", child) }
        @children.each { |child| child.parent = self if child.respond_to?(:parent=) }
        @children.each_cons(2) do |left, right|
          left.next_sibling = right if left.respond_to?(:next_sibling=)
          right.prev_sibling = left if right.respond_to?(:prev_sibling=)
        end
        @start_point = FactPoint.new(@span[0].to_i - 1, @span[1].to_i)
        @end_point = FactPoint.new(@span[2].to_i - 1, @span[3].to_i)
      end

      def named?
        @named
      end

      def child_count
        @children.length
      end

      def named_children
        @children.select { |child| child.respond_to?(:named?) && child.named? }
      end

      def named_child_count
        named_children.length
      end

      def child_by_field_name(name)
        @children.find { |child| child.respond_to?(:field_name) && child.field_name.to_s == name.to_s }
      end

      private

      def byte_offset(line, column)
        ((line.to_i - 1) * 1_000_000) + column.to_i
      end
    end
  end
end
