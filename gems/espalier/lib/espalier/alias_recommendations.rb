# typed: false
# frozen_string_literal: true

require "digest"
require "json"
require_relative "static_helpers"

module Espalier
  class AliasRecommendations
    MAX_ALIAS_UNION_TYPES = 4
    MAX_ALIAS_TARGET_LENGTH = 240
    BROAD_TYPE_PATTERN = /\b(?:T\.untyped|T\.anything|typing\.Any|Any|any|unknown|Object|BasicObject)\b/.freeze

    def self.build(type_definitions:, minimum_slots: 1)
      new(type_definitions, minimum_slots: minimum_slots).build
    end

    def initialize(type_definitions, minimum_slots: 1)
      @type_definitions = Array(type_definitions)
      @minimum_slots = minimum_slots.to_i.positive? ? minimum_slots.to_i : 1
    end

    def build
      slots = slot_records
      aliases.filter_map do |definition|
        target = alias_target(definition)
        next if target.empty? || noisy_alias_target?(target)

        alias_name = qualified_alias_name(definition)
        next if alias_name.empty?

        matches = slots.filter_map { |slot| alias_slot_match(slot, definition, alias_name, target) }
        next if matches.size < @minimum_slots

        recommendation(definition, alias_name, target, matches)
      end.sort_by { |row| [-row["slot_count"].to_i, row["alias"].to_s, row.dig("definition", "path").to_s] }
    end

    private

    def aliases
      @type_definitions.select { |definition| definition["kind"].to_s == "type_alias" }
    end

    def slot_records
      @slot_records ||= @type_definitions.flat_map do |definition|
        case definition["kind"].to_s
        when "method_signature"
          method_signature_slots(definition)
        when "state_field"
          state_field_slots(definition)
        else
          []
        end
      end
    end

    def method_signature_slots(definition)
      slots = Array(definition["params"]).filter_map do |param|
        next unless param.is_a?(Hash)

        type = param["type"] || param["declared_type"]
        next if type.to_s.empty?

        slot_record(definition, "param", param["name"], type)
      end

      return_type = definition["return_type"] || definition.dig("return", "declared_type")
      slots << slot_record(definition, "return", "return", return_type) unless return_type.to_s.empty?

      if slots.empty? && definition["signature"].to_s.start_with?("sig ")
        Espalier.extract_param_entries(definition["signature"]).each do |name, type|
          slots << slot_record(definition, "param", name, type)
        end
        return_type = Espalier.extract_return_type(definition["signature"])
        slots << slot_record(definition, "return", "return", return_type) unless return_type.to_s.empty?
      end

      slots
    end

    def state_field_slots(definition)
      type = definition["declared_type"] || definition["type"] || definition.dig("source", "type")
      return [] if type.to_s.empty?

      [slot_record(definition, "field", definition["name"] || definition["field"], type)]
    end

    def slot_record(definition, kind, name, type)
      {
        "path" => definition["path"],
        "line" => definition["line"],
        "owner" => definition["owner"],
        "name" => definition["name"],
        "member_kind" => definition["kind"],
        "slot_kind" => kind,
        "slot" => name.to_s,
        "current_type" => type.to_s.strip,
        "signature" => definition["signature"],
        "language" => definition["language"],
        "type_system" => definition["type_system"],
      }
    end

    def alias_slot_match(slot, definition, alias_name, target)
      return nil if same_definition?(slot, definition)
      return nil unless slot["language"].to_s == definition["language"].to_s
      return nil unless alias_scope_matches_slot?(slot, definition)
      return nil if references_alias?(slot["current_type"], alias_name, definition["name"])

      replacement = replacement_for(slot["current_type"], target, alias_name)
      return nil unless replacement

      slot.merge("replacement_type" => replacement)
    end

    def alias_scope_matches_slot?(slot, definition)
      alias_owner = definition["owner"].to_s
      slot_owner = slot["owner"].to_s
      return slot["path"].to_s == definition["path"].to_s if alias_owner.empty?

      slot_owner == alias_owner ||
        slot_owner.start_with?("#{alias_owner}::") ||
        slot["path"].to_s == definition["path"].to_s
    end

    def same_definition?(slot, definition)
      slot["path"].to_s == definition["path"].to_s &&
        slot["line"].to_i == definition["line"].to_i &&
        slot["owner"].to_s == definition["owner"].to_s &&
        slot["name"].to_s == definition["name"].to_s
    end

    def replacement_for(current, target, alias_name)
      current = current.to_s.strip
      target = target.to_s.strip
      return alias_name if normalize_type(current) == normalize_type(target)

      nilable_inner = Espalier.extract_call_args(current, "T.nilable")
      if nilable_inner && normalize_type(nilable_inner) == normalize_type(target)
        return "T.nilable(#{alias_name})"
      end

      optional_inner = optional_type_inner(current)
      return "Optional[#{alias_name}]" if optional_inner && normalize_type(optional_inner) == normalize_type(target)

      nil
    end

    def optional_type_inner(current)
      match = current.to_s.strip.match(/\AOptional\[(.*)\]\z/)
      match && match[1]
    end

    def alias_target(definition)
      (definition["target"] || definition["type"] || definition["declared_type"] || definition["value"]).to_s.strip
    end

    def qualified_alias_name(definition)
      name = definition["name"].to_s.strip
      return name if name.empty? || name.include?("::") || definition["owner"].to_s.empty?

      "#{definition["owner"]}::#{name}"
    end

    def noisy_alias_target?(target)
      text = target.to_s.strip
      return true if text.empty?
      return true if text.length > MAX_ALIAS_TARGET_LENGTH
      return true if text.match?(BROAD_TYPE_PATTERN)
      return true if CORE_CLASS_CONSTANTS.include?(text)

      Espalier.broad_union_type?(text, max: MAX_ALIAS_UNION_TYPES)
    end

    def references_alias?(type, qualified_name, short_name)
      aliases = [qualified_name, short_name].map(&:to_s).reject(&:empty?).uniq
      aliases.any? do |name|
        escaped = Regexp.escape(name)
        type.to_s.match?(/(?<![A-Za-z0-9_:])#{escaped}(?![A-Za-z0-9_:])/)
      end
    end

    def normalize_type(type)
      type.to_s.gsub(/\s+/, "")
    end

    def recommendation(definition, alias_name, target, slots)
      first_slot = slots.min_by { |slot| [slot["path"].to_s, slot["line"].to_i, slot["slot_kind"].to_s, slot["slot"].to_s] }
      record = {
        "kind" => "alias_recommendation",
        "language" => definition["language"],
        "type_system" => definition["type_system"],
        "alias" => alias_name,
        "target" => target,
        "definition" => {
          "path" => definition["path"],
          "line" => definition["line"],
          "owner" => definition["owner"],
          "name" => definition["name"],
        },
        "slot_count" => slots.size,
        "slots" => slots.sort_by { |slot| [slot["path"].to_s, slot["line"].to_i, slot["slot_kind"].to_s, slot["slot"].to_s] },
        "path" => first_slot["path"],
        "line" => first_slot["line"],
        "confidence" => slots.size > 1 ? HIGH : REVIEW,
      }
      record["id"] = stable_id(record)
      record["message"] = "use #{alias_name} for #{target} in #{slots.size} static type slot#{slots.size == 1 ? "" : "s"}"
      record
    end

    def stable_id(record)
      raw = JSON.generate([record["alias"], record["target"], record.dig("definition", "path"),
        record.dig("definition", "line"), record["slots"].map { |slot| [slot["path"], slot["line"], slot["slot_kind"], slot["slot"]] }])
      "alias-#{Digest::SHA256.hexdigest(raw)[0, 16]}"
    end
  end
end
