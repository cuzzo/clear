# frozen_string_literal: true

require "json"
require_relative "type_profile"

module Espalier
  # Normalizes Nil-Kill Espalier evidence across legacy Ruby ivar facts and the
  # Tree-sitter static schema v2.
  class NilKillEvidence
    attr_reader :method_signatures, :state_types, :state_param_origins, :state_protocols, :loop_counts

    def self.load(path)
      return empty unless path && File.exist?(path)

      new(FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(path))), path)
    rescue StandardError
      empty
    end

    def self.empty
      new({})
    end

    def initialize(data, path = nil)
      @data = data || {}
      @method_signatures = {}
      @state_types = nested_state_map(facts["state_types"] || {})
      @state_param_origins = nested_state_map(facts["state_param_origins"] || facts["ivar_param_origins"] || {})
      @state_protocols = nested_state_map(facts["state_protocols"] || facts["ivar_protocols"] || {})
      @loop_counts = Hash.new { |h, k| h[k] = Hash.new(0) }
      load_methods!
      load_legacy_runtime_types!
      load_loops_if_present!(path) if path
    end

    def apply!(modules)
      Array(modules).each do |mod|
        mod_owner = mod[:name].to_s
        mod[:ivar_types] ||= {}
        mod[:ivar_properties] ||= {}

        state_types.fetch(mod_owner, {}).each do |state, type|
          mod[:ivar_types][state] = type
        end

        Array(mod[:states]).each do |state|
          props = []
          if (origins = state_param_origins.dig(mod_owner, state.to_s))
            props << "loaded from param: #{origins.join(', ')}"
          end
          if (protocols = state_protocols.dig(mod_owner, state.to_s))
            props << "protocol interfaces: #{protocols.join(', ')}"
          end
          mod[:ivar_properties][state.to_s] = props unless props.empty?
        end
      end
      modules
    end

    private

    attr_reader :data

    def facts
      data["facts"] || {}
    end

    def load_methods!
      Array(data["methods"]).each do |entry|
        signature = entry.dig("source", "sig").to_s
        signature = entry["signature"].to_s if signature.empty?
        next if signature.empty?

        if entry["owner"] && entry["name"]
          @method_signatures["#{entry["owner"]}##{entry["name"]}"] = signature
          next
        end

        key_parts = entry["key"]
        next unless key_parts && key_parts.size >= 3

        class_name = key_parts[0]
        method_name = key_parts[1]
        kind = key_parts[2]
        full_method_name = kind == "class" ? "self.#{method_name}" : method_name
        @method_signatures["#{class_name}##{full_method_name}"] = signature
      end
    end

    def load_legacy_runtime_types!
      Array(facts["ivar_runtime"]).each do |entry|
        runtime_owner = entry["class"]
        state = entry["name"]
        classes = Array(entry["classes"])
        next unless runtime_owner && state && !classes.empty?

        @state_types[runtime_owner] ||= {}
        @state_types[runtime_owner][state] = sorbet_type(classes)
      end
    end

    def nested_state_map(map)
      Hash(map).each_with_object({}) do |(key, value), out|
        map_owner, state = key.to_s.split("\u0000", 2)
        next if map_owner.to_s.empty? || state.to_s.empty?

        out[map_owner] ||= {}
        out[map_owner][state] = value.is_a?(Array) ? value.map(&:to_s).sort.uniq : value.to_s
      end
    end

    def sorbet_type(classes)
      if classes.size == 1
        classes.first
      elsif classes.include?("NilClass")
        non_nil = classes - ["NilClass"]
        non_nil.size == 1 ? "T.nilable(#{non_nil.first})" : "T.nilable(T.any(#{non_nil.join(', ')}))"
      else
        "T.any(#{classes.join(', ')})"
      end
    end

    def load_loops_if_present!(evidence_path)
      dir = File.dirname(evidence_path)
      runtime_dir = File.join(dir, "runtime")
      return unless File.directory?(runtime_dir)

      Dir.glob(File.join(runtime_dir, "loops-*.jsonl")).each do |loop_file|
        File.readlines(loop_file).each do |line|
          data = JSON.parse(line) rescue next
          path = data["path"]
          line_num = data["line"]&.to_i
          if path && line_num
            @loop_counts[path][line_num] += Integer(data.fetch("count", 1))
          end
        end
      end
    end
  end
end
