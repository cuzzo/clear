#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "open3"
require "optparse"
require "digest"
require "shellwords"
require "set"

TOOL_ROOT = File.expand_path("../../..", __dir__)
LINEAGE_MANIFEST = File.join(TOOL_ROOT, "gems/lineage/Cargo.toml")
DECOMPLEX_MANIFEST = File.join(TOOL_ROOT, "gems/decomplex/Cargo.toml")
FACT_MINE_MANIFEST = File.join(TOOL_ROOT, "gems/fact-mine/Cargo.toml")

DEFAULT_EXCLUDES = %w[
  .git
  .zig-cache
  node_modules
  target
  vendor
].freeze

SOURCE_EXTS = {
  "zig" => :zig,
  "go" => :go,
  "rs" => :rust,
  "c" => :c,
  "h" => :c,
  "cc" => :cpp,
  "cpp" => :cpp,
  "cxx" => :cpp,
  "hh" => :cpp,
  "hpp" => :cpp,
  "cs" => :csharp,
}.freeze

COVERAGE_NAMES = %w[
  .resultset.json
  cobertura.xml
  coverage.xml
  coverage.json
  coverage-final.json
  lcov.info
  coverage.lcov
  coverage.out
  coverage.coverprofile
].freeze

options = {
  repo: ".",
  db: nil,
  out_dir: nil,
  max_commits: nil,
  fresh: false,
  build_tools: true,
  analyzers: true,
  lints: true,
  coverage: true,
  hazards: true,
  sarif_inputs: [],
  coverage_inputs: [],
  host: "127.0.0.1",
  port: 8080,
  serve: false,
  daemon: false,
  replace: true,
  top: 100,
}

OptionParser.new do |parser|
  parser.banner = "Usage: import_repo.rb [options]"
  parser.on("--repo=PATH", "Repository to import. Default: .") { |value| options[:repo] = value }
  parser.on("--db=PATH", "Lineage DB path. Default: REPO/lineage.db") { |value| options[:db] = value }
  parser.on("--out-dir=PATH", "Artifact/log directory. Default: REPO/tmp/lineage-import") { |value| options[:out_dir] = value }
  parser.on("--max-commits=N", Integer, "Cap lineage history while iterating") { |value| options[:max_commits] = value }
  parser.on("--fresh", "Remove the existing DB before import") { options[:fresh] = true }
  parser.on("--no-build-tools", "Do not build Lineage/Decomplex/fact-mine release binaries") { options[:build_tools] = false }
  parser.on("--no-analyzers", "Skip Decomplex/Boobytrap/SlopCop/Nil-Kill/Espalier SARIF generation") { options[:analyzers] = false }
  parser.on("--no-lints", "Skip RuboCop/Clippy/go vet/Zig lint SARIF generation") { options[:lints] = false }
  parser.on("--no-coverage", "Skip coverage discovery/ingestion") { options[:coverage] = false }
  parser.on("--no-hazards", "Skip hazard discovery/ingestion") { options[:hazards] = false }
  parser.on("--coverage=PATH", "Additional coverage artifact. May be repeated") { |value| options[:coverage_inputs] << value }
  parser.on("--sarif-input=PATH", "Additional SARIF file/directory to ingest. May be repeated") { |value| options[:sarif_inputs] << value }
  parser.on("--host=HOST", "UI host if --serve is passed. Default: 127.0.0.1") { |value| options[:host] = value }
  parser.on("--port=PORT", Integer, "UI port if --serve is passed. Default: 8080") { |value| options[:port] = value }
  parser.on("--serve", "Serve the UI after import") { options[:serve] = true }
  parser.on("--daemon", "With --serve, start the UI in the background") { options[:daemon] = true }
  parser.on("--top=N", Integer, "Analyzer report size. Default: 100") { |value| options[:top] = value }
  parser.on("--no-replace", "Do not replace current-commit coverage/SARIF rows") { options[:replace] = false }
end.parse!

