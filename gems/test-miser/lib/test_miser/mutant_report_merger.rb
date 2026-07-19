# frozen_string_literal: true

require "digest"

module TestMiser
  class MutantReportMerger
    def self.call(payloads)
      new(payloads).call
    end

    def initialize(payloads)
      @payloads = payloads
    end

    def call
      raise CollectionError, "no mutant shard reports to merge" if @payloads.empty?

      metadata = merged_metadata
      mutants_by_file = Hash.new { |hash, key| hash[key] = {} }
      tests_by_file = Hash.new { |hash, key| hash[key] = {} }
      @payloads.each do |payload|
        payload.fetch("files").each do |file, details|
          Array(details["mutants"]).each { |mutant| mutants_by_file[file][mutant.fetch("id")] = mutant }
        end
        payload.fetch("testFiles", {}).each do |file, details|
          Array(details["tests"]).each { |test| tests_by_file[file][test.fetch("id")] = test }
        end
      end

      completed = mutants_by_file.values.sum(&:length)
      expected = metadata.fetch("expectedMutants")
      complete = completed == expected && metadata.delete("componentsComplete")

      {
        "schemaVersion" => "2.0",
        "thresholds" => { "high" => 100, "low" => 0 },
        "files" => mutants_by_file.transform_values { |mutants| { "mutants" => mutants.values.sort_by { |row| row["id"] } } },
        "testFiles" => tests_by_file.transform_values { |tests| { "tests" => tests.values.sort_by { |row| row["id"] } } },
        "testMiser" => metadata.merge(
          "shard" => { "index" => 0, "total" => 1 },
          "assignedMutants" => expected,
          "completedMutants" => completed,
          "complete" => complete,
          "mergedShards" => metadata["mergedShards"] || 1
        )
      }
    end

    private

    def merged_metadata
      rows = @payloads.map { |payload| payload.fetch("testMiser") }
      fingerprints = rows.map { |row| row["corpusFingerprint"] }.uniq
      return shard_metadata(rows) if fingerprints.length == 1

      unless rows.all? { |row| row["complete"] == true }
        raise CollectionError, "cannot merge incomplete component corpora"
      end

      compatible = rows.flat_map { |row| Array(row["mutationCompatibleSubjects"]) }.uniq.sort
      expressions = rows.flat_map { |row| Array(row["subjectExpressions"]) }.uniq.sort
      attribution_modes = rows.map { |row| row["attributionMode"] }.compact.uniq
      {
        "schemaVersion" => "1",
        "subjectExpressions" => expressions,
        "mutationCompatibleSubjects" => compatible,
        "corpusFingerprint" => Digest::SHA256.hexdigest(fingerprints.sort.join("\0")),
        "expectedMutants" => rows.sum { |row| row.fetch("expectedMutants") },
        "expectedTests" => rows.map { |row| row["expectedTests"] }.uniq.one? ? rows.first["expectedTests"] : nil,
        "runToComplete" => rows.all? { |row| row["runToComplete"] == true },
        "attributionMode" => attribution_modes.one? ? attribution_modes.first : nil,
        "killSetsComplete" => rows.all? { |row| row["killSetsComplete"] == true },
        "componentCorpora" => rows.length,
        "componentsComplete" => true
      }.compact
    end

    def shard_metadata(rows)
      expected_counts = rows.map { |row| row["expectedMutants"] }.uniq
      shard_totals = rows.map { |row| row.dig("shard", "total") }.uniq
      unless expected_counts.length == 1 && shard_totals.length == 1
        raise CollectionError, "mutant shard reports describe different corpora"
      end

      shard_total = shard_totals.first
      shard_indexes = rows.map { |row| row.dig("shard", "index") }.uniq.sort

      rows.first.reject do |key, _value|
        %w[assignedMutants completedMutants complete mergedShards].include?(key)
      end.merge(
        "componentsComplete" => shard_indexes == (0...shard_total).to_a &&
          rows.all? { |row| row["runToComplete"] == true },
        "mergedShards" => shard_total
      )
    end
  end
end
