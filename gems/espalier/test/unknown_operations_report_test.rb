# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/espalier"

class UnknownOperationsReportTest < Minitest::Test
  def test_groups_unknown_operations_by_language_and_ranks_by_occurrence
    manifest = [
      {
        module: "Parser", file: "lib/parser.py", language: :python,
        functions: [
          { name: "first", line: 4, quality_metrics: {
            big_o_unknowns: ["Array#rotate", "input.work"],
            big_o_unknown_operation_evidence: {
              "Array#rotate" => { "occurrences" => 2, "typed_unmodeled_occurrences" => 2, "evidence_gaps" => { "unmodeled_typed_operation" => 2 } },
              "input.work" => { "occurrences" => 1, "typed_unmodeled_occurrences" => 0, "evidence_gaps" => { "unresolved_receiver_type" => 1 } }
            }
          } },
          { name: "second", line: 9, quality_metrics: {
            big_o_unknowns: ["Array#rotate"],
            big_o_unknown_operation_evidence: {
              "Array#rotate" => { "occurrences" => 1, "typed_unmodeled_occurrences" => 1, "evidence_gaps" => { "unmodeled_typed_operation" => 1 } }
            }
          } }
        ]
      },
      {
        module: "Worker", file: "src/worker.ts", language: :typescript,
        functions: [
          { name: "run", line: 2, quality_metrics: { big_o_unknowns: ["Set#sweep"], big_o_evidence_gaps: ["unmodeled_typed_operation"] } }
        ]
      }
    ]

    report = Espalier::UnknownOperationsReport.build(manifest)

    assert_equal "espalier.unknown-operations.v1", report.fetch("schema")
    python = report.fetch("languages").find { |language| language.fetch("language") == "python" }
    assert_equal 4, python.fetch("unknown_occurrences")
    assert_equal 3, python.fetch("typed_unmodeled_occurrences")
    assert_equal ["Array#rotate", "input.work"], python.fetch("unknown_operations").map { |row| row.fetch("operation") }
    rotate = python.fetch("unknown_operations").first
    assert_equal 3, rotate.fetch("occurrences")
    assert_equal 3, rotate.fetch("typed_unmodeled_occurrences")
    assert_equal %w[Parser#first Parser#second], rotate.fetch("incomplete_functions").map { |function| function.fetch("subject") }
    assert_equal({ "unmodeled_typed_operation" => 3 }, rotate.fetch("evidence_gaps"))
    assert_equal [2, 1], rotate.fetch("incomplete_functions").map { |function| function.fetch("occurrences") }
  end

  def test_cli_format_is_machine_readable
    report = Espalier::UnknownOperationsReport.build([])
    assert_equal [], JSON.parse(JSON.generate(report)).fetch("languages")
  end
end
