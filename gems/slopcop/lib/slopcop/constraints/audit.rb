# frozen_string_literal: true

require "json"

require_relative "diff"
require_relative "evidence"
require_relative "sarif"
require_relative "zig_provider"

module SlopCop
  module Constraints
    class Audit
      attr_reader :repo, :base, :head, :coverage_specs, :languages

      def initialize(repo:, base:, head: "HEAD", coverage_specs: [], languages: ["zig"])
        @repo = File.expand_path(repo)
        @base = base
        @head = head
        @coverage_specs = coverage_specs
        @languages = languages
      end

      def findings
        @findings ||= begin
          additions = Diff.added_lines(repo: repo, base: base, head: head)
          evidence = Evidence.from_specs(coverage_specs, repo: repo)
          languages.flat_map do |language|
            provider = Constraints.providers.fetch(language.to_s) do
              raise ArgumentError, "unsupported constraint language #{language.inspect}"
            end
            provider.findings(repo: repo, additions: additions, evidence: evidence)
          end.sort_by { |finding| [finding.path, finding.line, finding.rule_id] }
        end
      end

      def rules
        languages.flat_map do |language|
          Constraints.providers.fetch(language.to_s).rules
        end
      end

      def to_json(*args)
        JSON.pretty_generate(
          {
            "format" => "slopcop.constraints",
            "base" => base,
            "head" => head,
            "findings" => findings.map(&:to_h)
          },
          *args
        )
      end

      def to_sarif
        Sarif.render(findings, rules: rules)
      end

      def to_markdown
        lines = ["## SlopCop Constraint Audit", ""]
        lines << "**Diff:** `#{base}...#{head}`"
        lines << ""
        if findings.empty?
          lines << "No constraint coverage warnings."
          return "#{lines.join("\n")}\n"
        end

        lines << "| file | line | rule | evidence | finding |"
        lines << "| --- | ---: | --- | --- | --- |"
        findings.each do |finding|
          lines << "| `#{escape(finding.path)}` | #{finding.line} | `#{escape(finding.rule_id)}` | `#{escape(finding.required_evidence)}` | #{escape(finding.message)} |"
        end
        "#{lines.join("\n")}\n"
      end

      private

      def escape(value)
        value.to_s.gsub("|", "\\|")
      end
    end
  end
end
