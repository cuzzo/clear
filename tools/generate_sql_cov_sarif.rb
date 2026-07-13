#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "tempfile"

ROOT = File.expand_path("..", __dir__)

options = {
  repo: ".",
  out_dir: "tmp/generalized-gems-sarif",
  setup: "gems/lineage/sql/storage/init_schema.sql",
  sql_cov_bin: "gems/sql-cov/target/release/sql-cov"
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate_sql_cov_sarif.rb [options]"
  parser.on("--repo=PATH") { |value| options[:repo] = value }
  parser.on("--out-dir=PATH") { |value| options[:out_dir] = value }
  parser.on("--setup=PATH") { |value| options[:setup] = value }
  parser.on("--sql-cov-bin=PATH") { |value| options[:sql_cov_bin] = value }
end.parse!

repo = File.realpath(options[:repo])
out_dir = File.expand_path(options[:out_dir])
setup_file = File.expand_path(options[:setup], repo)
sql_cov_bin = File.expand_path(options[:sql_cov_bin], ROOT)

FileUtils.mkdir_p(out_dir)

# Find all SQL files in gems/lineage/sql
sql_files = Dir.glob(File.join(repo, "gems/lineage/sql/**/*.sql"))
             .reject { |path| path == setup_file || File.basename(path) == "ensure_natural_key_indexes.sql" }
             .sort

warn "Found #{sql_files.size} SQL files to scan"

rules = {}
results = []
all_unresolved = []
scanned_files = 0
skipped_non_query_files = []
scan_failures = []

sql_files.each do |file|
  rel_path = file.sub("#{repo}/", "")
  source = File.read(file)
  statement = source.lines.reject { |line| line.lstrip.start_with?("--") }.join("\n").lstrip
  if %w[PRAGMA CREATE DROP].any? { |keyword| statement.start_with?(keyword) }
    skipped_non_query_files << rel_path
    next
  end

  normalized_file = nil
  input_file = file
  if source.include?("{column}")
    normalized_file = Tempfile.new(["sql-cov-normalized-", ".sql"])
    normalized_file.write(source.gsub("{column}", "current_line_cov"))
    normalized_file.flush
    input_file = normalized_file.path
  end

  cmd = [
    sql_cov_bin,
    "hazards",
    "--input", input_file,
    "--setup", setup_file,
    "--dialect", "sqlite",
    "--format", "sarif"
  ]
  
  begin
    stdout, stderr, status = Open3.capture3(*cmd)
  ensure
    normalized_file&.close!
  end
  unless status.success?
    warn "Failed to scan #{rel_path}: #{stderr}"
    scan_failures << "#{rel_path}: #{stderr.strip}"
    next
  end
  scanned_files += 1

  begin
    sarif_doc = JSON.parse(stdout)
    run = sarif_doc["runs"]&.first
    if run
      # Extract rules
      run["tool"]&.[]("driver")&.[]("rules")&.each do |rule|
        rule["defaultConfiguration"] = { "level" => "warning" }
        rules[rule["id"]] = rule
      end
      
      # Extract results
      run["results"]&.each do |result|
        # Native SQL-COV hazards are advisory in this repository. SQLFluff is
        # intentionally not requested above: its SARIF labels every lint and
        # formatting result as an error, which makes GitHub treat style debt as
        # a correctness gate.
        result["level"] = "warning"
        # Fix file URI paths to be relative for GitHub actions
        if result["locations"]
          result["locations"].each do |loc|
            if loc["physicalLocation"] && loc["physicalLocation"]["artifactLocation"]
              loc["physicalLocation"]["artifactLocation"]["uri"] = rel_path
            end
          end
        end
        results << result
      end
      
      # Extract unresolved schema facts
      run["properties"]&.[]("unresolvedSchemaFacts")&.each do |fact|
        all_unresolved << "#{rel_path}: #{fact}"
      end
    end
  rescue => e
    warn "Failed to parse sql-cov output for #{rel_path}: #{e.message}"
    scan_failures << "#{rel_path}: invalid SQL-COV SARIF: #{e.message}"
  end
end

all_unresolved = all_unresolved.sort.uniq
unless scan_failures.empty?
  abort "SQL-COV failed to scan #{scan_failures.size} files:\n- #{scan_failures.join("\n- ")}"
end

# Build master SARIF document
sarif_doc = {
  "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
  "version" => "2.1.0",
  "runs" => [{
    "tool" => {
      "driver" => {
        "name" => "sql-cov-hazards",
        "informationUri" => "https://cuzzo.github.io/clear/blog/an-ode-to-sql/",
        "semanticVersion" => "0.1.0",
        "rules" => rules.values
      }
    },
    "results" => results,
    "properties" => {
      "format" => "sql-cov/hazard/sarif",
      "dialect" => "sqlite",
      "unresolvedSchemaFacts" => all_unresolved,
      "scannedFiles" => scanned_files,
      "skippedNonQueryFiles" => skipped_non_query_files
    }
  }]
}

# Write SARIF
sarif_path = File.join(out_dir, "sql-cov.sarif")
File.write(sarif_path, JSON.pretty_generate(sarif_doc))
warn "Wrote #{sarif_path} with #{results.size} findings"

# Write Markdown
md_path = File.join(out_dir, "sql-cov.md")
md_content = String.new("# SQL-cov Hazards Report\n\n")
if results.empty?
  md_content << "No SQL logic hazards or three-valued logic bugs detected in database queries.\n"
else
  md_content << "### Findings Summary\n\n"
  md_content << "| File | Line | Expression | Hazard | Message | Tier |\n"
  md_content << "| --- | --- | --- | --- | --- | --- |\n"
  results.each do |res|
    file = res["locations"]&.first&.[]("physicalLocation")&.[]("artifactLocation")&.[]("uri") || "unknown"
    line = res["locations"]&.first&.[]("physicalLocation")&.[]("region")&.[]("startLine") || 0
    expr = res["locations"]&.first&.[]("physicalLocation")&.[]("region")&.[]("snippet")&.[]("text") || ""
    hazard = res["properties"]&.[]("kind") || res["ruleId"]
    msg = res["message"]&.[]("text") || ""
    tier = res["properties"]&.[]("tier") || "T1"
    md_content << "| `#{file}` | #{line} | `#{expr}` | **#{hazard}** | #{msg} | #{tier} |\n"
  end
end


md_content << "\n## Analysis Completeness\n\n"
md_content << "SQL-COV analyzed #{scanned_files} query files and skipped " \
              "#{skipped_non_query_files.size} non-query SQL files.\n\n"
if all_unresolved.empty?
  md_content << "SQL-COV resolved every schema fact needed by this scan.\n"
else
  md_content << "SQL-COV reported #{all_unresolved.size} unresolved schema facts. " \
                "These are analyzer-completeness gaps, not SQL findings.\n\n"
  md_content << "<details>\n<summary>Unresolved schema facts</summary>\n\n"
  all_unresolved.each { |fact| md_content << "- #{fact}\n" }
  md_content << "\n</details>\n"
end
File.write(md_path, md_content)
warn "Wrote #{md_path}"