def repo_relative(path, repo)
  expanded = File.expand_path(path.to_s.start_with?("/") ? path : File.join(repo, path)).tr("\\", "/")
  root = "#{File.expand_path(repo).tr("\\", "/").chomp("/")}/"
  expanded.start_with?(root) ? expanded[root.length..] : path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
end

def ignored_path?(path)
  path.to_s.tr("\\", "/").split("/").any? { |part| DEFAULT_EXCLUDES.include?(part) }
end

def safe_name(label)
  label.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_").gsub(/\A_+|_+\z/, "")
end

def run_command(label, command, chdir:, log_dir:, optional: false)
  FileUtils.mkdir_p(log_dir)
  stdout_path = File.join(log_dir, "#{safe_name(label)}.stdout")
  stderr_path = File.join(log_dir, "#{safe_name(label)}.stderr")
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  File.write(stdout_path, stdout)
  File.write(stderr_path, stderr)
  if status.success?
    warn "[ok] #{label}"
    return stdout
  end

  message = "[#{optional ? "warn" : "fail"}] #{label} exited #{status.exitstatus}"
  warn message
  warn stderr.lines.first.to_s.strip unless stderr.empty?
  abort message unless optional
  stdout
end

def git_output(repo, *args)
  out, err, status = Open3.capture3("git", *args, chdir: repo)
  abort(err.empty? ? out : err) unless status.success?
  out
end

def git_tracked_files(repo)
  git_output(repo, "ls-files", "-z").split("\0").reject(&:empty?)
end

def source_languages(repo)
  langs = Set.new
  git_tracked_files(repo).each do |path|
    next if ignored_path?(path)

    ext = File.extname(path).delete_prefix(".").downcase
    lang = SOURCE_EXTS[ext]
    langs << lang if lang
  end
  langs
end

def discover_coverage(repo, explicit)
  paths = explicit.map { |path| File.expand_path(path, repo) }
  Find.find(repo) do |path|
    rel = repo_relative(path, repo)
    if File.directory?(path)
      Find.prune if ignored_path?(rel)
      next
    end
    next unless File.file?(path)

    base = File.basename(path)
    next unless COVERAGE_NAMES.include?(base) || base.end_with?(".lcov", ".coverprofile")

    paths << path
  end
  paths.uniq
       .select { |path| File.file?(path) }
       .reject do |path|
         File.basename(path) == "coverage.json" &&
           File.file?(File.join(File.dirname(path), "cobertura.xml"))
       end
end

def coverage_kind(path)
  rel = path.tr("\\", "/")
  return "zig-loom" if rel.include?("coverage-loom")
  return "zig-vopr" if rel.include?("coverage-vopr")
  return "zig-fuzz" if rel.include?("coverage-fuzz")
  return "zig" if rel.include?("zig-out/coverage")
  return "rust" if rel.include?("rust-coverage") || rel.include?("cargo")
  return "ruby" if File.basename(path) == ".resultset.json"
  return "typescript" if rel.end_with?("lcov.info") || rel.end_with?(".lcov") || rel.end_with?("coverage-final.json")
  return "python" if File.basename(path) == "coverage.json"
  return "go" if go_coverprofile?(path)

  "coverage"
end

def go_coverprofile?(path)
  return false unless File.file?(path)

  File.open(path, "r") { |file| file.readline.start_with?("mode:") }
rescue EOFError
  false
end

def coverage_format(path)
  base = File.basename(path)
  return "simplecov" if base == ".resultset.json"
  return "cobertura" if base == "cobertura.xml" || base == "coverage.xml"
  return "codecov" if base == "codecov.json"
  if base == "coverage.json"
    begin
      data = JSON.parse(File.read(path))
      return "generic" if data["files"].is_a?(Hash)
      return "codecov" if data["files"].is_a?(Array)
    rescue JSON::ParserError
      return nil
    end
  end
  return "generic" if base == "coverage-final.json" || base.end_with?(".lcov") || base == "lcov.info" || go_coverprofile?(path)

  nil
end

