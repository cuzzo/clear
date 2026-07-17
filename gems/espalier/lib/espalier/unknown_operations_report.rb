# frozen_string_literal: true

# Renders the complexity evidence gaps that are candidates for a Fact-Mine
# language configuration. This does not guess a native API: it groups the
# already-recorded unknown call identities by language and gives a reviewer the
# affected functions, paths, exact call frequency, and exact Fact-Mine evidence
# gap. The report is therefore a review queue, not an implicit registry outside
# Fact-Mine.
module Espalier
  class UnknownOperationsReport
    SCHEMA = "espalier.unknown-operations.v1"

    def self.build(manifest)
      new(manifest).build
    end

    def initialize(manifest)
      @manifest = Array(manifest)
    end

    def build
      grouped = Hash.new do |languages, language|
        languages[language] = Hash.new do |operations, operation|
          operations[operation] = {
            occurrences: 0,
            typed_unmodeled_occurrences: 0,
            incomplete_functions: {},
            evidence_gaps: Hash.new(0)
          }
        end
      end

      @manifest.each do |mod|
        language = value(mod, :language).to_s
        language = "generic" if language.empty?
        file = value(mod, :file).to_s
        Array(value(mod, :functions)).each do |function|
          metrics = value(function, :quality_metrics)
          next unless metrics.is_a?(Hash)

          unknowns = Array(value(metrics, :big_o_unknowns)).map(&:to_s).reject(&:empty?)
          next if unknowns.empty?

          subject = "#{value(mod, :module)}##{value(function, :name)}"
          operation_evidence = value(metrics, :big_o_unknown_operation_evidence)
          unknowns.each do |operation|
            row = grouped[language][operation]
            evidence = value(operation_evidence, operation)
            occurrence_count = positive_integer(value(evidence, :occurrences)) || 1
            typed_unmodeled_count = positive_integer(value(evidence, :typed_unmodeled_occurrences)) || 0
            gaps = evidence_gap_counts_for(evidence, metrics)

            row[:occurrences] += occurrence_count
            row[:typed_unmodeled_occurrences] += typed_unmodeled_count
            function_row = row[:incomplete_functions][subject] ||= {
              "subject" => subject,
              "path" => file,
              "line" => value(function, :line).to_i,
              "occurrences" => 0
            }
            function_row["occurrences"] += occurrence_count
            gaps.each { |gap, count| row[:evidence_gaps][gap] += count }
          end
        end
      end

      languages = grouped.sort_by { |language, _| language }.map do |language, operations|
        rows = operations.map do |operation, row|
          {
            "operation" => operation,
            "occurrences" => row[:occurrences],
            "typed_unmodeled_occurrences" => row[:typed_unmodeled_occurrences],
            "incomplete_functions" => row[:incomplete_functions].values.sort_by { |function| [function["path"], function["line"], function["subject"]] },
            "evidence_gaps" => row[:evidence_gaps].sort_by { |gap, count| [-count, gap] }.to_h
          }
        end
        rows.sort_by! do |row|
          [-row["occurrences"], -row["incomplete_functions"].length, row["operation"]]
        end
        {
          "language" => language,
          "unknown_operations" => rows,
          "unknown_occurrences" => rows.sum { |row| row["occurrences"] },
          "typed_unmodeled_occurrences" => rows.sum { |row| row["typed_unmodeled_occurrences"] },
          "unique_unknown_operations" => rows.length
        }
      end

      {
        "schema" => SCHEMA,
        "guidance" => "Map only a documented native API with a guaranteed bound in gems/fact-mine/config/stdlib_complexity/<language>.yml. unresolved_receiver_type and unresolved_call_target require type/call resolution, not a mapping.",
        "languages" => languages
      }
    end

    private

    def value(object, key)
      return nil unless object.respond_to?(:[])

      object[key] || object[key.to_s]
    end

    def positive_integer(value)
      value.to_i.positive? ? value.to_i : nil
    end

    def evidence_gap_counts_for(evidence, metrics)
      precise_gaps = value(evidence, :evidence_gaps)
      if precise_gaps.respond_to?(:each_pair)
        return precise_gaps.each_pair.each_with_object({}) do |(gap, count), counts|
          next if gap.to_s.empty?

          counts[gap.to_s] = positive_integer(count) || 1
        end
      end

      # A saved manifest from before operation-level evidence existed remains
      # readable, but callers can distinguish this compatibility fallback from
      # new exact per-operation evidence because its occurrence count is one.
      Array(value(metrics, :big_o_evidence_gaps)).map(&:to_s).reject(&:empty?).to_h { |gap| [gap, 1] }
    end
  end
end
