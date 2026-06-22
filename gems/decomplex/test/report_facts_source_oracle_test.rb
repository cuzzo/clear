# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/report_facts"

class ReportFactsSourceOracleTest < Minitest::Test
  def test_modifier_path_conditions_match_ruby_report_facts
    Tempfile.create(["decomplex_path_modifier", ".rb"]) do |file|
      file.write(<<~RB)
        def one
          grammar = ENV["GRAMMAR"]
          skip "missing" unless grammar && File.file?(grammar)
        end

        def two
          grammar = ENV["GRAMMAR"]
          skip "missing" unless grammar && File.file?(grammar)
        end
      RB
      file.flush

      expected = [
        {
          "guards" => ["!File.file?(grammar)", "!grammar"],
          "support" => 2,
          "scatter" => 2,
          "rank" => 4
        }
      ]

      assert_equal expected, projected_path_conditions(file.path, "ruby")
    end
  end

  private

  def projected_path_conditions(path, engine)
    facts = Decomplex::ReportFacts.from_files([path], engine: engine, jobs: 2)
    Array(facts.fetch("detectors").fetch("path_condition").fetch("scattered")).map do |row|
      row.slice("guards", "support", "scatter", "rank")
    end
  end
end
