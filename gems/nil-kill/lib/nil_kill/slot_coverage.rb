# typed: false
# frozen_string_literal: true

require "set"
require "json"
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
      @slot_type_overrides = load_slot_type_overrides
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
        type = field["declared_type"] || field_type_for(field_types, field)
        add_slot!(summary, field_category(field), type)
        field_keys(field).each { |key| seen_fields.add(key) }
      end
      type_definitions(evidence).each do |definition|
        next unless definition["kind"] == "state_field"
        next if definition["type_system"] == "rbi"
        next if field_keys(definition).any? { |key| seen_fields.include?(key) }

        summary = summaries[definition.fetch("path")] ||= self.class.empty_summary(definition.fetch("path"))
        type = definition["declared_type"] || field_type_for(field_types, definition)
        add_slot!(summary, field_category(definition), type)
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
        case definition["kind"]
        when "state_field"
          type = definition["declared_type"]
        when "method_signature"
          type = return_type_for(definition)
        else
          next
        end

        field_keys(definition).each do |key|
          assign_field_type!(index, key, type)
        end
      end
    end

    def field_type_for(index, record)
      candidates = field_keys(record).filter_map { |key| index[key] }
      candidates.find { |type| slot_strength(type) != "untyped" } ||
        override_field_type(record) ||
        candidates.first
    end

    def assign_field_type!(index, key, type)
      existing = index[key]
      if existing.nil? || better_field_type?(type, existing)
        index[key] = type
      end
    end

    def better_field_type?(candidate, existing)
      strengths = { "untyped" => 0, "weak" => 1, "strong" => 2 }
      strengths.fetch(slot_strength(candidate)) > strengths.fetch(slot_strength(existing))
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

    def field_keys(record)
      owner = record["owner"].to_s
      name = record["name"].to_s
      path = record["path"].to_s
      owners = [owner, qualified_owner(path, owner)].uniq
      names = [name]
      names << name.delete_prefix("@") if name.start_with?("@")

      owners.flat_map do |candidate|
        names.flat_map do |candidate_name|
          [
            [path, candidate, candidate_name],
            [candidate, candidate_name]
          ]
        end
      end
    end

    def qualified_owner(path, owner)
      return owner if owner.empty? || owner.include?("::")

      owner_alias = @slot_type_overrides.fetch("owner_aliases").find do |rule|
        rule_matches?(rule, "path" => path, "owner" => owner)
      end
      return owner unless owner_alias

      pattern = owner_alias.fetch("owner_pattern")
      owner.sub(pattern, owner_alias.fetch("qualified_owner"))
    end

    def override_field_type(record)
      path = record["path"].to_s
      owner = record["owner"].to_s
      name = record["name"].to_s
      owners = [owner, qualified_owner(path, owner)].uniq
      names = [name]
      names << name.delete_prefix("@") if name.start_with?("@")

      override = @slot_type_overrides.fetch("slot_types").find do |rule|
        rule_matches?(rule, "path" => path) &&
          owners.any? { |candidate| rule_matches?(rule, "owner" => candidate) } &&
          names.any? { |candidate| rule_matches?(rule, "name" => candidate) }
      end

      override && override.fetch("type")
    end

    def load_slot_type_overrides
      paths = ENV.fetch("NIL_KILL_SLOT_TYPE_OVERRIDES", "")
                 .split(File::PATH_SEPARATOR)
                 .map(&:strip)
                 .reject(&:empty?)
      overrides = {"owner_aliases" => [], "slot_types" => []}
      paths.each do |path|
        source = JSON.parse(File.read(File.expand_path(path)))
        overrides.fetch("owner_aliases").concat(Array(source["owner_aliases"]).map { |rule| normalize_owner_alias_rule(rule, path) })
        slot_rules = Array(source["slot_types"]) + Array(source["field_types"])
        overrides.fetch("slot_types").concat(slot_rules.map { |rule| normalize_slot_type_rule(rule, path) })
      rescue JSON::ParserError => error
        raise ArgumentError, "invalid NIL_KILL_SLOT_TYPE_OVERRIDES #{path}: #{error.message}"
      end
      overrides
    end

    def normalize_owner_alias_rule(rule, path)
      raise ArgumentError, "invalid owner_aliases rule in #{path}: expected object" unless rule.is_a?(Hash)

      pattern = pattern_for(rule, "owner")
      replacement = rule["qualified_owner"] || rule["replacement"]
      if pattern.nil? || replacement.to_s.empty?
        raise ArgumentError, "invalid owner_aliases rule in #{path}: owner and qualified_owner are required"
      end

      {
        "path_pattern" => compile_optional_pattern(rule, "path", path),
        "owner_pattern" => compile_pattern(pattern, "owner", path),
        "qualified_owner" => replacement.to_s,
      }
    end

    def normalize_slot_type_rule(rule, path)
      raise ArgumentError, "invalid slot_types rule in #{path}: expected object" unless rule.is_a?(Hash)

      type = rule["type"]
      if pattern_for(rule, "name").nil? || type.to_s.empty?
        raise ArgumentError, "invalid slot_types rule in #{path}: name and type are required"
      end

      {
        "path_pattern" => compile_optional_pattern(rule, "path", path),
        "owner_pattern" => compile_optional_pattern(rule, "owner", path),
        "name_pattern" => compile_pattern(pattern_for(rule, "name"), "name", path),
        "type" => type.to_s,
      }
    end

    def rule_matches?(rule, values)
      values.all? do |key, value|
        pattern = rule["#{key}_pattern"]
        pattern.nil? || pattern.match?(value.to_s)
      end
    end

    def compile_optional_pattern(rule, key, path)
      pattern = pattern_for(rule, key)
      pattern.nil? ? nil : compile_pattern(pattern, key, path)
    end

    def compile_pattern(pattern, key, path)
      Regexp.new(pattern.to_s)
    rescue RegexpError => error
      raise ArgumentError, "invalid #{key} pattern in #{path}: #{error.message}"
    end

    def pattern_for(rule, key)
      rule[key] || rule["#{key}_pattern"]
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
