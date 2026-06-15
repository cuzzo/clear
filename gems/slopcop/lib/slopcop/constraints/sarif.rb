# frozen_string_literal: true

require "json"

module SlopCop
  module Constraints
    module Sarif
      module_function

      def render(findings, rules:)
        JSON.pretty_generate(
          {
            "version" => "2.1.0",
            "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
            "runs" => [
              {
                "tool" => {
                  "driver" => {
                    "name" => "SlopCop",
                    "informationUri" => "https://github.com/codeforreno/litedb",
                    "rules" => rules
                  }
                },
                "results" => findings.map { |finding| result(finding) }
              }
            ]
          }
        )
      end

      def result(finding)
        {
          "ruleId" => finding.rule_id,
          "level" => finding.severity || "warning",
          "message" => { "text" => finding.message },
          "locations" => [
            {
              "physicalLocation" => {
                "artifactLocation" => { "uri" => finding.path },
                "region" => { "startLine" => [finding.line.to_i, 1].max }
              }
            }
          ],
          "properties" => {
            "hazard_type" => finding.hazard_type,
            "required_evidence" => finding.required_evidence,
            "source" => finding.source.to_s
          }
        }
      end
    end
  end
end
