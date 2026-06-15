#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"

ROOT = File.expand_path("..", __dir__)
DECOMPLEX_SARIF_MAX_RESULTS = Integer(ENV.fetch("DECOMPLEX_CI_SARIF_MAX_RESULTS", "1000"))
$LOAD_PATH.unshift(File.join(ROOT, "gems/decomplex/lib"))
$LOAD_PATH.unshift(File.join(ROOT, "gems/boobytrap/lib"))
$LOAD_PATH.unshift(File.join(ROOT, "gems/slopcop/lib"))

require "decomplex/report"
require "decomplex/source_filter"
require "decomplex/sarif"
require "boobytrap"
require "slopcop"

options = {
  repo: ".",
  head: "HEAD",
  out_dir: "tmp/generalized-gems-sarif",
  coverage: [],
  exclude: [],
  top: 50
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate_generalized_gem_sarif.rb --base=REF [options]"
  parser.on("--repo=PATH") { |value| options[:repo] = value }
  parser.on("--base=REF") { |value| options[:base] = value }
  parser.on("--head=REF") { |value| options[:head] = value }
  parser.on("--coverage=PATH") { |value| options[:coverage] << value }
  parser.on("--out-dir=PATH") { |value| options[:out_dir] = value }
  parser.on("--top=N", Integer) { |value| options[:top] = value }
  parser.on("--exclude=GLOB") { |value| options[:exclude] << value }
end.parse!

abort "--base is required" unless options[:base]

repo = File.realpath(options[:repo])
out_dir = File.expand_path(options[:out_dir])
FileUtils.mkdir_p(out_dir)

def repo_relative(path, repo)
  expanded = File.expand_path(path.to_s.start_with?("/") ? path : File.join(repo, path)).tr("\\", "/")
  root = "#{File.expand_path(repo).tr("\\", "/").chomp("/")}/"
  expanded.start_with?(root) ? expanded[root.length..] : path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
end

def changed_files(repo, base, head)
  out, status = Open3.capture2e(
    "git", "-C", repo, "diff", "--name-only", "--diff-filter=ACMRT",
    "#{base}...#{head}"
  )
  abort out unless status.success?

  out.lines.map(&:strip).reject(&:empty?)
end

def source_files(repo, files, exclude)
  Decomplex::SourceFilter.collect(
    files,
    parser: "tree_sitter",
    root: repo,
    exclude: exclude
  ).map { |path| repo_relative(path, repo) }
   .select { |path| File.file?(File.join(repo, path)) }
   .uniq
   .sort
end

def write(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
  warn "wrote #{path}"
end

def empty_sarif(tool_name, format)
  JSON.pretty_generate(
    Decomplex::Sarif.document(
      tool_name: tool_name,
      information_uri: "https://github.com/codeforreno/litedb",
      rules: [],
      results: [],
      properties: {
        "format" => format,
        "reason" => "no_changed_tree_sitter_source_files"
      }
    )
  )
end

def empty_markdown(tool_name)
  "# #{tool_name} Report\n\n_No changed Tree-sitter-supported source files in this PR._\n"
end

coverage_paths = options[:coverage].flat_map { |entry| entry.split(File::PATH_SEPARATOR) }
                                  .map(&:strip)
                                  .reject(&:empty?)
                                  .select { |path| File.file?(path) || File.directory?(path) }
coverage = coverage_paths.empty? ? nil : coverage_paths.join(File::PATH_SEPARATOR)

changed = changed_files(repo, options[:base], options[:head])
rel_files = source_files(repo, changed, options[:exclude])

warn "changed supported source files: #{rel_files.size}"
rel_files.each { |path| warn "  #{path}" }

if rel_files.empty?
  write(File.join(out_dir, "decomplex.sarif"), empty_sarif("Decomplex", "decomplex.report.sarif.v1"))
  write(File.join(out_dir, "decomplex.md"), empty_markdown("Decomplex"))
  write(File.join(out_dir, "boobytrap.sarif"), empty_sarif("Boobytrap", "boobytrap.report.sarif.v1"))
  write(File.join(out_dir, "boobytrap.md"), empty_markdown("Boobytrap"))
  write(File.join(out_dir, "slopcop.sarif"), empty_sarif("SlopCop", "slopcop.report.sarif.v1"))
  write(File.join(out_dir, "slopcop.md"), empty_markdown("SlopCop"))
  exit 0
end

previous_parser = ENV["DECOMPLEX_PARSER"]
ENV["DECOMPLEX_PARSER"] = "tree_sitter"

begin
  Dir.chdir(repo) do
    decomplex = Decomplex::Report.new(rel_files)
    write(
      File.join(out_dir, "decomplex.sarif"),
      decomplex.to_sarif(
        include_snapshot: false,
        include_finding_payload: false,
        max_results: DECOMPLEX_SARIF_MAX_RESULTS
      )
    )
    write(File.join(out_dir, "decomplex.md"), decomplex.to_markdown)
  end

  boobytrap = Boobytrap::Report.new(
    repo: repo,
    resultset: coverage,
    files: rel_files,
    top: options[:top],
    exclude: options[:exclude]
  )
  write(File.join(out_dir, "boobytrap.sarif"), boobytrap.to_sarif)
  write(File.join(out_dir, "boobytrap.md"), boobytrap.to_markdown)

  slopcop = SlopCop::Report.new(
    files: rel_files,
    repo: repo,
    resultset: coverage,
    top: options[:top],
    exclude: options[:exclude],
    link_base: out_dir
  )
  write(File.join(out_dir, "slopcop.sarif"), slopcop.to_json)
  write(File.join(out_dir, "slopcop.md"), slopcop.to_markdown)
ensure
  previous_parser.nil? ? ENV.delete("DECOMPLEX_PARSER") : ENV["DECOMPLEX_PARSER"] = previous_parser
end
