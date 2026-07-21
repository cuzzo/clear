#!/usr/bin/env ruby
# frozen_string_literal: true

# MVP Model Context Protocol server over lineage.db.
#
# Read-only, stdio JSON-RPC (Content-Length framed, matching LSP transport
# framing). No MCP gem dependency: this hand-rolls the small subset of the
# protocol an agent actually exercises (initialize, tools/list, tools/call),
# and reuses the exact .sql query files the Rust UI/LSP already ship in
# sql/storage/ and sql/ui/runtime/ wherever one exists for the shape needed,
# so query logic never forks between the Rust and MCP surfaces.
#
# Five tools, deliberately not one per table (17 tables would be a poor
# design - see gems/lineage/README.md "MCP server" section): each answers
# one workflow question a coding agent actually asks before or during an
# edit, not a CRUD operation on a table.
#
# Usage: ruby mcp_server.rb --db lineage.db [--repo .]

require "json"
require "optparse"
require "sqlite3"

TOOL_ROOT = File.expand_path("..", __dir__)

options = { db: "lineage.db", repo: "." }
OptionParser.new do |opts|
  opts.on("--db=PATH") { |v| options[:db] = v }
  opts.on("--repo=PATH") { |v| options[:repo] = v }
end.parse!

db_path = File.expand_path(options[:db])
abort "lineage database not found: #{db_path} (run `lineage init`/`lineage build` first)" unless File.file?(db_path)

DB = SQLite3::Database.new(db_path, readonly: true)
DB.results_as_hash = true

def sql(relative_path)
  @sql_cache ||= {}
  @sql_cache[relative_path] ||= File.read(File.join(TOOL_ROOT, "sql", relative_path))
end

# ---------------------------------------------------------------------------
# Data access - thin wrappers, each either executes a reused .sql file
# verbatim or a small direct query for shapes with no existing UI/LSP
# equivalent (change history, cross-table file-risk aggregation).
# ---------------------------------------------------------------------------

def resolve_path_or_prefix(query_template, path)
  exact = DB.execute(query_template, [path])
  return [exact, path] unless exact.empty?

  [DB.execute(query_template.sub("= ?1", "LIKE ?1"), ["#{path}%"]), "#{path}*"]
end

def file_risk(path)
  base = <<~SQL
    SELECT COALESCE(le.path, u.original_path) AS current_path,
           COUNT(DISTINCT u.id) AS units,
           ROUND(AVG(u.current_line_cov), 1) AS avg_line_coverage,
           ROUND(AVG(u.current_mutant_cov), 1) AS avg_mutant_coverage,
           SUM(u.current_distinct_tests) AS total_distinct_tests,
           SUM(CASE WHEN u.is_hard_gated = 1 THEN 1 ELSE 0 END) AS hard_gated_units
    FROM logical_units u
    LEFT JOIN (
      SELECT unit_id, path,
             ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY timestamp DESC, id DESC) AS rank
      FROM events
    ) le ON le.unit_id = u.id AND le.rank = 1
    WHERE COALESCE(le.path, u.original_path) = ?1
    GROUP BY current_path
  SQL
  rows, matched = resolve_path_or_prefix(base, path)
  return { error: "no tracked units under #{path.inspect} (run `lineage build` first?)" } if rows.empty?

  hazard_rows = DB.execute(
    "SELECT path, COUNT(*) AS hazards FROM unit_hazards WHERE is_active = 1 AND path #{matched.end_with?("*") ? "LIKE ?1" : "= ?1"} GROUP BY path",
    [matched.end_with?("*") ? "#{path}%" : path]
  )
  hazards_by_path = hazard_rows.to_h { |row| [row["path"], row["hazards"]] }
  {
    scope: matched,
    files: rows.map do |row|
      row.merge("open_hazards" => hazards_by_path.fetch(row["current_path"], 0))
    end
  }
end

