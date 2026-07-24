# typed: false
# frozen_string_literal: true

require "digest"
require "json"
require_relative "static_helpers"

module Espalier
  class AliasRecommendations
    MAX_ALIAS_UNION_TYPES = 4
    MAX_ALIAS_TARGET_LENGTH = 240

    def self.build(type_definitions:, minimum_slots: 1)
      new(type_definitions, minimum_slots: minimum_slots).build
    end

    def initialize(type_definitions, minimum_slots: 1)
      @type_definitions = Array(type_definitions)
      @minimum_slots = minimum_slots.to_i.positive? ? minimum_slots.to_i : 1
    end

    def build
      by_path, by_owner = index_slots(slot_records)
      aliases.filter_map do |definition|
        target = alias_target(definition)
        profile = type_profile_for_definition(definition)
        next if target.empty? || noisy_alias_target?(target, profile)

        alias_name = qualified_alias_name(definition)
        next if alias_name.empty?

        matches = candidate_slots(definition, by_path, by_owner)
          .filter_map { |slot| alias_slot_match(slot, definition, alias_name, target, profile) }
        next if matches.size < @minimum_slots

        recommendation(definition, alias_name, target, matches)
      end.sort_by { |row| [-row["slot_count"].to_i, row["alias"].to_s, row.dig("definition", "path").to_s] }
    end

    # A slot can only match an alias in the same language whose scope covers it:
    # the same file, or the alias owner / a nesting ancestor of it (see
    # `alias_scope_matches_slot?`). Bucketing slots by `[language, path]` and by
    # `[language, owner-and-every-ancestor]` lets each alias examine only that
    # union instead of every slot, turning the O(aliases x slots) scan into a
    # scoped lookup. The result set is identical - `alias_slot_match` still runs
    # its full guards on the candidates.
    def index_slots(slots)
      by_path = Hash.new { |hash, key| hash[key] = [] }
      by_owner = Hash.new { |hash, key| hash[key] = [] }
      slots.each do |slot|
        language = slot["language"].to_s
        by_path[[language, slot["path"].to_s]] << slot
        ancestor = slot["owner"].to_s
        until ancestor.empty?
          by_owner[[language, ancestor]] << slot
          separator = ancestor.rindex("::")
          break unless separator

          ancestor = ancestor[0...separator]
        end
      end
      [by_path, by_owner]
    end

    def candidate_slots(definition, by_path, by_owner)
      language = definition["language"].to_s
      path_slots = by_path[[language, definition["path"].to_s]]
      owner = definition["owner"].to_s
      return path_slots if owner.empty?

      (by_owner[[language, owner]] + path_slots).uniq(&:object_id)
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

    def alias_slot_match(slot, definition, alias_name, target, profile)
      return nil if same_definition?(slot, definition)
      return nil unless slot["language"].to_s == definition["language"].to_s
      return nil unless alias_scope_matches_slot?(slot, definition)
      return nil if references_alias?(slot["current_type"], alias_name, definition["name"], profile)

      replacement = replacement_for(slot["current_type"], target, alias_name, profile)
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

    def replacement_for(current, target, alias_name, profile)
      profile.alias_replacement(current, target, alias_name)
    end

    def alias_target(definition)
      (definition["target"] || definition["type"] || definition["declared_type"] || definition["value"]).to_s.strip
    end

    def qualified_alias_name(definition)
      name = definition["name"].to_s.strip
      return name if name.empty? || name.include?("::") || definition["owner"].to_s.empty?

      "#{definition["owner"]}::#{name}"
    end

    def noisy_alias_target?(target, profile)
      profile.noisy_alias_target?(
        target,
        max_union_types: MAX_ALIAS_UNION_TYPES,
        max_length: MAX_ALIAS_TARGET_LENGTH
      )
    end

    def references_alias?(type, qualified_name, short_name, profile = Espalier.type_profile_for(:generic))
      aliases = [qualified_name, short_name].map(&:to_s).reject(&:empty?).uniq
      profile.references_alias?(type, aliases)
    end

    def type_profile_for_definition(definition)
      Espalier.type_profile_for(definition["language"], type_system: definition["type_system"])
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
