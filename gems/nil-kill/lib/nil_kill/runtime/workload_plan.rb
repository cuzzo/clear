# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    class WorkloadPlan
      attr_reader :mode, :shards, :tests, :support_files, :original_commands

      def self.build(root:, targets:, commands:)
        providers = Array(targets).filter_map { |path| Languages.provider_for_path(path) }.uniq
        provider = providers.one? ? providers.first : nil
        raw = provider&.runtime_test_plan(root: root, targets: targets, commands: commands)
        new(root: root, commands: commands, raw: raw)
      end

      def self.from_h(root:, value:)
        shards = value.fetch("shards", {}).map do |id, shard|
          shard.merge("id" => id)
        end
        new(
          root: root,
          commands: shards.map { |shard| shard.fetch("command") },
          raw: {
            "mode" => value.fetch("mode"),
            "shards" => shards,
            "tests" => value.fetch("tests", {}),
            "support_files" => value.fetch("support_files", {}),
            "command_digest" => value.fetch("command_digest"),
          }
        )
      end

      def initialize(root:, commands:, raw: nil)
        @root = File.expand_path(root)
        @original_commands = commands
        raw ||= opaque_plan(commands)
        @mode = raw.fetch("mode")
        @shards = raw.fetch("shards")
        @tests = raw.fetch("tests", {})
        @support_files = raw.fetch("support_files", {})
        @command_digest = raw["command_digest"] ||
          Digest::SHA256.hexdigest(JSON.generate(original_commands))
      end

      def to_h
        {
          "mode" => mode,
          "command_digest" => command_digest,
          "tests" => tests,
          "support_files" => support_files,
          "shards" => shards.to_h do |shard|
            [shard.fetch("id"), shard]
          end,
        }
      end

      def command_digest
        @command_digest
      end

      def shard_ids
        shards.map { |shard| shard.fetch("id") }
      end

      private

      def opaque_plan(commands)
        {
          "mode" => "opaque",
          "shards" => commands.each_with_index.map do |command, index|
            {
              "id" => "command-#{index}-#{Digest::SHA256.hexdigest(JSON.generate(command))[0, 12]}",
              "command" => command,
              "test_path" => "",
            }
          end,
          "tests" => {},
          "support_files" => {},
        }
      end
    end
  end
end
