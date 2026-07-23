#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "set"

ROOT = File.expand_path("..", __dir__)
LOCAL_RUBY_LOAD_PATHS = [File.join(ROOT, "gems/nil-kill/lib")].freeze
LOCAL_RUBY_LOAD_PATHS.reverse_each { |path| $LOAD_PATH.unshift(path) }
existing_rubylib = ENV.fetch("RUBYLIB", "").split(File::PATH_SEPARATOR).reject(&:empty?)
ENV["RUBYLIB"] = (LOCAL_RUBY_LOAD_PATHS + existing_rubylib).uniq.join(File::PATH_SEPARATOR)
require "nil_kill/sarif"

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
RUST_LINTS = %w[
  clippy::correctness
  clippy::suspicious
  clippy::perf
  clippy::complexity
].freeze

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

def tracked_files(repo)
  out, err, status = run_capture(repo, "git", "ls-files", "-z")
  abort(err.empty? ? out : err) unless status&.success?

  out.split("\0").reject(&:empty?)
end

def command_available?(repo, command)
  _out, _err, status = run_capture(repo, "sh", "-c", "command -v #{command} >/dev/null 2>&1")
  status&.success?
end

def source_files(repo, changed, extension)
  files = changed || all_files(repo, extension)
  files.select do |path|
    path.end_with?(".#{extension}") &&
      !ignored_path?(path) &&
      File.file?(File.join(repo, path))
  end.sort.uniq
end

def cargo_manifests(repo)
  tracked_files(repo)
    .select { |path| File.basename(path) == "Cargo.toml" }
    .reject { |path| ignored_path?(path) }
    .select { |path| File.file?(File.join(repo, path)) }
    .sort
end

def go_modules(repo)
  tracked_files(repo)
    .select { |path| File.basename(path) == "go.mod" }
    .reject { |path| ignored_path?(path) }
    .select { |path| File.file?(File.join(repo, path)) }
    .sort
end

