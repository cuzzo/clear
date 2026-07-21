# frozen_string_literal: true

# WIP: cross-module change coupling from git history.
#
# Counts commits in which two production source files change together,
# keeping only pairs living in DIFFERENT modules (top-level directories) -
# same-directory co-change is expected and boring. Reports pairs by support
# (co-change commits) and confidence (co-changes / changes of the less-churned
# file). File-granularity is the WIP simplification; Lineage's rename-stable
# unit ledger is the intended upgrade path.
#
# Usage: ruby change_coupling.rb REPO_ROOT [min_support] [--sarif=PATH] [--base=REF [--head=REF]]

require "set"
require "json"
require "open3"

RULES = [
  {
    "id" => "arch-change-coupling",
    "name" => "Cross-module change coupling",
    "shortDescription" => { "text" => "Files in different modules almost always change together" },
    "fullDescription" => {
      "text" => "High co-change support and confidence between files in different modules indicates a hidden dependency or a misplaced boundary: the logical unit spans the module split."
    },
    "defaultConfiguration" => { "level" => "note" }
  }
].freeze

args = []
options = { sarif: nil, base: nil, head: nil }
ARGV.each do |arg|
  case arg
  when /\A--sarif=(.+)/ then options[:sarif] = Regexp.last_match(1)
  when /\A--base=(.+)/ then options[:base] = Regexp.last_match(1)
  when /\A--head=(.+)/ then options[:head] = Regexp.last_match(1)
  else args << arg
  end
end

repo = File.expand_path(args[0] || ".")
min_support = (args[1] || 5).to_i

SOURCE_EXT = /\.(rb|py|js|mjs|cjs|ts|go|c|h|cc|cpp|cxx|hpp|hh|cs|java|kt|swift|lua|rs|zig|php)\z/
EXCLUDE = %r{(^|/)(test|tests|spec|specs|vendor|node_modules|examples?|bench(mark)?s?|dist|build|target|docs?|fixtures)(/|$)|(^|/)test_|[._](test|spec)\.}

def module_of(path)
  parts = path.split("/")
  parts.size > 1 ? parts[0] : "(root)"
end

commits = []
current = nil
IO.popen(["git", "-C", repo, "log", "--no-merges", "--format=%x01%H", "--name-only"]) do |io|
  io.each_line do |line|
    line = line.strip
    if line.start_with?("\x01")
      commits << current if current
      current = []
    elsif !line.empty? && line.match?(SOURCE_EXT) && !line.match?(EXCLUDE)
      current << line if current
    end
  end
end
commits << current if current

# Bulk commits (mass renames, reformats, generators) poison co-change counts.
commits.reject! { |files| files.size > 20 || files.size < 2 }

file_changes = Hash.new(0)
pair_changes = Hash.new(0)
commits.each do |files|
  files = files.uniq
  files.each { |f| file_changes[f] += 1 }
  files.combination(2) do |a, b|
    next if module_of(a) == module_of(b) && File.dirname(a) == File.dirname(b)
    pair_changes[[a, b].sort] += 1
  end
end

rows = pair_changes.filter_map do |(a, b), support|
  next if support < min_support
  confidence = support.to_f / [file_changes[a], file_changes[b]].min
  distance = module_of(a) == module_of(b) ? "cross-dir" : "cross-module"
  [support, confidence, distance, a, b]
end

changed = nil
if options[:base]
  stdout, _stderr, status = Open3.capture3(
    "git", "-C", repo, "diff", "--name-only", "#{options[:base]}...#{options[:head] || "HEAD"}"
  )
  changed = stdout.lines.map(&:strip).reject(&:empty?).to_set if status.success?
end

rows = rows.select { |_, _, _, a, b| changed.include?(a) || changed.include?(b) } if changed

puts "repo: #{repo}  commits considered: #{commits.size}"
puts
puts "== Change-coupled pairs (support >= #{min_support}, sorted by support*confidence) =="
sorted_rows = rows.sort_by { |s, c, _, _, _| -(s * c) }
sorted_rows.first(15).each do |support, confidence, distance, a, b|
  printf("  s=%-3d c=%.2f %-12s %s <-> %s\n", support, confidence, distance, a, b)
end
puts "  (none)" if rows.empty?

if options[:sarif]
  findings = sorted_rows.first(50).map do |support, confidence, distance, a, b|
    {
      rule_id: "arch-change-coupling",
      level: "note",
      message: "#{a} and #{b} co-changed in #{support} commits (confidence #{confidence.round(2)}, #{distance})",
      path: a,
      line: 1
    }
  end
  document = {
    "$schema" => "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
    "version" => "2.1.0",
    "runs" => [
      {
        "tool" => { "driver" => { "name" => "lineage-change-coupling", "rules" => RULES } },
        "results" => findings.map do |finding|
          {
            "ruleId" => finding[:rule_id],
            "level" => finding[:level],
            "message" => { "text" => finding[:message] },
            "locations" => [
              {
                "physicalLocation" => {
                  "artifactLocation" => { "uri" => finding[:path] },
                  "region" => { "startLine" => finding[:line] }
                }
              }
            ]
          }
        end
      }
    ]
  }
  File.write(options[:sarif], JSON.pretty_generate(document))
end
