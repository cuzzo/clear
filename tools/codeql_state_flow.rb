#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"

ROOT = File.expand_path("..", __dir__)
DEFAULT_DB = File.join(ROOT, "tmp", "codeql-ruby-db")
DEFAULT_OUT = File.join(ROOT, "tmp", "codeql-state-flow")
QUERY_DIR = File.join(ROOT, "tools", "codeql")
STATE_QUERY = File.join(QUERY_DIR, "StateFieldAccess.ql")
CALL_QUERY = File.join(QUERY_DIR, "CallEdges.ql")

DEFAULT_FIELDS = %w[
  full_type
  storage
  provenance
  ownership
  sync
  layout
  emit
  target
  value
  symbol
  name
  type
  left
  right
  expr
  result_type
].freeze

options = {
  db: DEFAULT_DB,
  out: DEFAULT_OUT,
  create_db: false,
  overwrite_db: false,
  source_root: ROOT,
  top: 40,
  format: "md",
  fields: DEFAULT_FIELDS,
  only: %w[src/],
  call_edges: false
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/codeql_state_flow.rb [options]"
  o.on("--db PATH", "CodeQL Ruby database path (default: tmp/codeql-ruby-db)") { |v| options[:db] = File.expand_path(v, ROOT) }
  o.on("--out DIR", "Output directory (default: tmp/codeql-state-flow)") { |v| options[:out] = File.expand_path(v, ROOT) }
  o.on("--create-db", "Create the Ruby CodeQL database before querying") { options[:create_db] = true }
  o.on("--overwrite-db", "Pass --overwrite to database create") { options[:overwrite_db] = true }
  o.on("--source-root PATH", "Source root for database create") { |v| options[:source_root] = File.expand_path(v, ROOT) }
  o.on("--only CSV", "Repo-relative path prefixes to include in the report (default: src/)") { |v| options[:only] = v.split(",").map(&:strip).reject(&:empty?) }
  o.on("--call-edges", "Also run the slower resolved-call-edge query") { options[:call_edges] = true }
  o.on("--top N", Integer, "Rows per ranking table") { |v| options[:top] = v }
  o.on("--format NAME", "md or json") { |v| options[:format] = v }
end.parse!

def sh(*args)
  puts args.join(" ")
  system(*args) || abort("command failed: #{args.join(" ")}")
end

def codeql
  ENV["CODEQL"] || "codeql"
end

def require_codeql!
  return if system(codeql, "version", out: File::NULL, err: File::NULL)

  abort <<~MSG
    CodeQL CLI not found. Install it and re-run this tool, or set CODEQL=/path/to/codeql.

    Expected workflow:
      ruby tools/codeql_state_flow.rb --create-db --overwrite-db
      ruby tools/codeql_state_flow.rb
  MSG
end

def create_database!(db, source_root, overwrite)
  args = [codeql, "database", "create", db, "--language=ruby", "--source-root=#{source_root}"]
  args << "--overwrite" if overwrite
  sh(*args)
end

def run_query!(db, query, bqrs)
  sh(codeql, "query", "run", query, "--database=#{db}", "--output=#{bqrs}")
end

def decode_csv!(bqrs, csv)
  sh(codeql, "bqrs", "decode", bqrs, "--format=csv", "--output=#{csv}")
end

def normalize_row(row)
  file = row["file"].to_s
  module_name = row["moduleName"].to_s
  method_name = row["methodName"].to_s
  method = module_name.empty? || module_name == "(top-level)" ? method_name : "#{module_name}##{method_name}"

  row.merge(
    "access_kind" => row["accessKind"].to_s,
    "method" => method,
    "caller" => [row["callerModule"], row["caller"]].compact.reject { |v| v.to_s.empty? || v == "(top-level)" }.join("#"),
    "callee" => row["callee"].to_s,
    "file" => file
  )
end

def csv_rows(path, only_prefixes)
  return [] unless File.exist?(path)

  CSV.read(path, headers: true).map { |row| normalize_row(row.to_h) }.select do |row|
    only_prefixes.empty? || only_prefixes.any? { |prefix| row["file"].start_with?(prefix) }
  end
rescue CSV::MalformedCSVError
  []
end

def count_by(rows, *keys)
  rows.each_with_object(Hash.new(0)) do |row, acc|
    values = keys.map { |k| row[k].to_s }
    next if values.any?(&:empty?)

    acc[values] += 1
  end
end

def top_counts(rows, *keys, limit:)
  count_by(rows, *keys).sort_by { |(_, count)| -count }.first(limit)
end

def markdown_table(headers, rows)
  out = +"| #{headers.join(" | ")} |\n"
  out << "| #{headers.map { "---" }.join(" | ")} |\n"
  rows.each { |row| out << "| #{row.join(" | ")} |\n" }
  out
end

def report_markdown(state_rows, call_rows, options)
  top = options[:top]
  out = +"# CodeQL State Flow Report\n\n"
  out << "- Database: `#{Pathname.new(options[:db]).relative_path_from(Pathname.new(ROOT))}`\n"
  out << "- State rows: #{state_rows.size}\n"
  out << "- Call edge rows: #{call_rows.size}\n"
  out << "- Tracked fields: #{options[:fields].join(", ")}\n\n"
  out << "- Included paths: #{options[:only].empty? ? "(all)" : options[:only].join(", ")}\n\n"

  out << "## Field Pressure\n\n"
  rows = top_counts(state_rows, "field", "access_kind", limit: top).map { |(key, count)| [key[0], key[1], count] }
  out << markdown_table(%w[field accesses count], rows)

  out << "\n## Methods Touching State\n\n"
  rows = top_counts(state_rows, "method", "field", limit: top).map { |(key, count)| [key[0], key[1], count] }
  out << markdown_table(%w[method field count], rows)

  out << "\n## Files Touching State\n\n"
  rows = top_counts(state_rows, "file", "field", limit: top).map { |(key, count)| [key[0], key[1], count] }
  out << markdown_table(%w[file field count], rows)

  out << "\n## Call Edge Pressure\n\n"
  rows = top_counts(call_rows, "caller", "callee", limit: top).map { |(key, count)| [key[0], key[1], count] }
  out << markdown_table(%w[caller callee count], rows)

  out
end

def report_json(state_rows, call_rows, options)
  JSON.pretty_generate(
    db: options[:db],
    tracked_fields: options[:fields],
    state_rows: state_rows,
    call_rows: call_rows,
    rankings: {
      field_pressure: top_counts(state_rows, "field", "access_kind", limit: options[:top]),
      method_field_pressure: top_counts(state_rows, "method", "field", limit: options[:top]),
      file_field_pressure: top_counts(state_rows, "file", "field", limit: options[:top]),
      call_edges: top_counts(call_rows, "caller", "callee", limit: options[:top])
    }
  )
end

require_codeql!
create_database!(options[:db], options[:source_root], options[:overwrite_db]) if options[:create_db]
abort "missing CodeQL database at #{options[:db]} (pass --create-db)" unless Dir.exist?(options[:db])

FileUtils.mkdir_p(options[:out])
fields_path = File.join(options[:out], "tracked-fields.json")
File.write(fields_path, JSON.pretty_generate(options[:fields]))

state_bqrs = File.join(options[:out], "state-field-access.bqrs")
state_csv = File.join(options[:out], "state-field-access.csv")
call_bqrs = File.join(options[:out], "call-edges.bqrs")
call_csv = File.join(options[:out], "call-edges.csv")

run_query!(options[:db], STATE_QUERY, state_bqrs)
decode_csv!(state_bqrs, state_csv)
if options[:call_edges]
  run_query!(options[:db], CALL_QUERY, call_bqrs)
  decode_csv!(call_bqrs, call_csv)
end

state_rows = csv_rows(state_csv, options[:only])
call_rows = csv_rows(call_csv, options[:only])
report = options[:format] == "json" ? report_json(state_rows, call_rows, options) : report_markdown(state_rows, call_rows, options)
report_path = File.join(options[:out], "report.#{options[:format] == "json" ? "json" : "md"}")
File.write(report_path, report)
puts "wrote #{report_path}"