def unit_context(path, line)
  spans = DB.execute(sql("storage/current_unit_spans_for_path.sql"), [path])
  containing = spans
               .select { |row| line >= row["start_line"] && line <= row["end_line"] }
               .min_by { |row| row["end_line"] - row["start_line"] }
  return { error: "no tracked unit contains #{path}:#{line}" } unless containing

  unit = DB.execute(
    "SELECT id, name, type, original_path, start_line, current_line_cov, current_mutant_cov, " \
    "current_distinct_tests, current_test_types, current_mutant_verified_tests, " \
    "current_mutant_killed_tests, is_hard_gated FROM logical_units WHERE id = ?1",
    [containing["id"]]
  ).first
  events = DB.execute(
    "SELECT event_type, COUNT(*) AS count FROM events WHERE unit_id = ?1 GROUP BY event_type",
    [containing["id"]]
  ).to_h { |row| [row["event_type"], row["count"]] }
  hazards = DB.execute(sql("ui/runtime/apply_hazards.sql"), [path])
              .select { |row| row["line"] >= containing["start_line"] && row["line"] <= containing["end_line"] }
  hotness = DB.execute(sql("ui/runtime/apply_hotness.sql"), [path])
              .select { |row| row["line"] && row["line"] >= containing["start_line"] && row["line"] <= containing["end_line"] }
  findings = DB.execute(sql("storage/sarif_findings_for_path.sql"), [path])
               .select { |row| row["start_line"] && row["start_line"] >= containing["start_line"] && row["start_line"] <= containing["end_line"] }
               .map { |row| row.slice("rule_id", "level", "message", "start_line", "source", "is_dark_arm") }

  {
    unit: unit.slice("id", "name", "type", "original_path", "start_line", "current_line_cov",
                      "current_mutant_cov", "current_distinct_tests", "current_test_types",
                      "current_mutant_verified_tests", "current_mutant_killed_tests", "is_hard_gated"),
    span: [containing["start_line"], containing["end_line"]],
    event_counts: events,
    hazards: hazards.map { |row| row.slice("line", "hazard_type", "required_evidence", "verified", "source").transform_keys { |k| k == "source" ? "snippet" : k } },
    hotness: hotness.map { |row| row.slice("line", "tier", "cum_share", "source") },
    findings: findings
  }
end

def verification_gaps(path)
  is_prefix = DB.execute("SELECT 1 FROM unit_hazards WHERE path = ?1 LIMIT 1", [path]).empty? &&
              DB.execute("SELECT 1 FROM current_sarif_findings WHERE path = ?1 LIMIT 1", [path]).empty?
  hazard_sql = is_prefix ? "SELECT path, line, hazard_type, required_evidence, symbol, source AS snippet FROM unit_hazards WHERE is_active = 1 AND path LIKE ?1" \
                          : "SELECT path, line, hazard_type, required_evidence, symbol, source AS snippet FROM unit_hazards WHERE is_active = 1 AND path = ?1"
  finding_sql = is_prefix ? "SELECT path, start_line, rule_id, message FROM current_sarif_findings WHERE (is_dark_arm = 1 OR rule_id LIKE 'test-miser.%') AND path LIKE ?1" \
                           : "SELECT path, start_line, rule_id, message FROM current_sarif_findings WHERE (is_dark_arm = 1 OR rule_id LIKE 'test-miser.%') AND path = ?1"
  arg = is_prefix ? "#{path}%" : path
  {
    scope: is_prefix ? "#{path}*" : path,
    note: is_prefix ? "directory scope: raw active-hazard count, not the verified/unverified evidence join a single-file lookup gets" : nil,
    open_hazards: DB.execute(hazard_sql, [arg]),
    dark_arms_and_weak_tests: DB.execute(finding_sql, [arg])
  }.compact
end

def change_history(path, limit)
  {
    events: DB.execute(
      "SELECT commit_hash, event_type, timestamp, semantic_change, lines_added, lines_removed " \
      "FROM events WHERE path = ?1 ORDER BY timestamp DESC LIMIT ?2",
      [path, limit]
    ),
    crashes: DB.execute(
      "SELECT commit_hash, timestamp, error_class, is_verified FROM crash_events " \
      "WHERE path = ?1 ORDER BY timestamp DESC LIMIT ?2",
      [path, limit]
    )
  }
end

def find_definition(name, path, commit)
  # MVP simplification: the Rust find_definitions also consults an
  # in-flight engine_state checkpoint before this static query, for
  # freshness mid-incremental-build. That fast path is skipped here.
  rows = DB.execute(sql("storage/find_definitions.sql"), [name])
  rows = rows.first(100)
  {
    definitions: rows.map { |row| { path: row["path"], line: row["start_line"] } },
    note: (path || commit) ? "path/commit proximity ranking is not applied in this MVP; results are unranked" : nil
  }.compact
end

