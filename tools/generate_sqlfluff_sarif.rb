#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
BLOCKING_RULES = %w[LXR PRS TMP].freeze

options = {
  repo: ".",
  out_dir: "tmp/generalized-gems-sarif",
  config: ".sqlfluff",
  sql_path: "gems/lineage/sql",
  sqlfluff_bin: "sqlfluff"
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate_sqlfluff_sarif.rb [options]"
  parser.on("--repo=PATH") { |value| options[:repo] = value }
  parser.on("--out-dir=PATH") { |value| options[:out_dir] = value }
  parser.on("--config=PATH") { |value| options[:config] = value }
  parser.on("--sql-path=PATH") { |value| options[:sql_path] = value }
  parser.on("--sqlfluff-bin=PATH") { |value| options[:sqlfluff_bin] = value }
end.parse!

repo = File.realpath(options[:repo])
out_dir = File.expand_path(options[:out_dir])
config = File.expand_path(options[:config], repo)
sql_path = File.expand_path(options[:sql_path], repo)
FileUtils.mkdir_p(out_dir)

stdout, stderr, status = Open3.capture3(
  options[:sqlfluff_bin],
  "lint",
  "--config", config,
  "--format", "sarif",
  sql_path,
  chdir: repo
)

# SQLFluff exits 1 when lint findings exist. Exit 2 indicates an invocation or
# configuration failure and must not be mistaken for a clean scan.
abort "SQLFluff failed (exit #{status.exitstatus}): #{stderr}" unless [0, 1].include?(status.exitstatus)

begin
  sarif = JSON.parse(stdout)
rescue JSON::ParserError => e
  abort "SQLFluff emitted invalid SARIF: #{e.message}\n#{stderr}"
end

runs = sarif.fetch("runs")
abort "SQLFluff SARIF must contain exactly one run" unless runs.one?

run = runs.first
results = run.fetch("results", [])
levels = results.to_h do |result|
  rule_id = result.fetch("ruleId")
  level = BLOCKING_RULES.include?(rule_id) ? "error" : "warning"
  result["level"] = level
  result["properties"] = (result["properties"] || {}).merge(
    "sqlfluffPolicy" => level == "error" ? "blocking-parser-or-templater-failure" : "advisory-ambiguity"
  )
  result.fetch("locations", []).each do |location|
    artifact = location.dig("physicalLocation", "artifactLocation")
    next unless artifact&.key?("uri")

    absolute_uri = File.expand_path(artifact["uri"], repo)
    artifact["uri"] = absolute_uri.delete_prefix("#{repo}/") if absolute_uri.start_with?("#{repo}/")
  end
  [rule_id, level]
end

run.dig("tool", "driver", "rules")&.each do |rule|
  level = levels.fetch(rule["id"], BLOCKING_RULES.include?(rule["id"]) ? "error" : "warning")
  rule["defaultConfiguration"] = { "level" => level }
end

run["properties"] = (run["properties"] || {}).merge(
  "policy" => "parser/templater failures block; configured ambiguity rules warn",
  "blockingRules" => BLOCKING_RULES,
  "config" => options[:config]
)

sarif_path = File.join(out_dir, "sqlfluff.sarif")
File.write(sarif_path, JSON.pretty_generate(sarif))

blocking_count = results.count { |result| result["level"] == "error" }
warning_count = results.count { |result| result["level"] == "warning" }
markdown = <<~MARKDOWN
  # SQLFluff Report

  SQLFluff reported #{blocking_count} blocking parser/templater failures and #{warning_count} advisory SQL ambiguity findings.

  Formatting, capitalization, alias-style, and other stylistic rules are intentionally excluded by `.sqlfluff` so this report remains actionable.
MARKDOWN
File.write(File.join(out_dir, "sqlfluff.md"), markdown)

warn "Wrote #{sarif_path} with #{blocking_count} blockers and #{warning_count} warnings"