def analyzer_coverage_compatible?(path, format)
  return true if %w[simplecov cobertura codecov].include?(format)

  base = File.basename(path)
  return true if base == "coverage.json"
  return true if base == "branch-coverage.json" || base == "nil-kill-branch-coverage.json"
  return true if base.end_with?(".jsonl")

  false
end

def tracked_suffix_index(repo)
  files = git_tracked_files(repo)
  index = Hash.new { |hash, key| hash[key] = [] }
  files.each do |file|
    parts = file.split("/")
    parts.each_index do |idx|
      index[parts[idx..].join("/")] << file
    end
  end
  index
end

def resolve_coverage_path(raw_path, repo, suffix_index)
  normalized = raw_path.to_s.tr("\\", "/").sub(%r{\Afile://}, "").sub(%r{\A\./}, "")
  if normalized.start_with?("/")
    rel = repo_relative(normalized, repo)
    return rel if File.file?(File.join(repo, rel))
  end
  return normalized if File.file?(File.join(repo, normalized))

  candidates = suffix_index[normalized]
  return candidates.min_by(&:length) if candidates.any?

  basename_candidates = suffix_index[File.basename(normalized)]
  basename_candidates.min_by(&:length) || normalized
end

def write_generic_coverage(path, out_dir, repo, suffix_index)
  base = File.basename(path)
  if base == "coverage.json"
    data = JSON.parse(File.read(path))
    if data["files"].is_a?(Hash)
      return convert_coverage_py(path, data, out_dir, repo, suffix_index)
    end
  elsif base == "coverage-final.json"
    return convert_istanbul_json(path, JSON.parse(File.read(path)), out_dir, repo, suffix_index)
  elsif base == "lcov.info" || base.end_with?(".lcov")
    return convert_lcov(path, out_dir, repo, suffix_index)
  elsif go_coverprofile?(path)
    return convert_go_coverprofile(path, out_dir, repo, suffix_index)
  end
  path
end

def write_generic_payload(source_path, out_dir, payload)
  FileUtils.mkdir_p(out_dir)
  name = "#{safe_name(File.basename(source_path))}-#{Digest::SHA1.hexdigest(source_path)[0, 10]}"
  output = File.join(out_dir, "#{name}.generic.json")
  File.write(output, JSON.pretty_generate(payload))
  output
end

def file_record(path, hits)
  lines = hits.keys.sort.map { |line| { "line" => line, "hits" => hits[line] } }
  covered = lines.count { |line| line["hits"].positive? }
  coverage = lines.empty? ? nil : (covered * 100.0 / lines.length)
  { "path" => path, "coverage" => coverage, "line_hits" => lines }
end

def convert_coverage_py(path, data, out_dir, repo, suffix_index)
  files = []
  data.fetch("files", {}).each do |raw_path, entry|
    hits = {}
    Array(entry["executed_lines"]).each { |line| hits[Integer(line)] = 1 }
    Array(entry["missing_lines"]).each { |line| hits[Integer(line)] ||= 0 }
    files << file_record(resolve_coverage_path(raw_path, repo, suffix_index), hits) unless hits.empty?
  end
  write_generic_payload(path, out_dir, { "files" => files })
end

def convert_istanbul_json(path, data, out_dir, repo, suffix_index)
  files = []
  data.each do |raw_path, entry|
    statement_map = entry["statementMap"] || {}
    statement_hits = entry["s"] || {}
    line_hits = Hash.new(0)
    statement_map.each do |id, location|
      line = location.dig("start", "line")
      next unless line

      line_hits[Integer(line)] += Integer(statement_hits[id].to_i)
    end
    files << file_record(resolve_coverage_path(raw_path, repo, suffix_index), line_hits) unless line_hits.empty?
  end
  write_generic_payload(path, out_dir, { "files" => files })
end

def convert_lcov(path, out_dir, repo, suffix_index)
  files = []
  current = nil
  hits = {}
  File.readlines(path, chomp: true).each do |line|
    if line.start_with?("SF:")
      current = resolve_coverage_path(line.delete_prefix("SF:"), repo, suffix_index)
      hits = {}
    elsif line.start_with?("DA:") && current
      line_no, count = line.delete_prefix("DA:").split(",", 2)
      hits[Integer(line_no)] = Integer(count.to_i)
    elsif line == "end_of_record" && current
      files << file_record(current, hits) unless hits.empty?
      current = nil
      hits = {}
    end
  end
  files << file_record(current, hits) if current && !hits.empty?
  write_generic_payload(path, out_dir, { "files" => files })
end

def convert_go_coverprofile(path, out_dir, repo, suffix_index)
  by_file = Hash.new { |hash, key| hash[key] = Hash.new(0) }
  File.readlines(path, chomp: true).each do |line|
    next if line.start_with?("mode:") || line.strip.empty?

    if line =~ /\A(.+?):(\d+)\.\d+,(\d+)\.\d+\s+\d+\s+(\d+)\z/
      file = resolve_coverage_path(Regexp.last_match(1), repo, suffix_index)
      start_line = Integer(Regexp.last_match(2))
      end_line = Integer(Regexp.last_match(3))
      count = Integer(Regexp.last_match(4))
      (start_line..end_line).each { |line_no| by_file[file][line_no] = [by_file[file][line_no], count].max }
    end
  end
  files = by_file.map { |file, hits| file_record(file, hits) }
  write_generic_payload(path, out_dir, { "files" => files })
end

repo = File.realpath(options[:repo])
db = File.expand_path(options[:db] || File.join(repo, "lineage.db"), repo)
out_dir = File.expand_path(options[:out_dir] || File.join(repo, "tmp/lineage-import"), repo)
log_dir = File.join(out_dir, "logs")
sarif_dir = File.join(out_dir, "sarif")
coverage_dir = File.join(out_dir, "coverage-normalized")
lineage_bin = File.join(TOOL_ROOT, "gems/lineage/target/release/lineage")
decomplex_bin = File.join(TOOL_ROOT, "gems/decomplex/target/release/decomplex-rust")
fact_mine_bin = File.join(TOOL_ROOT, "gems/fact-mine/target/release/fact-mine-rust")

FileUtils.mkdir_p(out_dir)
FileUtils.rm_f(db) if options[:fresh]

if options[:build_tools]
  run_command("build-lineage", ["cargo", "build", "--release", "--manifest-path", LINEAGE_MANIFEST], chdir: TOOL_ROOT, log_dir: log_dir)
  if options[:analyzers]
    run_command("build-decomplex", ["cargo", "build", "--release", "--manifest-path", DECOMPLEX_MANIFEST], chdir: TOOL_ROOT, log_dir: log_dir)
    run_command("build-fact-mine", ["cargo", "build", "--release", "--manifest-path", FACT_MINE_MANIFEST], chdir: TOOL_ROOT, log_dir: log_dir, optional: true)
  end
end

commit = git_output(repo, "rev-parse", "HEAD").strip
build_cmd = [lineage_bin, "build", "--repo", repo, "--db", db]
build_cmd += ["--max-commits", options[:max_commits].to_s] if options[:max_commits]
run_command("lineage-build", build_cmd, chdir: repo, log_dir: log_dir)

analyzer_coverage_paths = []
if options[:coverage]
  suffix_index = tracked_suffix_index(repo)
  discovered = discover_coverage(repo, options[:coverage_inputs])
  discovered.each do |path|
    format = coverage_format(path)
    next unless format

    input = format == "generic" ? write_generic_coverage(path, coverage_dir, repo, suffix_index) : path
    rel = repo_relative(path, repo)
    type = coverage_kind(path)
    test_id = "#{type}:#{rel}"
    cmd = [
      lineage_bin, "ingest-coverage",
      "--db", db,
      "--repo", repo,
      "--input", input,
      "--format", format,
      "--commit", commit,
      "--test-type", type,
      "--test-id", test_id,
    ]
    cmd << "--replace" if options[:replace]
    run_command("coverage-#{rel}", cmd, chdir: repo, log_dir: log_dir, optional: true)
    analyzer_coverage_paths << path if analyzer_coverage_compatible?(path, format)
  end
end

langs = source_languages(repo)
if options[:hazards]
  provider_by_lang = {
    zig: "zig",
    go: "go",
    rust: "rust",
    c: "c",
    cpp: "cpp",
    csharp: "csharp",
  }
  provider_by_lang.each do |lang, provider|
    next unless langs.include?(lang)

    cmd = [lineage_bin, "ingest-hazards", "--db", db, "--repo", repo, "--provider", provider, "--commit", commit]
    run_command("hazards-#{provider}", cmd, chdir: repo, log_dir: log_dir, optional: true)
  end
end

if options[:analyzers]
  first_party_dir = File.join(sarif_dir, "first-party")
  cmd = [
    "ruby", File.join(TOOL_ROOT, "tools/generate_generalized_gem_sarif.rb"),
    "--repo", repo,
    "--out-dir", first_party_dir,
    "--top", options[:top].to_s,
    "--decomplex-binary", decomplex_bin,
  ]
  cmd += ["--coverage", analyzer_coverage_paths.join(File::PATH_SEPARATOR)] unless analyzer_coverage_paths.empty?
  ENV["FACT_MINE_RUST_BINARY"] = fact_mine_bin
  run_command("first-party-sarif", cmd, chdir: TOOL_ROOT, log_dir: log_dir, optional: true)
  ingest = [lineage_bin, "ingest-sarif", "--db", db, "--repo", repo, "--input", first_party_dir, "--source", "first-party", "--commit", commit]
  ingest << "--replace" if options[:replace]
  run_command("ingest-first-party-sarif", ingest, chdir: repo, log_dir: log_dir, optional: true)
end

if options[:lints]
  lint_dir = File.join(sarif_dir, "lint")
  cmd = ["ruby", File.join(TOOL_ROOT, "tools/generate_lint_sarif.rb"), "--repo", repo, "--out-dir", lint_dir]
  run_command("lint-sarif", cmd, chdir: TOOL_ROOT, log_dir: log_dir, optional: true)
  ingest = [lineage_bin, "ingest-sarif", "--db", db, "--repo", repo, "--input", lint_dir, "--source", "lint", "--commit", commit]
  ingest << "--replace" if options[:replace]
  run_command("ingest-lint-sarif", ingest, chdir: repo, log_dir: log_dir, optional: true)
end

options[:sarif_inputs].each do |input|
  input = File.expand_path(input, repo)
  next unless File.exist?(input)

  ingest = [lineage_bin, "ingest-sarif", "--db", db, "--repo", repo, "--input", input, "--source", "external", "--commit", commit]
  ingest << "--replace" if options[:replace]
  run_command("ingest-extra-sarif-#{File.basename(input)}", ingest, chdir: repo, log_dir: log_dir, optional: true)
end

run_command("refresh-ui", [lineage_bin, "refresh-ui", "--db", db], chdir: repo, log_dir: log_dir)

puts "Lineage import complete"
puts "  repo: #{repo}"
puts "  db: #{db}"
puts "  artifacts: #{out_dir}"
puts "  commit: #{commit}"

if options[:serve]
  cmd = [lineage_bin, "ui", "--db", db, "--repo", repo, "--host", options[:host], "--port", options[:port].to_s]
  if options[:daemon]
    ui_log = File.join(log_dir, "lineage-ui.log")
    pid = Process.spawn(*cmd, out: ui_log, err: ui_log, chdir: repo, pgroup: true)
    File.write(File.join(out_dir, "lineage-ui.pid"), "#{pid}\n")
    puts "  ui: http://#{options[:host]}:#{options[:port]} (pid #{pid})"
  else
    warn "Serving Lineage UI on #{options[:host]}:#{options[:port]}"
    exec(*cmd, chdir: repo)
  end
end