TOOLS = {
  "lineage_file_risk" => {
    description: "Coverage, mutation coverage, and open-hazard counts for a file or a directory prefix. " \
                  "Call before editing unfamiliar code to learn whether it is well-verified.",
    input_schema: {
      type: "object",
      properties: { "path" => { type: "string", description: "Repo-relative file path or directory prefix" } },
      required: ["path"]
    },
    handler: ->(args) { file_risk(args.fetch("path")) }
  },
  "lineage_unit_context" => {
    description: "Full context for the function/unit containing a specific line: risk, test coverage, " \
                  "mutation status, open hazards, runtime hotness, and static findings in its range. " \
                  "The richest tool - call before modifying a specific function.",
    input_schema: {
      type: "object",
      properties: {
        "path" => { type: "string", description: "Repo-relative file path" },
        "line" => { type: "integer", description: "1-indexed line number within the file" }
      },
      required: %w[path line]
    },
    handler: ->(args) { unit_context(args.fetch("path"), Integer(args.fetch("line"))) }
  },
  "lineage_verification_gaps" => {
    description: "Open hazards lacking evidence, dead/dark branch arms, and zero-kill (weak) tests in a file " \
                  "or directory. Call before trusting a coverage percentage at face value.",
    input_schema: {
      type: "object",
      properties: { "path" => { type: "string", description: "Repo-relative file path or directory prefix" } },
      required: ["path"]
    },
    handler: ->(args) { verification_gaps(args.fetch("path")) }
  },
  "lineage_change_history" => {
    description: "Recent commit-level events (changes/moves/fixes) and production crash occurrences for a " \
                  "file. Call before a risky refactor to see how fragile the area has been.",
    input_schema: {
      type: "object",
      properties: {
        "path" => { type: "string", description: "Repo-relative file path" },
        "limit" => { type: "integer", description: "Max rows per category (default 20)" }
      },
      required: ["path"]
    },
    handler: ->(args) { change_history(args.fetch("path"), Integer(args["limit"] || 20)) }
  },
  "lineage_find_definition" => {
    description: "Resolve a symbol name to its definition location(s) by rename-stable logical-unit identity, " \
                  "not text search.",
    input_schema: {
      type: "object",
      properties: {
        "name" => { type: "string", description: "Bare or qualified symbol name" },
        "path" => { type: "string", description: "Calling file, for future proximity ranking (currently unused)" }
      },
      required: ["name"]
    },
    handler: ->(args) { find_definition(args.fetch("name"), args["path"], args["commit"]) }
  }
}.freeze

# ---------------------------------------------------------------------------
# Minimal MCP-over-stdio protocol: JSON-RPC 2.0, Content-Length framing.
# ---------------------------------------------------------------------------

def read_message(io)
  headers = {}
  loop do
    line = io.readline("\r\n")
    return nil if line.nil?

    line = line.chomp("\r\n")
    break if line.empty?

    key, value = line.split(": ", 2)
    headers[key] = value
  end
  length = Integer(headers.fetch("Content-Length"))
  JSON.parse(io.read(length))
rescue EOFError
  nil
end

def write_message(io, payload)
  json = JSON.generate(payload)
  io.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
  io.flush
end

def handle_request(message)
  case message["method"]
  when "initialize"
    {
      protocolVersion: message.dig("params", "protocolVersion") || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "lineage-mcp", version: "0.1.0-mvp" }
    }
  when "tools/list"
    { tools: TOOLS.map { |name, tool| { name: name, description: tool[:description], inputSchema: tool[:input_schema] } } }
  when "tools/call"
    name = message.dig("params", "name")
    tool = TOOLS[name]
    return jsonrpc_error(-32602, "unknown tool: #{name}") unless tool

    begin
      result = tool[:handler].call(message.dig("params", "arguments") || {})
      { content: [{ type: "text", text: JSON.pretty_generate(result) }], isError: result.is_a?(Hash) && result.key?(:error) }
    rescue StandardError => e
      { content: [{ type: "text", text: "#{e.class}: #{e.message}" }], isError: true }
    end
  else
    jsonrpc_error(-32601, "method not found: #{message["method"]}")
  end
end

def jsonrpc_error(code, message)
  { __error__: { code: code, message: message } }
end

$stdin.sync = true
$stdout.sync = true
$stdin.binmode
$stdout.binmode

loop do
  message = read_message($stdin)
  break if message.nil?
  next unless message["method"] # ignore bare responses; this server issues no requests of its own

  if message["id"].nil?
    handle_request(message) # notification (e.g. notifications/initialized): process, no reply
    next
  end

  result = handle_request(message)
  response = if result.is_a?(Hash) && result[:__error__]
               { jsonrpc: "2.0", id: message["id"], error: result[:__error__] }
             else
               { jsonrpc: "2.0", id: message["id"], result: result }
             end
  write_message($stdout, response)
end