def sarif_document(tool_name, results)
  results_by_rule = results.group_by { |result| result.fetch("ruleId") }
  rules = results_by_rule.keys.sort.map do |rule_id|
    first_result = results_by_rule.fetch(rule_id).first || {}
    NilKill::Sarif.rule(
      id: rule_id,
      name: rule_id,
      short_description: rule_id,
      default_level: first_result.fetch("level", "warning"),
      properties: {
        "category" => "lint",
        "precision" => "medium"
      }
    )
  end

  JSON.pretty_generate(
    NilKill::Sarif.document(
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
  NilKill::Sarif.result(
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

  commands = []
  # A Lineage profile may lint a subproject whose Gemfile lives at a
  # monorepo ancestor. Bundler's explicit BUNDLE_GEMFILE is authoritative for
  # that profile, so do not silently drop RuboCop merely because the selected
  # source root itself has no Gemfile.
  bundled_project = File.file?(File.join(repo, "Gemfile")) || !ENV.fetch("BUNDLE_GEMFILE", "").empty?
  commands << ["bundle", "exec", "rubocop"] if bundled_project && command_available?(repo, "bundle")
  commands << ["rubocop"] if command_available?(repo, "rubocop")
  commands.uniq!
  if commands.empty?
    warn "rubocop not found; writing empty Ruby lint SARIF"
    return []
  end

  config = if File.file?(File.join(repo, "tools/lint/rubocop_lineage.yml"))
             File.join(repo, "tools/lint/rubocop_lineage.yml")
           elsif File.file?(File.join(ROOT, "tools/lint/rubocop_lineage.yml"))
             File.join(ROOT, "tools/lint/rubocop_lineage.yml")
           end

  commands.each do |command|
    args = [
      *command,
      "--format", "json",
      "--force-exclusion"
    ]
    args += ["--config", config] if config
    args += ruby_files
    stdout, stderr, status = run_capture(repo, *args)
    warn stderr unless stderr.empty?
    if stdout.strip.empty?
      warn "rubocop #{command.join(' ')} exited #{status&.exitstatus}" if status && !status.success?
      next
    end

    data = JSON.parse(stdout)
    return data.fetch("files", []).flat_map do |file|
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
    warn "could not parse RuboCop JSON from #{command.join(' ')}: #{e.message}"
  end

  warn "rubocop produced no parseable JSON; writing empty Ruby lint SARIF"
  []
end

def clippy_results(repo, manifests, changed)
  return [] if manifests.empty?
  unless command_available?(repo, "cargo")
    warn "cargo not found; writing empty Rust lint SARIF"
    return []
  end

  changed_set = changed&.to_set
  manifests.flat_map do |manifest|
    stdout, stderr, status = run_capture(
      repo,
      "cargo", "clippy",
      "--manifest-path", manifest,
      "--all-targets",
      "--all-features",
      "--message-format=json",
      "--",
      *RUST_LINTS.flat_map { |lint| ["-W", lint] }
    )
    warn stderr unless stderr.empty?
    warn "clippy #{manifest} exited #{status&.exitstatus}" if status && !status.success?

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
        tool: "clippy",
        extra: { "manifest" => manifest }
      )
    rescue JSON::ParserError
      nil
    end
  end
end

def go_vet_results(repo, modules, changed)
  return [] if modules.empty?
  unless command_available?(repo, "go")
    warn "go not found; writing empty Go lint SARIF"
    return []
  end

  changed_set = changed&.to_set
  modules.flat_map do |mod|
    dir = File.dirname(File.join(repo, mod))
    stdout, stderr, status = Open3.capture3("go", "vet", "./...", chdir: dir)
    warn stderr unless stderr.empty?
    warn "go vet #{mod} exited #{status&.exitstatus}" if status && !status.success?

    combined = [stdout, stderr].join("\n")
    current_package = nil
    combined.lines.filter_map do |raw|
      line = raw.strip
      next if line.empty? || line.start_with?("go: downloading")
      if line.start_with?("# ")
        current_package = line.delete_prefix("# ").strip
        next
      end

      if line =~ /\A(.+?):(\d+):(\d+):\s+(.+)\z/
        path = Regexp.last_match(1)
        path = File.expand_path(path, dir) unless path.start_with?("/")
        path = repo_relative(path, repo)
        next if changed_set && !changed_set.include?(path)

        lint_result(
          rule_id: "go-vet",
          message: Regexp.last_match(4),
          path: path,
          line: Integer(Regexp.last_match(2)),
          start_column: Integer(Regexp.last_match(3)),
          level: "warning",
          tool: "go-vet",
          extra: { "module" => mod }
        )
      elsif line =~ /\A(.+?):(\d+):\s+(.+)\z/
        path = Regexp.last_match(1)
        path = File.expand_path(path, dir) unless path.start_with?("/")
        path = repo_relative(path, repo)
        next if changed_set && !changed_set.include?(path)

        lint_result(
          rule_id: "go-vet",
          message: Regexp.last_match(3),
          path: path,
          line: Integer(Regexp.last_match(2)),
          level: "warning",
          tool: "go-vet",
          extra: { "module" => mod }
        )
      elsif status && !status.success?
        module_path = repo_relative(File.join(dir, "go.mod"), repo)
        next if changed_set && !changed_set.include?(module_path)

        lint_result(
          rule_id: "go-vet.module-error",
          message: [current_package, line].compact.join(": "),
          path: module_path,
          line: 1,
          level: "error",
          tool: "go-vet",
          extra: { "module" => mod }
        )
      end
    end
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
manifests = cargo_manifests(repo)
modules = go_modules(repo)

warn "lint ruby files: #{ruby_files.size}"
warn "lint zig files: #{zig_files.size}"
warn "lint cargo manifests: #{manifests.size}"
warn "lint go modules: #{modules.size}"
write_sarif(out_dir, "rubocop", "RuboCop", rubocop_results(repo, ruby_files))
write_sarif(out_dir, "clippy", "Clippy", clippy_results(repo, manifests, changed))
write_sarif(out_dir, "go-vet", "Go Vet", go_vet_results(repo, modules, changed))
write_sarif(out_dir, "zig-ast-check", "Zig AST Check", zig_ast_check_results(repo, zig_files))
