# frozen_string_literal: true

# Advisory PR-time mutation summary for the Test Miser workflow.
#
# Aggregates whatever shard/merge reports this run produced and prints a
# markdown table of per-suite mutant counts. Counts only - weak-test and
# redundancy verdicts intentionally require the canonical corpus snapshot
# (see gems/test-miser/docs/agents/lineage-sync.md), so none are made here.
#
# Accepts Mutation Testing Elements reports (files.*.mutants[*].killedBy)
# and mutant-facts/v1 (mutants[*].killed_by, or subjects[*].killed/alive).
#
# Usage: ruby tools/test_miser_step_summary.rb REPORT_OR_DIR... [>> $GITHUB_STEP_SUMMARY]

require "json"

def suite_label(path, payload)
  sibling = File.join(File.dirname(path), "suite.txt")
  return File.read(sibling).strip if File.file?(sibling)

  payload.dig("test_miser", "suite") || File.basename(path)
end

def tally(payload)
  totals = { mutants: 0, killed: 0, survived: 0, uncovered: 0 }

  if payload["files"].is_a?(Hash)
    payload["files"].each_value do |details|
      Array(details["mutants"]).each do |mutant|
        totals[:mutants] += 1
        killed = !Array(mutant["killedBy"]).empty? || mutant["status"] == "Killed"
        covered = !Array(mutant["coveredBy"]).empty? || killed
        if killed then totals[:killed] += 1
        elsif covered then totals[:survived] += 1
        else totals[:uncovered] += 1
        end
      end
    end
  elsif payload["mutants"].is_a?(Array) && !payload["mutants"].empty?
    payload["mutants"].each do |mutant|
      totals[:mutants] += 1
      killed = !Array(mutant["killed_by"]).empty?
      covered = !Array(mutant["covered_by"]).empty? || killed
      if killed then totals[:killed] += 1
      elsif covered then totals[:survived] += 1
      else totals[:uncovered] += 1
      end
    end
  elsif payload["subjects"].is_a?(Array)
    payload["subjects"].each do |subject|
      mutations = subject["mutations"].to_i
      killed = subject["killed"].to_i
      totals[:mutants] += mutations
      totals[:killed] += killed
      totals[:survived] += [mutations - killed, 0].max
    end
  end

  totals
end

reports = ARGV.flat_map do |argument|
  if File.directory?(argument)
    Dir[File.join(argument, "**", "{mutants,facts,mutant-facts}*.json")].sort
  else
    [argument]
  end
end.select { |path| File.file?(path) }

by_suite = Hash.new { |hash, key| hash[key] = { mutants: 0, killed: 0, survived: 0, uncovered: 0 } }
reports.each do |path|
  payload = JSON.parse(File.read(path))
  suite = suite_label(path, payload)
  tally(payload).each { |key, value| by_suite[suite][key] += value }
rescue JSON::ParserError => error
  warn "skipping #{path}: #{error.message}"
end

puts "## Test Miser mutation run (advisory)"
puts
if by_suite.empty?
  puts "No mutation reports were produced by this run."
  exit 0
end

puts "| Suite | Mutants | Killed | Survived (covered) | Uncovered |"
puts "|---|---:|---:|---:|---:|"
by_suite.sort.each do |suite, totals|
  puts "| #{suite} | #{totals[:mutants]} | #{totals[:killed]} | #{totals[:survived]} | #{totals[:uncovered]} |"
end
totals = by_suite.values.each_with_object(Hash.new(0)) { |row, sum| row.each { |k, v| sum[k] += v } }
puts "| **total** | **#{totals[:mutants]}** | **#{totals[:killed]}** | **#{totals[:survived]}** | **#{totals[:uncovered]}** |"
puts
puts "_Counts are scoped to this run's diff plan. Weak-test and redundancy findings are only " \
     "published from the canonical default-branch snapshot (SARIF category `test-miser-canonical`)._"
