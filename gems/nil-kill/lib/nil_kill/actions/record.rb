# typed: false
# frozen_string_literal: true

module NilKill
  module Actions
    class Record
      LEGACY_KIND_MAP = {
        "fix_sig_param" => "fix_signature_param",
        "fix_sig_return" => "fix_signature_return",
        "add_sig" => "add_type_annotation",
        "replace_dead_nil_check" => "replace_deterministic_guard",
        "remove_dead_safe_nav" => "replace_deterministic_guard",
        "narrow_tlet" => "narrow_field_type",
        "add_tlet" => "add_runtime_assertion",
      }.freeze

      def self.build(kind:, language:, confidence:, target:, message:, data: {}, provenance: {})
        {
          "schema_version" => 2,
          "id" => stable_id(kind, target, data),
          "kind" => kind.to_s,
          "language" => language.to_s,
          "confidence" => confidence.to_s,
          "target" => target,
          "path" => target["path"],
          "line" => target["line"],
          "message" => message.to_s,
          "preconditions" => Array(target["preconditions"]),
          "edits" => [],
          "data" => data,
          "provenance" => provenance,
        }
      end

      def self.from_legacy(action, language: "ruby")
        path = action["path"].to_s
        line = action["line"].to_i
        build(
          kind: LEGACY_KIND_MAP.fetch(action["kind"].to_s, action["kind"].to_s),
          language: language,
          confidence: action["confidence"],
          target: {
            "path" => path,
            "line" => line,
            "symbol_id" => "#{language}\0#{path}\0legacy\0action\0#{action["kind"]}\0#{line}",
          },
          message: action["message"],
          data: action["data"] || {},
          provenance: { "legacy_action" => action["kind"] }
        )
      end

      def self.stable_id(kind, target, data)
        raw = JSON.generate([kind.to_s, target["path"].to_s, target["line"].to_i, target["symbol_id"].to_s, data])
        "action-#{Digest::SHA256.hexdigest(raw)[0, 16]}"
      end
    end
  end
end
