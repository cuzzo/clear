# frozen_string_literal: true

require_relative "static_evidence"

module NilKill
  class SourceIndex
    class << self
      attr_reader :global_struct_field_hash_shapes, :global_struct_field_array_shapes

      def reset_global_shape_indexes
        @noreturn_methods = Set.new
        @source_lines = {}
        @global_struct_field_hash_shapes = {}
        @global_struct_field_array_shapes = {}
      end

      def noreturn_methods
        @noreturn_methods ||= Set.new
      end

      def register_noreturn_method(name)
        return unless name && !name.to_s.empty?
        noreturn_methods << name.to_s
      end

      def source_lines(path)
        @source_lines ||= {}
        @source_lines[path] ||= File.readlines(path)
      end

      def merge_global_shapes(hash_shapes, array_shapes)
        @global_struct_field_hash_shapes ||= {}
        @global_struct_field_array_shapes ||= {}
        @global_struct_field_hash_shapes.merge!(hash_shapes) if hash_shapes
        @global_struct_field_array_shapes.merge!(array_shapes) if array_shapes
      end
    end

    attr_reader :path, :rel, :methods, :tlet_sites, :dead_nil_checks, :struct_declarations,
                :struct_field_static, :tuple_arrays, :hash_shapes, :collection_index_lookups,
                :hash_record_blockers, :hash_record_member_calls, :type_normalizers,
                :deterministic_guards, :dispatcher_inferences, :return_origins, :param_origins,
                :return_usage_sites, :return_direct_usage_sites, :hash_record_escape_sites,
                :hidden_enum_observations, :ivar_protocols, :ivar_param_origins,
                :rescue_handlers, :included_modules, :sorbet_state_fields

    def initialize(path, warm_only: false, usage_only: false)
      @path = path
      @rel = NilKill.rel(path)
      
      evidence = NilKill::StaticEvidence.build([@path], root: NilKill::ROOT)
      facts = evidence["facts"] || {}
      SourceIndex.merge_global_shapes(facts["struct_field_hash_shapes"], facts["struct_field_array_shapes"])
      
      if usage_only
        @tlet_sites = []
        @dead_nil_checks = []
        @struct_declarations = []
        @hash_shapes = []
        @collection_index_lookups = []
        @hash_record_blockers = []
        @deterministic_guards = []
        @param_origins = []
        @noreturn_methods = []
        @tuple_arrays = []
        @struct_field_static = []
        @included_modules = []
        @sorbet_state_fields = []
        @methods = []
        @type_normalizers = []
        @rescue_handlers = []
        @return_usage_sites = Array(facts["return_usage_sites"])
        @return_direct_usage_sites = Array(facts["return_direct_usage_sites"])
        @hash_record_escape_sites = []
        @hidden_enum_observations = []
        @dispatcher_inferences = []
        @hash_record_member_calls = []
        @ivar_protocols = {}
        @ivar_param_origins = {}
      else
        @tlet_sites = Array(facts["tlet_sites"])
        @dead_nil_checks = Array(facts["dead_nil_checks"])
        @struct_declarations = Array(facts["struct_declarations"])
        @hash_shapes = Array(facts["hash_shapes"])
        @collection_index_lookups = Array(facts["collection_index_lookups"])
        @hash_record_blockers = Array(facts["hash_record_blockers"])
        @deterministic_guards = Array(facts["deterministic_guards"])
        @param_origins = Array(facts["param_origins"])
        @noreturn_methods = Array(facts["noreturn_methods"])
        @noreturn_methods.each { |nm| SourceIndex.register_noreturn_method(nm["name"]) }
        
        @tuple_arrays = tuple_array_records(facts["array_shapes"])
        @struct_field_static = struct_field_static_records(facts["state_type_records"])
        
        @included_modules = []
        @sorbet_state_fields = []
        Array(facts["type_definitions"]).each do |d|
          if d["kind"] == "included_module"
            @included_modules << { "class" => d["owner"], "module" => d["name"] }
          elsif d["kind"] == "state_field" && d["type_system"] == "sorbet"
            @sorbet_state_fields << { "class" => d["owner"], "field" => d["name"]&.sub(/\A@/, ""), "type" => d["declared_type"] }
          end
        end
        
        @methods = convert_methods(evidence["methods"], facts["type_definitions"], @noreturn_methods)
        
        @type_normalizers = Array(facts["type_normalizers"])
        @rescue_handlers = Array(facts["rescue_handlers"])
        @return_usage_sites = Array(facts["return_usage_sites"])
        @return_direct_usage_sites = Array(facts["return_direct_usage_sites"])
        @hash_record_escape_sites = Array(facts["hash_record_escape_sites"])
        @hidden_enum_observations = Array(facts["hidden_enum_observations"])
        @dispatcher_inferences = Array(facts["dispatcher_inferences"])
        @hash_record_member_calls = Array(facts["hash_record_member_calls"])
        @ivar_protocols = {}
        @ivar_param_origins = {}
      end
      
      @static_return_types = {}
      Array(facts["type_definitions"]).each do |d|
        if d["kind"] == "method_signature" && d["type_system"] == "sorbet"
          @static_return_types[d["name"]] = d["return_type"]
        end
      end
      if usage_only
        @return_origins = []
      else
        @return_origins = Array(facts["return_origins"]).map do |origin|
          upgrade_call_untyped(origin)
        end
      end
    end

    def return_type(method_name, receiver_type = nil)
      if receiver_type
        clean_receiver = receiver_type.sub(/\AT\.nilable\((.+)\)\z/, '\1')
        match = @struct_field_static.find { |f| f["class"] == clean_receiver && f["field"] == method_name.to_s }
        return match["type"] if match
      end
      @static_return_types[method_name] || NilKill.rbi_return_type(method_name, receiver_type)
    end

