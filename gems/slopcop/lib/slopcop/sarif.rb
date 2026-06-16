# frozen_string_literal: true

require "json"
require_relative "rollup"

module SlopCop
  module Sarif
    SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
    RULE_ID = "slopcop.genuine-gap"

    module_function

    def render(report)
      JSON.pretty_generate(document(report))
    end

    def document(report)
      data = report.to_h
      gaps = data.fetch("top_gaps", [])
      dark_arms = data.fetch("dark_arms", [])
      rules = [genuine_gap_rule] + dark_arm_rules(data.fetch("totals", {}).keys)
      {
        "version" => "2.1.0",
        "$schema" => SCHEMA,
        "runs" => [
          {
            "tool" => {
              "driver" => {
                "name" => "SlopCop",
                "informationUri" => "https://github.com/cuzzo/clear/tree/master/gems/slopcop",
                "rules" => rules
              }
            },
            "results" => gaps.map { |gap| genuine_gap_result(gap) } +
                         dark_arms.map { |arm| dark_arm_result(arm, rules) },
            "properties" => {
              "format" => "slopcop.report.sarif.v1",
              "slopcop.summary" => data.fetch("summary", {}),
              "slopcop.totals" => data.fetch("totals", {})
            }
          }
        ]
      }
    end

    def genuine_gap_rule
      {
        "id" => RULE_ID,
        "name" => "Genuine uncovered branch arm",
        "shortDescription" => {
          "text" => "Reachable branch arm is not covered by the supplied test corpus"
        },
        "fullDescription" => {
          "text" => "SlopCop classified this dark branch arm as a genuine test gap " \
                    "after filtering non-actionable arms such as type guards, " \
                    "defensive branches, diagnostics, external boundaries, and " \
                    "span-precise spurious decisions."
        },
        "defaultConfiguration" => { "level" => "warning" },
        "helpUri" => "https://github.com/cuzzo/clear/tree/master/gems/slopcop",
        "properties" => {
          "category" => "coverage",
          "precision" => "high"
        }
      }
    end

    def dark_arm_rules(categories)
      categories.map(&:to_s).sort.map do |category|
        {
          "id" => "slopcop.dark-arm.#{category}",
          "name" => "Dark arm: #{category}",
          "shortDescription" => {
            "text" => "Uncovered branch arm classified as #{category}"
          },
          "fullDescription" => {
            "text" => Rollup::ACTION.fetch(category.to_sym, "Uncovered branch arm")
          },
          "defaultConfiguration" => {
            "level" => category == "genuine" ? "warning" : "note"
          },
          "helpUri" => "https://github.com/cuzzo/clear/tree/master/gems/slopcop",
          "properties" => {
            "category" => category,
            "precision" => category == "genuine" ? "high" : "medium",
            "dark_arm" => true
          }
        }
      end
    end

    def genuine_gap_result(gap)
      file = gap.fetch("file", "")
      line = positive_line(gap["line"])
      {
        "ruleId" => RULE_ID,
        "ruleIndex" => 0,
        "level" => "warning",
        "message" => {
          "text" => message(gap)
        },
        "locations" => [
          {
            "physicalLocation" => {
              "artifactLocation" => { "uri" => normalize_path(file) },
              "region" => { "startLine" => line }
            }
          }
        ],
        "partialFingerprints" => {
          "slopcopGenuineGap" => fingerprint(file, line, gap.fetch("method", ""))
        },
        "properties" => {
          "method" => gap["method"],
          "churn" => gap["churn"],
          "decomplex_deviance" => gap["deviance"],
          "decomplex_detectors" => gap.fetch("detectors", []),
          "decomplex_precise" => gap["precise"],
          "coarse_duplication_hint" => gap["coarse_dup"],
          "priority" => gap["priority"],
          "verification" => gap["verification"],
          "risk_profile" => gap["risk_profile"],
          "mutation_kill_rate" => gap["mutation_kill_rate"],
          "mutation_gate_status" => gap["mutation_gate_status"]
        }.compact
      }
    end

    def dark_arm_result(arm, rules)
      category = arm.fetch("category", arm.fetch("arm_category", "genuine")).to_s
      rule_id = "slopcop.dark-arm.#{category}"
      line = positive_line(arm["line"])
      file = arm.fetch("file", "")
      method = arm.fetch("method", "")
      {
        "ruleId" => rule_id,
        "ruleIndex" => rules.index { |rule| rule.fetch("id") == rule_id },
        "level" => category == "genuine" ? "warning" : "note",
        "message" => {
          "text" => arm.fetch("message", "dark arm: #{category}")
        },
        "locations" => [
          {
            "physicalLocation" => {
              "artifactLocation" => { "uri" => normalize_path(file) },
              "region" => { "startLine" => line }
            }
          }
        ],
        "partialFingerprints" => {
          "slopcopDarkArm" => fingerprint(file, line, "#{method}:#{category}")
        },
        "properties" => arm.merge(
          "category" => category,
          "dark_arm" => true,
          "source_format" => "slopcop.report.v1"
        )
      }
    end

    def message(gap)
      method = gap.fetch("method", "")
      churn = gap.fetch("churn", 0)
      deviance = gap.fetch("deviance", 0)
      detectors = Array(gap["detectors"])
      detail = detectors.empty? ? "" : "; Decomplex: #{detectors.first(3).join(", ")}"
      "Genuine uncovered branch arm in #{method} " \
        "(churn=#{churn}, deviance=#{deviance}#{detail})"
    end

    def normalize_path(path)
      path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
    end

    def positive_line(value)
      line = value.to_i
      line.positive? ? line : 1
    end

    def fingerprint(file, line, method)
      [normalize_path(file), line, method.to_s].join(":")
    end
  end
end
