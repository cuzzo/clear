# typed: false
# frozen_string_literal: true

module NilKill
  module Schema
    class RuntimeType
      NULL_NAMES = %w[nil null none undefined NilClass NoneType].freeze
      ARRAY_NAMES = %w[Array list tuple Set].freeze
      MAP_NAMES = %w[Hash dict Object Map table].freeze
      PRIMITIVE_NAMES = %w[
        String Symbol Integer Float TrueClass FalseClass Boolean bool str int float number
        string boolean bigint undefined
      ].freeze

      def self.normalize(value, language:)
        return normalize_hash(value, language: language) if value.is_a?(Hash)

        name = value.to_s
        kind = infer_kind(name, language)
        {
          "name" => name,
          "kind" => kind,
          "nullable" => kind == "null",
          "language" => language.to_s,
          "display" => name,
          "confidence" => "observed",
        }
      end

      def self.normalize_hash(value, language:)
        lang = (value["language"] || value[:language] || language).to_s
        name = (value["name"] || value[:name] || value["display"] || value[:display] || "unknown").to_s
        kind = (value["kind"] || value[:kind] || infer_kind(name, lang)).to_s
        {
          "name" => name,
          "kind" => kind,
          "nullable" => truthy?(value["nullable"] || value[:nullable]) || kind == "null",
          "language" => lang,
          "display" => (value["display"] || value[:display] || name).to_s,
          "confidence" => (value["confidence"] || value[:confidence] || "observed").to_s,
        }.tap do |out|
          members = value["members"] || value[:members]
          out["members"] = Array(members).map { |member| normalize(member, language: lang) } if members
        end
      end

      def self.infer_kind(name, language)
        down = name.to_s.downcase
        return "null" if NULL_NAMES.any? { |n| down == n.downcase }
        return "array" if ARRAY_NAMES.any? { |n| down == n.downcase }
        return "map" if MAP_NAMES.any? { |n| down == n.downcase }
        return "union" if name.to_s.include?("|")
        return "primitive" if PRIMITIVE_NAMES.any? { |n| down == n.downcase }
        return "record" if language.to_s == "lua" && down == "table"

        "class"
      end

      def self.nullable?(type)
        normalized = normalize(type, language: type.is_a?(Hash) ? (type["language"] || type[:language]) : nil)
        return true if normalized["nullable"]
        return true if normalized["kind"] == "null"

        Array(normalized["members"]).any? { |member| nullable?(member) }
      end

      def self.truthy?(value)
        value == true || value.to_s == "true"
      end
    end
  end
end
