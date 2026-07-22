# frozen_string_literal: true

require "set"

require_relative "finding"

module SlopCop
  module Constraints
    module LanguageProvider
      module_function

      def findings(provider, repo:, additions:, evidence:)
        repo = File.expand_path(repo)
        changed_files = additions.keys.select { |path| provider.source_path?(path) }
        return [] if changed_files.empty?

        hazards = provider.scan_hazards(repo: repo, paths: changed_files)

        hazards.each_with_object([]) do |hazard, out|
          path = hazard[:path] || hazard["path"]
          lines = additions[path]
          next unless lines

          changed = lines.to_set
          line = hazard[:line] || hazard["line"]
          next unless changed.include?(line)
          req_ev = hazard[:required_evidence] || hazard["required_evidence"]
          report_required = hazard.key?(:report_required) ? hazard[:report_required] : hazard.fetch("report_required", true)
          next unless report_required

          coverage_required = hazard.key?(:coverage_required) ? hazard[:coverage_required] : hazard.fetch("coverage_required", true)
          if coverage_required
            next if covered?(evidence, hazard)
            message = "changed #{hazard[:label] || hazard["label"]} has no #{req_ev} coverage evidence"
          else
            claim = hazard[:evidence_claim] || hazard["evidence_claim"] || "site_reached"
            message = "changed #{hazard[:label] || hazard["label"]} requires review; #{claim} evidence cannot satisfy this hazard"
          end

          out << Finding.new(
            path: path,
            line: line,
            rule_id: provider.rule_id_for(req_ev),
            message: message,
            source: hazard[:source] || hazard["source"],
            hazard_type: hazard[:hazard_type] || hazard["hazard_type"],
            required_evidence: req_ev,
            severity: "warning"
          )
        end
      end

      def covered?(evidence, hazard)
        evidence_type = hazard[:required_evidence] || hazard["required_evidence"]
        return false unless evidence.known_type?(evidence_type)

        path = hazard[:path] || hazard["path"]
        line = hazard[:line] || hazard["line"]
        evidence.line_covered?(evidence_type, path, line)
      end

      def excluded_path?(path, dirs:, file_suffixes: [])
        parts = path.split("/")
        return true if parts.any? { |part| dirs.include?(part) || part.start_with?(".") }

        file_suffixes.any? { |suffix| path.end_with?(suffix) }
      end
    end
  end
end
