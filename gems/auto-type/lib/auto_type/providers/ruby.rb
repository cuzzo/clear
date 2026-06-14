# typed: false
# frozen_string_literal: true

module AutoType
  module Providers
    class RubyProvider < Base
      ACTION_KINDS = %w[
        add_sig
        fix_sig_param
        fix_sig_return
        narrow_generic_param
        narrow_generic_return
        narrow_tlet
        add_tlet
        remove_dead_safe_nav
        replace_dead_nil_check
        replace_nil_with_default
        promote_hash_record_to_struct
        promote_hash_record_cluster_to_struct
        add_struct_field_sig
      ].freeze

      def initialize(dry_run: false)
        @dry_run = dry_run
      end

      def language
        "ruby"
      end

      def capabilities
        {
          "language" => language,
          "action_kinds" => ACTION_KINDS,
          "deterministic" => true,
          "plan_kind" => "legacy_ruby_actions",
          "requires_verifier" => false,
        }
      end

      def supports?(action)
        language = action["language"].to_s
        language = action.dig("target", "language").to_s if language.empty?
        (language.empty? || language == "ruby") && ACTION_KINDS.include?(legacy_kind(action))
      end

      def plan(action, workspace:)
        return super unless supports?(action)

        RewritePlan.new(
          provider: self.class.name,
          language: language,
          supported: true,
          legacy_actions: [legacy_action(action)],
          risk: review_action?(action) ? "review" : "low",
          requires_verifier: review_action?(action),
        )
      end

      private

      def legacy_kind(action)
        if action["schema_version"].to_i == 2
          action.dig("data", "legacy_kind").to_s.empty? ? action["kind"].to_s : action.dig("data", "legacy_kind").to_s
        else
          action["kind"].to_s
        end
      end

      def legacy_action(action)
        return action.merge("kind" => legacy_kind(action)) unless action["schema_version"].to_i == 2

        data = action["data"] || {}
        {
          "kind" => legacy_kind(action),
          "confidence" => action["confidence"],
          "path" => action.dig("target", "path") || action["path"],
          "line" => action.dig("target", "line") || action["line"],
          "message" => action["message"],
          "data" => data,
        }
      end

      def review_action?(action)
        action["confidence"].to_s == AutoType.review_confidence
      end
    end

    register(RubyProvider)
  end
end