def upgrade_call_untyped(origin)
  sources = Array(origin["sources"]).dup
  has_untyped = false
  blockers = Array(origin["blockers"]).dup

  sources.each_with_index do |source, idx|
    next unless source["kind"] == "call_untyped"
    callee = source["callee"]
    receiver_type = source["receiver_type"]
    ret = return_type(callee, receiver_type)
    if NilKill.useful_type?(ret)
      origin["sources"][idx] = source.merge("kind" => "typed_call", "type" => ret)
      blockers.reject! { |b| b.include?("untyped callee #{callee}") }
    else
      has_untyped = true
    end
  end

  origin["blockers"] = blockers

  if origin["sources"] != sources
    # Recompute candidate_type and confidence
    type_sources = origin["sources"].filter_map { |s| s["type"] }
    candidate = NilKill.static_sorbet_type(type_sources)
    candidate = "T.untyped" if candidate == "NilClass" && has_untyped
    useful = NilKill.useful_type?(candidate)
    confidence = useful && !NilKill.weak_type?(candidate) && blockers.empty? && !has_untyped ? "strong" : "review"
    confidence = "blocked" unless blockers.empty?
    
    origin["candidate_type"] = candidate
    origin["confidence"] = confidence
  end
  origin
end


    def summary
      {
        "method_count" => @methods.size,
        "unsigned_methods" => @methods.count { |m| !m["has_sig"] },
        "tlet_sites" => @tlet_sites.count { |s| s["tlet"] },
        "candidate_tlet_sites" => @tlet_sites.count { |s| !s["tlet"] },
        "dead_nil_checks" => @dead_nil_checks.size,
        "structs" => @struct_declarations.size,
        "tuple_arrays" => @tuple_arrays.size,
        "hash_shapes" => @hash_shapes.size,
        "collection_index_lookups" => @collection_index_lookups.size,
        "type_normalizers" => @type_normalizers.size,
        "deterministic_guards" => @deterministic_guards.size,
        "return_origins" => @return_origins.size,
        "param_origins" => @param_origins.size,
        "return_usage_sites" => @return_usage_sites.size,
        "hash_record_escape_sites" => @hash_record_escape_sites.size,
        "hidden_enum_observations" => @hidden_enum_observations.size,
      }
    end

    private

    def convert_methods(raw_methods, type_definitions, noreturn_methods)
      type_defs = Array(type_definitions).each_with_object({}) do |d, h|
        next unless d["kind"] == "method_signature"
        key = [d["language"].to_s, d["path"].to_s, d["owner"].to_s, d["name"].to_s, d["line"].to_i]
        h[key] = d
      end

      noreturn_set = Array(noreturn_methods).map { |n| n["name"].to_s }.to_set

      Array(raw_methods).map do |m|
        sig = m["signature"].to_s
        name = m["name"].to_s.sub(/\Aself\./, "")
        kind = if m["name"].to_s.start_with?("self.") || m["kind"].to_s == "class_method"
                 "class"
               elsif m["kind"].to_s == "function" || m["owner"].to_s.empty?
                 "function"
               else
                 "instance"
               end

        key = [m["language"].to_s, m["path"].to_s, m["owner"].to_s, name, m["line"].to_i]
        definition = type_defs[key]
        
        typed_params = Array(definition && definition["params"]).each_with_object({}) do |param, h2|
          h2[param["name"].to_s] = param["type"].to_s
        end

        untraceable = Array(m["untraceable_params"]).map(&:to_s).to_set
        params = Array(m["params"]).reject { |p| untraceable.include?(p.to_s) }.map do |pname|
          {
            "name" => pname.to_s,
            "nil_default" => false,
            "type" => typed_params[pname.to_s] || "T.untyped"
          }
        end

        non_nil_params = params.filter_map do |param|
          t = param["type"].to_s
          if !t.empty? && t != "T.untyped" && t != "NilClass" && !t.include?("T.nilable")
            param["name"].to_s
          end
        end

        is_noreturn = (definition && definition["return_type"].to_s == "T.noreturn") || noreturn_set.include?(name)

        {
          "path" => m["path"].to_s,
          "line" => m["line"].to_i,
          "end_line" => Array(m["span"])[2].to_i,
          "class" => m["owner"].to_s,
          "method" => name,
          "kind" => kind,
          "language" => m["language"].to_s,
          "has_sig" => !sig.empty?,
          "sig" => sig,
          "params" => params,
          "scope" => m["owner"].to_s.split("::").reject(&:empty?),
          "non_nil_params" => non_nil_params,
          "uses_yield" => false,
          "untraceable_params" => Array(m["untraceable_params"]).map(&:to_s),
          "protocols" => {},
          "noreturn_candidate" => is_noreturn,
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

    def core_rbi_return_type(method, receiver_type)
      case method
      when "to_s" then "String"
      when "to_i" then "Integer"
      when "nil?" then "T::Boolean"
      when "include?", "empty?", "key?", "has_key?" then "T::Boolean"
      when "!" then "T::Boolean"
      else nil
      end
    end
  end
end
