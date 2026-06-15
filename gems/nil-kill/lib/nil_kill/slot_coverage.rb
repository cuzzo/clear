# typed: false
# frozen_string_literal: true

require "set"
require_relative "static_evidence"

module NilKill
  class SlotCoverage
    STRUCTURAL_CATEGORIES = %w[params returns ivars struct_fields].freeze
    COLLECTION_CATEGORIES = %w[arrays hashes].freeze
    COUNT_KEYS = %w[total strong weak untyped nilable weak_collection].freeze

    class << self
      def files_for(inputs)
        StaticEvidence.build(inputs.empty? ? ["src"] : inputs, root: ROOT)
          .fetch("files", [])
          .map { |file| File.expand_path(file.fetch("path"), ROOT) }
      end

      def scan(inputs = ["src"])
        new(inputs.empty? ? ["src"] : inputs).summaries
      end

      def totals(summaries)
        total = empty_summary("TOTAL")
        summaries.each do |summary|
          all_categories.each do |category|
            merge_counts!(total.fetch(category), summary.fetch(category))
          end
        end
        finalize_summary!(total)
      end

      def all_categories
        STRUCTURAL_CATEGORIES + COLLECTION_CATEGORIES
      end

      def empty_summary(path)
        all_categories.each_with_object({ "path" => path }) do |category, summary|
          summary[category] = empty_counts
        end
      end

      def empty_counts
        COUNT_KEYS.to_h { |key| [key, 0] }
      end

      def merge_counts!(target, source)
        COUNT_KEYS.each { |key| target[key] += source[key].to_i }
        target
      end

      def finalize_summary!(summary)
        structural = empty_counts
        STRUCTURAL_CATEGORIES.each { |category| merge_counts!(structural, summary.fetch(category)) }
        summary["structural"] = structural
        total = structural["total"]
        summary["typed_percent"] = total.positive? ? (100.0 * structural["strong"] / total).round(1) : 100.0
        summary
      end
    end

    def initialize(targets)
      @targets = targets
    end

    def summaries
      evidence = StaticEvidence.build(@targets, root: ROOT)
      summaries = evidence.fetch("files", []).to_h do |file|
        [file.fetch("path"), self.class.empty_summary(file.fetch("path"))]
      end

      method_signatures = method_signature_index(evidence)
      evidence.fetch("methods", []).each do |method|
        summary = summaries[method.fetch("path")] ||= self.class.empty_summary(method.fetch("path"))
        add_method_slots!(summary, method, method_signatures[method_key(method)])
      end

      field_types = field_type_index(evidence)
      seen_fields = Set.new
      evidence.fetch("fields", []).each do |field|
        summary = summaries[field.fetch("path")] ||= self.class.empty_summary(field.fetch("path"))
        type = field["declared_type"] || field_types[field_key(field)]
        add_slot!(summary, field_category(field), type)
        seen_fields.add(field_key(field))
      end
      type_definitions(evidence).each do |definition|
        next unless definition["kind"] == "state_field"
        next if seen_fields.include?(field_key(definition))

        summary = summaries[definition.fetch("path")] ||= self.class.empty_summary(definition.fetch("path"))
        add_slot!(summary, field_category(definition), definition["declared_type"])
      end

      summaries.values.sort_by { |summary| summary.fetch("path") }.map do |summary|
        self.class.finalize_summary!(summary)
      end
    end

    private

    def method_signature_index(evidence)
      type_definitions(evidence).each_with_object({}) do |definition, index|
        next unless definition["kind"] == "method_signature"

        index[method_key(definition)] = definition
      end
    end

    def field_type_index(evidence)
      type_definitions(evidence).each_with_object({}) do |definition, index|
        next unless definition["kind"] == "state_field"

        index[field_key(definition)] = definition["declared_type"]
      end
    end

    def type_definitions(evidence)
      Array(evidence.dig("facts", "type_definitions"))
    end

    def add_method_slots!(summary, method, signature)
      param_types = Array(signature && signature["params"]).to_h do |param|
        [param["name"].to_s, param["type"]]
      end
      Array(method["params"]).each do |param|
        name = param.is_a?(Hash) ? param["name"] : param.to_s
        add_slot!(summary, "params", param_types[name])
      end
      add_slot!(summary, "returns", return_type_for(signature))
    end

    def return_type_for(signature)
      return nil unless signature

      type = signature["return_type"]
      if type.to_s.empty? && signature["signature"].to_s.match?(/(?:\.|\b)void\b/)
        return "NilClass"
      end

      type
    end

    def method_key(record)
      [
        record["path"].to_s,
        record["owner"].to_s,
        record["name"].to_s
      ]
    end

    def field_key(record)
      [
        record["path"].to_s,
        record["owner"].to_s,
        record["name"].to_s
      ]
    end

    def field_category(field)
      field["name"].to_s.start_with?("@") ? "ivars" : "struct_fields"
    end

    def add_slot!(summary, category, type)
      add_count!(summary.fetch(category), type)
      case collection_kind(type)
      when "array" then add_count!(summary.fetch("arrays"), type)
      when "hash" then add_count!(summary.fetch("hashes"), type)
      end
    end

    def add_count!(counts, type)
      normalized = normalize_slot_type(type)
      counts["total"] += 1
      counts["nilable"] += 1 if nilable_slot_type?(normalized)
      case slot_strength(normalized)
      when "strong" then counts["strong"] += 1
      when "weak" then counts["weak"] += 1
      else counts["untyped"] += 1
      end
      counts["weak_collection"] += 1 if weak_collection_slot_type?(normalized)
    end

    def slot_strength(type)
      return "untyped" if type.to_s.strip.empty?

      inner = strip_nilable_type(normalize_slot_type(type))
      return "untyped" if inner == "T.untyped"
      return "weak" if weak_slot_type?(inner)

      "strong"
    end

    def nilable_slot_type?(type)
      source = type.to_s
      source.include?("T.nilable(") ||
        source == "NilClass" ||
        source.match?(/\bOptional\s*\[/) ||
        source.match?(/\bNone\b|\bnull\b/) ||
        source.match?(/\?\s*:/)
    end

    def weak_collection_slot_type?(type)
      inner = strip_nilable_type(normalize_slot_type(type))
      collection_kind(inner) && weak_slot_type?(inner)
    end

    def collection_kind(type)
      inner = strip_nilable_type(normalize_slot_type(type))
      return "array" if inner == "Array" || inner.start_with?("Array[", "T::Array[", "list[", "List[", "Sequence[")
      return "array" if inner.match?(/\A(?:Array|ReadonlyArray)<.+>\z/) || inner.end_with?("[]")
      return "hash" if inner == "Hash" || inner.start_with?("Hash[", "T::Hash[", "dict[", "Dict[", "Mapping[")
      return "hash" if inner.match?(/\A(?:Record|Map)<.+>\z/)

      nil
    end

    def normalize_slot_type(type)
      text = type.to_s.strip
      case text
      when "" then ""
      when "Array" then "T::Array[T.untyped]"
      when "Hash" then "T::Hash[T.untyped, T.untyped]"
      when "Set" then "T::Set[T.untyped]"
      when "Any", "any", "typing.Any" then "T.untyped"
      else text
      end
    end

    def strip_nilable_type(type)
      text = type.to_s.strip
      if text.start_with?("T.nilable(")
        NilKill.extract_call_args(text, "T.nilable") || text
      elsif (match = text.match(/\AOptional\[(.+)\]\z/))
        match[1].strip
      else
        text.gsub(/\s*\|\s*(?:None|null|undefined)\b/, "")
            .gsub(/\b(?:None|null|undefined)\s*\|\s*/, "")
            .strip
      end
    end

    def weak_slot_type?(type)
      source = type.to_s
      source.include?("T.any(") ||
        source.include?("T.untyped") ||
        source.match?(/\b(?:Any|any|unknown|object)\b/) ||
        source.match?(/\A(?:Array|Hash|Set|list|dict|List|Dict)\s*(?:\[\s*\]|\[\s*(?:Any|any|unknown|T\.untyped))/)
    end
  end
end
