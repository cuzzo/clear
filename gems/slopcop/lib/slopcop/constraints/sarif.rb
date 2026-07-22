# frozen_string_literal: true

require "json"
require_relative "../sarif"

module SlopCop
  module Constraints
    module Sarif
      module_function

      def render(findings, rules:)
        results = findings.map { |finding| result(finding) }
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
                "results" => results,
                "properties" => {
                  SlopCop::Sarif::PROOF_BOUNDARY_SUMMARY_PROPERTY => SlopCop::Sarif.proof_boundary_summary(results)
                }
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
            "source" => finding.source.to_s,
            SlopCop::Sarif::PROOF_BOUNDARY_PROPERTY => proof_boundary_for(finding)
          }
        }
      end

      def proof_boundary_for(finding)
        review = finding.message.to_s.include?("requires review")
        SlopCop::Sarif.proof_boundary(
          input_completeness: "unknown",
          claim_status: review ? "review" : "observed",
          coverage_discharge: review ? "unsatisfiable" : "satisfiable",
          authority: ["fact_mine_hazard_contract", "slopcop_coverage"],
          scope: "changed_hazard_coverage",
          blockers: review ? ["coverage_cannot_satisfy_hazard"] : [finding.required_evidence.to_s, "runtime_coverage_is_observational"]
        )
      end
    end
  end
end
