#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "set"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "gems/decomplex/lib"))
require "decomplex/sarif"

options = {
  repo: ".",
  head: "HEAD",
  out_dir: "tmp/lint-sarif"
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate_lint_sarif.rb [--base=REF] [options]"
  parser.on("--repo=PATH") { |value| options[:repo] = value }
  parser.on("--base=REF") { |value| options[:base] = value }
  parser.on("--head=REF") { |value| options[:head] = value }
  parser.on("--out-dir=PATH") { |value| options[:out_dir] = value }
end.parse!

repo = File.realpath(options[:repo])
out_dir = File.expand_path(options[:out_dir])
FileUtils.mkdir_p(out_dir)

IGNORED_COMPONENTS = %w[
  .git
  .zig-cache
  coverage
  node_modules
  target
  tmp
  vendor
  zig-out
].freeze

LINT_WEIGHT = 0.08

def run_capture(repo, *command)
  Open3.capture3(*command, chdir: repo)
rescue Errno::ENOENT => e
  ["", e.message, nil]
end

def repo_relative(path, repo)
  normalized = path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
  return normalized unless normalized.start_with?("/")

  root = "#{repo.tr("\\", "/").chomp("/")}/"
  normalized.start_with?(root) ? normalized[root.length..] : normalized
end

def ignored_path?(path)
  path.split("/").any? { |component| IGNORED_COMPONENTS.include?(component) }
end

def changed_files(repo, base, head)
  return nil unless base

  out, err, status = run_capture(
    repo,
    "git", "diff", "--name-only", "--diff-filter=ACMRT", "#{base}...#{head}"
  )
  abort(err.empty? ? out : err) unless status&.success?

  out.lines.map(&:strip).reject(&:empty?).map { |path| repo_relative(path, repo) }
end

def all_files(repo, extension)
  Dir.chdir(repo) do
    Dir.glob("**/*.#{extension}", File::FNM_DOTMATCH)
       .reject { |path| ignored_path?(path) || !File.file?(path) }
       .sort
  end
end

def source_files(repo, changed, extension)
  files = changed || all_files(repo, extension)
  files.select do |path|
    path.end_with?(".#{extension}") &&
      !ignored_path?(path) &&
      File.file?(File.join(repo, path))
  end.sort.uniq
end

def sarif_document(tool_name, results)
  rules = results.map do |result|
    rule_id = result.fetch("ruleId")
    Decomplex::Sarif.rule(
      id: rule_id,
      name: rule_id,
      short_description: result.dig("message", "text").to_s.split("\n").first,
      default_level: result.fetch("level", "warning"),
      properties: {
        "category" => "lint",
        "precision" => "medium"
      }
    )
  end

  JSON.pretty_generate(
    Decomplex::Sarif.document(
      tool_name: tool_name,
      information_uri: "https://github.com/cuzzo/clear",
      rules: rules,
      results: results,
      properties: {
        "format" => "lineage.lint.sarif.v1",
        "category" => "lint"
      }
    )
  )
end

def lint_result(rule_id:, message:, path:, line:, start_column: nil, end_line: nil,
                end_column: nil, level: "warning", tool:, extra: {})
  Decomplex::Sarif.result(
    rule_id: rule_id,
    message: message,
    path: path,
    line: line,
    start_column: start_column,
    end_line: end_line,
    end_column: end_column,
    level: level,
    properties: {
      "category" => "lint",
      "lint" => true,
      "lint_tool" => tool,
      "lint_weight" => LINT_WEIGHT
    }.merge(extra),
    partial_fingerprints: {
      "lineageLint" => [tool, rule_id, path, line, message].join("\0")
    }
  )
end

def write_sarif(out_dir, name, tool_name, results)
  path = File.join(out_dir, "#{name}.sarif")
  File.write(path, sarif_document(tool_name, results))
  warn "wrote #{path} (#{results.size} findings)"
end

def sarif_level_from_rubocop(severity)
  case severity.to_s
  when "fatal", "error"
    "error"
  else
    "warning"
  end
end

def rubocop_results(repo, ruby_files)
  return [] if ruby_files.empty?

  stdout, stderr, status = run_capture(
    repo,
    "bundle", "exec", "rubocop",
    "--config", "tools/lint/rubocop_lineage.yml",
    "--format", "json",
    "--force-exclusion",
    *ruby_files
  )
  warn stderr unless stderr.empty?
  warn "rubocop exited #{status&.exitstatus}" if status && !status.success? && stdout.strip.empty?
  data = JSON.parse(stdout)

  data.fetch("files", []).flat_map do |file|
    path = repo_relative(file.fetch("path"), repo)
    file.fetch("offenses", []).map do |offense|
      location = offense.fetch("location", {})
      rule_id = offense.fetch("cop_name", "rubocop")
      line = Integer(location.fetch("line", 1))
      column = location["column"] ? Integer(location["column"]) : nil
      last_line = location["last_line"] ? Integer(location["last_line"]) : nil
      end_column = if location["last_column"]
                     Integer(location["last_column"])
                   elsif column && location["length"]
                     column + Integer(location["length"])
                   end
      lint_result(
        rule_id: rule_id,
        message: offense.fetch("message", rule_id),
        path: path,
        line: line,
        start_column: column,
        end_line: last_line,
        end_column: end_column,
        level: sarif_level_from_rubocop(offense["severity"]),
        tool: "rubocop",
        extra: {
          "severity" => offense["severity"],
          "correctable" => offense["correctable"]
        }
      )
    end
  end
rescue JSON::ParserError => e
  warn "could not parse RuboCop JSON: #{e.message}"
  []
end

def clippy_results(repo, changed)
  stdout, stderr, status = run_capture(
    repo,
    "cargo", "clippy",
    "--manifest-path", "gems/lineage/Cargo.toml",
    "--all-targets",
    "--all-features",
    "--message-format=json",
    "--",
    "-W", "clippy::correctness",
    "-W", "clippy::suspicious",
    "-W", "clippy::perf",
    "-W", "clippy::complexity"
  )
  warn stderr unless stderr.empty?
  warn "clippy exited #{status&.exitstatus}" if status && !status.success?
  changed_set = changed&.to_set

  stdout.lines.filter_map do |line|
    event = JSON.parse(line)
    next unless event["reason"] == "compiler-message"

    message = event.fetch("message", {})
    code = message.dig("code", "code").to_s
    next unless code.start_with?("clippy::")

    span = Array(message["spans"]).find { |candidate| candidate["is_primary"] } ||
           Array(message["spans"]).first
    next unless span

    path = repo_relative(span.fetch("file_name"), repo)
    next if changed_set && !changed_set.include?(path)

    lint_result(
      rule_id: code,
      message: message.fetch("message", code),
      path: path,
      line: Integer(span.fetch("line_start", 1)),
      start_column: span["column_start"] ? Integer(span["column_start"]) : nil,
      end_line: span["line_end"] ? Integer(span["line_end"]) : nil,
      end_column: span["column_end"] ? Integer(span["column_end"]) : nil,
      level: message.fetch("level", "warning"),
      tool: "clippy"
    )
  rescue JSON::ParserError
    nil
  end
end

def zig_ast_check_results(repo, zig_files)
  zig_files.flat_map do |path|
    _stdout, stderr, status = run_capture(repo, "zig", "ast-check", path)
    next [] if status&.success?

    stderr.lines.filter_map do |line|
      next unless line =~ /\A(.+?):(\d+):(\d+):\s+(error|warning):\s+(.+)\z/

      diag_path = repo_relative(Regexp.last_match(1), repo)
      next unless diag_path == path

      lint_result(
        rule_id: "zig.ast-check",
        message: Regexp.last_match(5),
        path: diag_path,
        line: Integer(Regexp.last_match(2)),
        start_column: Integer(Regexp.last_match(3)),
        level: Regexp.last_match(4) == "error" ? "error" : "warning",
        tool: "zig-ast-check"
      )
    end
  end
end

changed = changed_files(repo, options[:base], options[:head])
ruby_files = source_files(repo, changed, "rb")
zig_files = source_files(repo, changed, "zig")

warn "lint ruby files: #{ruby_files.size}"
warn "lint zig files: #{zig_files.size}"
write_sarif(out_dir, "rubocop", "RuboCop", rubocop_results(repo, ruby_files))
write_sarif(out_dir, "clippy", "Clippy", clippy_results(repo, changed))
write_sarif(out_dir, "zig-ast-check", "Zig AST Check", zig_ast_check_results(repo, zig_files))
