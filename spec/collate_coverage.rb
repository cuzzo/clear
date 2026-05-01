#!/usr/bin/env ruby
# Merge per-worker coverage entries (RSpec-w1-..., RSpec-w2-..., etc.)
# from coverage/.resultset.json into a single "RSpec" entry, then
# overwrite the file. RubyCritic's coverage analyser reads only
# `results.first` from the resultset (vendor/.../analysers/coverage.rb:16),
# so without this collation it sees only the parent's empty
# "RSpec" entry and reports 0% coverage for every file even though
# SimpleCov itself measured ~75%.
#
# Usage:
#   bundle exec prspec spec/
#   bundle exec ruby spec/collate_coverage.rb
#   bundle exec rubycritic src/ --no-browser

require "json"

resultset_path = File.expand_path("../coverage/.resultset.json", __dir__)
unless File.exist?(resultset_path)
  warn "no #{resultset_path} -- run specs first"
  exit 1
end

resultset = JSON.parse(File.read(resultset_path))

# Merge: for every file in any entry, take the per-line MAX hit count
# across all entries. nil + integer = integer; nil + nil = nil (line
# wasn't executable in any run).
merged_lines = {}
merged_branches = {}
latest_timestamp = 0

resultset.each do |_command_name, data|
  next unless data.is_a?(Hash)
  ts = data["timestamp"].to_i
  latest_timestamp = ts if ts > latest_timestamp

  (data["coverage"] || {}).each do |filename, file_data|
    lines = file_data["lines"] || []
    if (existing = merged_lines[filename])
      lines.each_with_index do |hit, i|
        cur = existing[i]
        existing[i] = if hit.nil? && cur.nil?
                        nil
                      elsif hit.nil?
                        cur
                      elsif cur.nil?
                        hit
                      else
                        cur + hit
                      end
      end
    else
      merged_lines[filename] = lines.dup
    end

    branches = file_data["branches"]
    if branches
      merged_branches[filename] ||= {}
      branches.each do |branch_id, conds|
        existing = merged_branches[filename][branch_id] || {}
        merged = existing.merge(conds) { |_, a, b| a.to_i + b.to_i }
        merged_branches[filename][branch_id] = merged
      end
    end
  end
end

# Build the new resultset: ONE entry, "RSpec".
collated_coverage = {}
merged_lines.each do |filename, lines|
  entry = { "lines" => lines }
  entry["branches"] = merged_branches[filename] if merged_branches[filename]
  collated_coverage[filename] = entry
end

File.write(resultset_path, JSON.pretty_generate(
  "RSpec" => {
    "coverage" => collated_coverage,
    "timestamp" => latest_timestamp,
  }
))

# Report what we did so the user can confirm coverage didn't drop.
total = merged_lines.values.flat_map { |l| l.compact }
hit = total.count { |h| h > 0 }
pct = total.empty? ? 0 : hit * 100.0 / total.size
puts "Collated #{resultset.size} entries (#{merged_lines.size} files) -> single 'RSpec' (%.1f%% line coverage)" % pct
