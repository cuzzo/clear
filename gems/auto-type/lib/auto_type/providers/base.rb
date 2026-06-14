# typed: false
# frozen_string_literal: true

module AutoType
  module Providers
    class Base
      def language
        raise NotImplementedError
      end

      def capabilities
        {
          "language" => language,
          "action_kinds" => [],
          "deterministic" => false,
          "plan_kind" => "unsupported",
        }
      end

      def supports?(_action)
        false
      end

      def plan(action, workspace:)
        RewritePlan.unsupported(
          provider: self.class.name,
          language: action_language(action),
          action: action,
          diagnostic: unsupported_diagnostic(action),
        )
      end

      private

      def action_language(action)
        raw = action["language"].to_s
        raw = action.dig("target", "language").to_s if raw.empty?
        raw.empty? ? "ruby" : raw
      end

      def unsupported_diagnostic(action)
        language = action_language(action)
        {
          "severity" => "info",
          "code" => "unsupported_auto_type_provider",
          "language" => language,
          "path" => action.dig("target", "path") || action["path"],
          "line" => action.dig("target", "line") || action["line"],
          "message" => "no Auto-type provider supports #{action["kind"]} for #{language}",
        }
      end
    end

    Provider = Base

    class NullProvider < Base
      def language
        "none"
      end
    end
  end
end
