# typed: false
# frozen_string_literal: true

module NilKill
  module Inference
    class StaticFactProvider
      def initialize(language = nil, copy_bundle: true, index_methods: true)
        @language = language&.to_s
        @copy_bundle = copy_bundle
        @index_methods = index_methods
      end

      def language
        @language
      end

      def index(store:, static:, root:)
        @root = root
        @static = static
        @store = store
        if @copy_bundle
          copy_summary
          copy_files
          copy_static_facts
        end
        index_methods if @index_methods
      end

      private

      attr_reader :root, :static, :store

      def copy_summary
        store.facts["static_evidence_summary"] = Hash(static["summary"])
      end

      def copy_files
        grouped_methods = Array(static["methods"]).group_by { |method| method["path"].to_s }
        grouped_fields = Array(static["fields"]).group_by { |field| field["path"].to_s }
        Array(static["files"]).each do |file|
          path = file["path"].to_s
          next if path.empty? || annotation_path?(path)

          store.facts["files"][path] = {
            "language" => file["language"],
            "methods" => Array(grouped_methods[path]).size,
            "fields" => Array(grouped_fields[path]).size,
            "digest" => file["digest"],
            "parser" => file["parser"],
          }
        end
      end

      def copy_static_facts
        facts = Hash(static["facts"])
        concat_fact("tlet_sites", facts["tlet_sites"])
        concat_fact("dead_nil_checks", facts["dead_nil_checks"])
        concat_fact("deterministic_guards", facts["deterministic_guards"])
        concat_fact("struct_declarations", facts["struct_declarations"])
        concat_fact("hash_shapes", facts["hash_shapes"])
        concat_fact("tuple_arrays", tuple_array_records(facts["array_shapes"]))
        concat_fact("struct_field_static", struct_field_static_records(facts["state_type_records"]))
        concat_fact("type_definitions", facts["type_definitions"])
        concat_fact("return_origins", facts["return_origins"])
        concat_fact("param_origins", facts["param_origins"])
        concat_fact("rbi_field_types", facts["rbi_field_types"])
        concat_fact("noreturn_methods", facts["noreturn_methods"])
        concat_fact("type_normalizers", facts["type_normalizers"])
        concat_fact("rescue_handlers", facts["rescue_handlers"])
        concat_fact("return_usage_sites", facts["return_usage_sites"])
        concat_fact("return_direct_usage_sites", facts["return_direct_usage_sites"])
        concat_fact("hash_record_escape_sites", facts["hash_record_escape_sites"])
        concat_fact("hidden_enum_observations", facts["hidden_enum_observations"])
        concat_fact("dispatcher_inferences", facts["dispatcher_inferences"])
        concat_fact("hash_record_member_calls", facts["hash_record_member_calls"])
        concat_fact("flow_local_types", facts["flow_local_types"])
        concat_fact("type_dependencies", facts["type_dependencies"])
        merge_fact_map("ivar_protocols", facts["ivar_protocols"])
        merge_fact_map("ivar_param_origins", facts["ivar_param_origins"])
      end

      def concat_fact(name, values)
        store.facts[name] ||= []
        store.facts[name].concat(Array(values))
      end

      def merge_fact_map(name, values)
        store.facts[name] ||= {}
        Hash(values).each do |key, entries|
          store.facts[name][key] ||= []
          store.facts[name][key] = (store.facts[name][key] + Array(entries)).map(&:to_s).uniq.sort
        end
      end

      def index_methods
        method_type_definitions = method_type_definition_index
        Array(static["methods"]).each do |method|
          next unless accepts_method?(method)
          next if annotation_path?(method["path"])

          source = legacy_method_record(method, find_definition_for(method, method_type_definitions))
          target = source["has_sig"] ? "existing_sigs" : "unsigned_methods"
          store.facts[target] << source
          rec = store.method_record([source["class"], source["method"], source["kind"], File.expand_path(source["path"], root), source["line"]])
          rec["source"] = source
          rec["has_sig"] = source["has_sig"]
        end
      end

      def accepts_method?(method)
        return true unless language

        method["language"].to_s == language.to_s
      end

      def method_type_definition_index
        Array(static.dig("facts", "type_definitions")).each_with_object({}) do |definition, index|
          next unless definition["kind"].to_s == "method_signature"

          key = [definition["language"].to_s, definition["path"].to_s, definition["owner"].to_s, definition["name"].to_s, definition["line"].to_i]
          index[key] = definition
          normalized = normalized_method_name(definition["name"])
          index[[definition["language"].to_s, definition["path"].to_s, definition["owner"].to_s, normalized, definition["line"].to_i]] = definition
        end
      end

      def method_definition_key(method)
        [
          method["language"].to_s,
          method["path"].to_s,
          method["owner"].to_s,
          normalized_method_name(method["name"]),
          method["line"].to_i,
        ]
      end

      def find_definition_for(method, method_type_definitions)
        key = method_definition_key(method)
        candidates = [
          key,
          [key[0], key[1], key[2], key[3], 0],
          [key[0], key[1], "", key[3], 0],
          [key[0], key[1], "", key[3], key[4]],
        ].uniq.map { |k| method_type_definitions[k] }.compact

        return nil if candidates.empty?

        merged = {}
        candidates.each do |cand|
          merged.merge!(cand) do |field_name, old_val, new_val|
            if field_name == "params"
              (Array(old_val) + Array(new_val)).uniq { |p| p["name"] }
            else
              new_val || old_val
            end
          end
        end
        merged
      end

      def legacy_method_record(method, definition)
        params = legacy_params(method, definition)
        signature = method["signature"].to_s
        kind, name = legacy_method_kind_and_name(method)
        {
          "path" => method["path"].to_s,
          "line" => method["line"].to_i,
          "end_line" => Array(method["span"])[2].to_i,
          "class" => method["owner"].to_s,
          "method" => name,
          "kind" => kind,
          "language" => method["language"].to_s,
          "has_sig" => !signature.empty?,
          "sig" => signature,
          "params" => params,
          "scope" => method["owner"].to_s.split("::").reject(&:empty?),
          "non_nil_params" => params.filter_map { |param| non_nil_type?(param["type"]) ? param["name"].to_s : nil },
          "uses_yield" => false,
          "untraceable_params" => Array(method["untraceable_params"]).map(&:to_s),
          "protocols" => {},
          "noreturn_candidate" => noreturn_method?(method, definition),
        }
      end

      def legacy_params(method, definition)
        typed = Array(definition && definition["params"]).each_with_object({}) do |param, index|
          index[param["name"].to_s] = param["type"].to_s
        end
        untraceable = Array(method["untraceable_params"]).map(&:to_s).to_set
        Array(method["params"]).reject { |name| untraceable.include?(name.to_s) }.map do |name|
          {
            "name" => name.to_s,
            "nil_default" => false,
            "type" => typed[name.to_s],
          }
        end
      end

      def legacy_method_kind_and_name(method)
        name = normalized_method_name(method["name"])
        kind =
          if method["name"].to_s.start_with?("self.") || method["kind"].to_s == "class_method"
            "class"
          elsif method["kind"].to_s == "function" || method["owner"].to_s.empty?
            "function"
          else
            "instance"
          end
        [kind, name]
      end

      def normalized_method_name(name)
        name.to_s.sub(/\Aself\./, "")
      end

      def non_nil_type?(type)
        raw = type.to_s
        !raw.empty? && raw != "T.untyped" && raw != "NilClass" && !raw.include?("T.nilable")
      end

      def noreturn_method?(method, definition)
        return true if definition && definition["return_type"].to_s == "T.noreturn"

        noreturn_names.include?(normalized_method_name(method["name"]))
      end

      def noreturn_names
        @noreturn_names ||= Array(static.dig("facts", "noreturn_methods")).map { |entry| entry["name"].to_s }.to_set
      end

      def struct_field_static_records(records)
        Array(records).filter_map do |record|
          type = record["declared_type"].to_s
          next if type.empty?

          {
            "path" => record["path"].to_s,
            "line" => record["line"].to_i,
            "class" => record["owner"].to_s,
            "field" => record["field"].to_s.sub(/\A@/, ""),
            "type" => type,
            "source" => "static_evidence",
          }
        end
      end

      def tuple_array_records(records)
        Array(records).filter_map do |record|
          types = Array(record["tuple_types"])
          next if types.empty?

          {
            "path" => record["path"].to_s,
            "line" => record["line"].to_i,
            "types" => types,
            "size" => record["size"].to_i,
            "code" => record["code"].to_s,
            "source" => "static_evidence",
          }
        end
      end

      def annotation_path?(path)
        path.to_s.end_with?(".rbi")
      end
    end
  end
end
