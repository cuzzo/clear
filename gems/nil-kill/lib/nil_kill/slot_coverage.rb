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
    NODE_LIKE_SLOT_NAMES = %w[node expr expression stmt statement ast_node ast_expr mir_node mir_expr].freeze
    NON_NODE_AST_TYPES = %w[AST::RawBody AST::SyntheticTypeInput AST::TypeInput].freeze

    class << self
      def files_for(inputs)
        StaticEvidence.build(inputs.empty? ? ["src"] : inputs, root: ROOT)
          .fetch("files", [])
          .map { |file| File.expand_path(file.fetch("path"), ROOT) }
      end

      def scan(inputs = ["src"])
        new(inputs.empty? ? ["src"] : inputs).summaries
      end

      def analyze(inputs = ["src"])
        new(inputs.empty? ? ["src"] : inputs).analysis
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
      analysis.fetch("files")
    end

    def analysis
      @analysis ||= build_analysis
    end

    private

    def build_analysis
      evidence = StaticEvidence.build(@targets, root: ROOT)
      summaries = evidence.fetch("files", []).to_h do |file|
        [file.fetch("path"), self.class.empty_summary(file.fetch("path"))]
      end
      name_pressure = Hash.new do |hash, name|
        hash[name] = {
          "name" => name,
          "count" => 0,
          "categories" => Hash.new(0),
          "examples" => [],
        }
      end
      typed_name_counts = Hash.new { |hash, name| hash[name] = Hash.new(0) }

      method_signatures = method_signature_index(evidence)
      evidence.fetch("methods", []).each do |method|
        summary = summaries[method.fetch("path")] ||= self.class.empty_summary(method.fetch("path"))
        add_method_slots!(summary, method, method_signatures[method_key(method)], name_pressure, typed_name_counts)
      end

      field_types = field_type_index(evidence)
      seen_fields = Set.new
      evidence.fetch("fields", []).each do |field|
        summary = summaries[field.fetch("path")] ||= self.class.empty_summary(field.fetch("path"))
        type = field["declared_type"] || field_type_for(field_types, field)
        add_slot!(summary, field_category(field), type)
        record_name_slot!(name_pressure, typed_name_counts, field["name"], field_category(field).delete_suffix("s"), type, field_site(field))
        field_keys(field).each { |key| seen_fields.add(key) }
      end
      type_definitions(evidence).each do |definition|
        next unless definition["kind"] == "state_field"
        next if definition["type_system"] == "rbi"
        next if field_keys(definition).any? { |key| seen_fields.include?(key) }

        summary = summaries[definition.fetch("path")] ||= self.class.empty_summary(definition.fetch("path"))
        type = definition["declared_type"] || field_type_for(field_types, definition)
        add_slot!(summary, field_category(definition), type)
        record_name_slot!(name_pressure, typed_name_counts, definition["name"], field_category(definition).delete_suffix("s"), type, field_site(definition))
      end
      record_hash_shape_name_slots!(evidence, name_pressure, typed_name_counts)

      files = summaries.values.sort_by { |summary| summary.fetch("path") }.map do |summary|
        self.class.finalize_summary!(summary)
      end
      {
        "files" => files,
        "totals" => self.class.totals(files),
        "top_untyped_slot_names" => finalize_name_pressure(name_pressure, typed_name_counts),
      }
    end

    def method_signature_index(evidence)
      type_definitions(evidence).each_with_object({}) do |definition, index|
        next unless definition["kind"] == "method_signature"

        index[method_key(definition)] = definition
      end
    end

    def field_type_index(evidence)
      definitions = type_definitions(evidence)
      included_modules = included_modules_by_owner(definitions)
      definitions.each_with_object({}) do |definition, index|
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
        included_method_field_keys(definition, included_modules).each do |key|
          assign_field_type!(index, key, type)
        end
      end
    end

    def included_modules_by_owner(definitions)
      direct = Hash.new { |hash, key| hash[key] = Set.new }
      definitions.each do |definition|
        next unless definition["kind"] == "included_module"

        owner = definition["owner"].to_s
        name = definition["name"].to_s
        next if owner.empty? || name.empty?

        direct[owner].add(name)
      end

      direct.keys.each_with_object({}) do |owner, index|
        index[owner] = expanded_included_modules(owner, direct, Set.new)
      end
    end

    def expanded_included_modules(owner, direct, seen)
      return Set.new if seen.include?(owner)

      seen.add(owner)
      direct[owner].each_with_object(Set.new) do |mod, modules|
        modules.add(mod)
        expanded_included_modules(mod, direct, seen.dup).each { |nested| modules.add(nested) }
      end
    end

    def included_method_field_keys(definition, included_modules)
      return [] unless definition["kind"] == "method_signature"

      signature_owner = definition["owner"].to_s
      included_modules.flat_map do |owner, modules|
        next [] unless modules.include?(signature_owner)

        field_keys(definition.merge("owner" => owner))
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

    def add_method_slots!(summary, method, signature, name_pressure, typed_name_counts)
      param_types = Array(signature && signature["params"]).to_h do |param|
        [param["name"].to_s, param["type"]]
      end
      Array(method["params"]).each do |param|
        name = param.is_a?(Hash) ? param["name"] : param.to_s
        type = param_types[name]
        add_slot!(summary, "params", type)
        record_name_slot!(name_pressure, typed_name_counts, name, "param", type, method_site(method, name))
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

    def record_name_slot!(name_pressure, typed_name_counts, name, category, type, site)
      clean_name = name.to_s.delete_prefix("@")
      return if clean_name.empty?

      if slot_strength(type) == "untyped"
        row = name_pressure[clean_name]
        row["count"] += 1
        row["categories"][category] += 1
        row["examples"] << site if row["examples"].size < 3
      else
        typed_name_counts[clean_name][distribution_type(type, clean_name)] += 1
      end
    end

    def record_hash_shape_name_slots!(evidence, name_pressure, typed_name_counts)
      seen = Set.new
      Array(evidence.dig("facts", "hash_shapes")).each do |shape|
        keys = Array(shape["keys"])
        value_types = Array(shape["value_types"])
        keys.each_with_index do |key, index|
          name = key.to_s
          next if name.empty?

          site_key = [shape["path"], shape["line"], name, index]
          next if seen.include?(site_key)

          seen.add(site_key)
          type = value_types[index]
          site = "#{shape["path"]}:#{shape["line"]} hash field #{name}"
          record_name_slot!(name_pressure, typed_name_counts, name, "hash_field", type, site)
        end
      end
    end

    def finalize_name_pressure(name_pressure, typed_name_counts)
      name_pressure.values
        .select { |row| row["count"] > 1 }
        .map do |row|
          typed_hints = typed_hints_for(typed_name_counts[row.fetch("name")])
          out = row.merge(
            "categories" => Hash[row.fetch("categories").sort],
            "typed_total" => typed_name_counts[row.fetch("name")].values.sum
          )
          out["typed_hints"] = typed_hints unless typed_hints.empty?
          out
        end
        .sort_by { |row| [-row["count"], row["name"]] }
    end

    def typed_hints_for(type_counts)
      total = type_counts.values.sum
      return [] if total.zero?

      prominent = type_counts.sort_by { |type, count| [-count, type] }.select do |_type, count|
        (100.0 * count / total) > 25.0
      end
      return [] if prominent.empty?

      prominent_total = prominent.sum { |_type, count| count }
      hints = prominent.map do |type, count|
        {
          "type" => type,
          "count" => count,
          "percent" => (100.0 * count / total).round(1),
        }
      end
      other = total - prominent_total
      if other.positive?
        hints << {
          "type" => "Other",
          "count" => other,
          "percent" => (100.0 * other / total).round(1),
        }
      end
      hints
    end

    def method_site(method, param_name)
      owner = method["owner"].to_s
      member = [owner, method["name"]].reject(&:empty?).join("#")
      "#{method["path"]}:#{method["line"]} #{member} param #{param_name}"
    end

    def field_site(field)
      owner = field["owner"].to_s
      member = [owner, field["name"]].reject(&:empty?).join(".")
      "#{field["path"]}:#{field["line"]} #{member}"
    end

    def distribution_type(type, slot_name)
      normalized = normalize_slot_type(type)
      inner = strip_nilable_type(normalized)
      family = node_family_type(inner, slot_name)
      return normalized unless family

      nilable_slot_type?(normalized) ? "T.nilable(#{family})" : family
    end

    def node_family_type(type, slot_name)
      return nil unless NODE_LIKE_SLOT_NAMES.include?(slot_name.to_s)

      if ast_node_type?(type)
        "AST::Node"
      elsif mir_node_type?(type)
        "MIR::Node"
      end
    end

    def ast_node_type?(type)
      type == "AST::Node" ||
        (type.match?(/\AAST::[A-Z]\w+\z/) && !NON_NODE_AST_TYPES.include?(type))
    end

    def mir_node_type?(type)
      type == "MIR::Node" ||
        type == "MIR::Emittable" ||
        type.match?(/\AMIR::[A-Z]\w+\z/)
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
