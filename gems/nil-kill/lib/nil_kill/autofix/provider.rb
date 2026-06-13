# typed: false
# frozen_string_literal: true

module NilKill
  module AutoFix
    class Provider
      def language
        raise NotImplementedError
      end

      def supports?(_action)
        false
      end

      def plan(action, _source_index = nil)
        { "supported" => false, "action" => action, "diagnostics" => [unsupported_diagnostic(action)] }
      end

      def apply(_plan, _workspace = NilKill::ROOT)
        0
      end

      def verify(_plan, _command_runner = nil)
        true
      end

      private

      def unsupported_diagnostic(action)
        {
          "severity" => "info",
          "code" => "unsupported_autofix_provider",
          "language" => action["language"],
          "path" => action.dig("target", "path") || action["path"],
          "line" => action.dig("target", "line") || action["line"],
          "message" => "no auto-fix provider supports #{action["kind"]} for #{action["language"]}",
        }
      end
    end

    class NullProvider < Provider
      def language
        "none"
      end
    end

    class RubyProvider < Provider
      def initialize(dry_run: false)
        @dry_run = dry_run
      end

      def language
        "ruby"
      end

      def supports?(action)
        action["language"].to_s.empty? || action["language"].to_s == "ruby"
      end

      def plan(action, _source_index = nil)
        return super unless supports?(action)

        { "supported" => true, "actions" => [legacy_action(action)] }
      end

      def apply(plan, _workspace = NilKill::ROOT)
        return 0 unless plan["supported"]

        args = @dry_run ? ["--dry-run"] : []
        Apply.new(args).apply_actions(plan["actions"])
      end

      private

      def legacy_action(action)
        return action unless action["schema_version"].to_i == 2

        data = action["data"] || {}
        {
          "kind" => data["legacy_kind"] || action["kind"],
          "confidence" => action["confidence"],
          "path" => action.dig("target", "path") || action["path"],
          "line" => action.dig("target", "line") || action["line"],
          "message" => action["message"],
          "data" => data,
        }
      end
    end

    def self.provider_for(language, dry_run: false)
      case language.to_s
      when "ruby" then RubyProvider.new(dry_run: dry_run)
      else NullProvider.new
      end
    end
  end
end
