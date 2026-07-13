#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require_relative "sarif_result_cap"

ROOT = File.expand_path("..", __dir__)
DECOMPLEX_SARIF_MAX_RESULTS = Integer(ENV.fetch("DECOMPLEX_CI_SARIF_MAX_RESULTS", "1000"))
LOCAL_RUBY_LOAD_PATHS = %w[
  gems/boobytrap/lib
  gems/slopcop/lib
  gems/espalier/lib
  gems/nil-kill/lib
].map { |path| File.join(ROOT, path) }.freeze

LOCAL_RUBY_LOAD_PATHS.reverse_each { |path| $LOAD_PATH.unshift(path) }
existing_rubylib = ENV.fetch("RUBYLIB", "").split(File::PATH_SEPARATOR).reject(&:empty?)
ENV["RUBYLIB"] = (LOCAL_RUBY_LOAD_PATHS + existing_rubylib).uniq.join(File::PATH_SEPARATOR)

SUPPORTED_TOOLS = %w[decomplex boobytrap slopcop espalier nil-kill].freeze

options = {
  repo: ".",
  head: "HEAD",
  out_dir: "tmp/generalized-gems-sarif",
  coverage: [],
  exclude: [],
  top: 50,
  decomplex_binary: nil,
  only: [],
}

OptionParser.new do |parser|
  parser.banner = "Usage: generate_generalized_gem_sarif.rb [--base=REF] [options]"
  parser.on("--repo=PATH") { |value| options[:repo] = value }
  parser.on("--base=REF") { |value| options[:base] = value }
  parser.on("--head=REF") { |value| options[:head] = value }
  parser.on("--coverage=PATH") { |value| options[:coverage] << value }
  parser.on("--out-dir=PATH") { |value| options[:out_dir] = value }
  parser.on("--top=N", Integer) { |value| options[:top] = value }
  parser.on("--exclude=GLOB") { |value| options[:exclude] << value }
  parser.on("--decomplex-binary=PATH") { |value| options[:decomplex_binary] = value }
  parser.on("--only=TOOL", SUPPORTED_TOOLS, "Generate only one report (repeatable)") do |value|
    options[:only] << value
  end
end.parse!

selected_tools = options[:only].empty? ? SUPPORTED_TOOLS : options[:only].uniq

require "nil_kill/sarif"
require "slopcop" if selected_tools.include?("slopcop")
if (selected_tools & %w[espalier nil-kill]).any?
  require "espalier" if selected_tools.include?("espalier")
  require "nil_kill"
end

repo = File.realpath(options[:repo])
out_dir = File.expand_path(options[:out_dir])
FileUtils.mkdir_p(out_dir)

SUPPORTED_SOURCE_EXTENSIONS = %w[
  c cc cpp cs cxx go h hh hpp java js jsx kt kts lua m py rb rs swift ts tsx zig
].freeze

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

def repo_relative(path, repo)
  expanded = File.expand_path(path.to_s.start_with?("/") ? path : File.join(repo, path)).tr("\\", "/")
  root = "#{File.expand_path(repo).tr("\\", "/").chomp("/")}/"
  expanded.start_with?(root) ? expanded[root.length..] : path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
end

def changed_files(repo, base, head)
  return nil if base.nil? || base.empty?

  out, status = Open3.capture2e(
    "git", "-C", repo, "diff", "--name-only", "--diff-filter=ACMRT",
    "#{base}...#{head}"
  )
  abort out unless status.success?

  out.lines.map(&:strip).reject(&:empty?)
end

def git_tracked_files(repo)
  out, status = Open3.capture2e("git", "-C", repo, "ls-files", "-z")
  abort out unless status.success?

  out.split("\0").reject(&:empty?)
end

def ignored_path?(path, exclude)
  normalized = path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
  components = normalized.split("/")
  return true if components.any? { |component| IGNORED_COMPONENTS.include?(component) || component.start_with?("nil-kill-") }

  exclude.any? do |pattern|
    pattern = pattern.tr("\\", "/")
    if pattern.end_with?("/**")
      prefix = pattern.delete_suffix("/**").delete_prefix("**/")
      normalized == prefix || normalized.start_with?("#{prefix}/") || normalized.include?("/#{prefix}/")
    else
      normalized == pattern || normalized.start_with?("#{pattern}/") || normalized.include?(pattern)
    end
  end
end

def source_files(repo, files, exclude)
  candidates = files || git_tracked_files(repo)
  candidates.map { |path| repo_relative(path, repo) }
            .select do |path|
              ext = File.extname(path).delete_prefix(".").downcase
              SUPPORTED_SOURCE_EXTENSIONS.include?(ext) &&
                !ignored_path?(path, exclude) &&
                File.file?(File.join(repo, path))
            end
            .uniq
            .sort
end

def write(path, body)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, body)
  warn "wrote #{path}"
end

def cap_sarif_results(path, max_results)
  return unless max_results&.positive?

  sarif = JSON.parse(File.read(path))
  run = sarif.fetch("runs").first
  results = run["results"]
  return unless results.is_a?(Array) && results.size > max_results

  original_count = results.size
  retained, selection = SarifResultCap.select(results, max_results)
  run["results"] = retained
  properties = run["properties"] ||= {}
  properties["decomplex.sarif_results_original_count"] = original_count
  properties["decomplex.sarif_results_limit"] = max_results
  properties["decomplex.sarif_results_truncated_count"] = original_count - max_results
  properties["decomplex.sarif_results_original_by_rule"] = selection.fetch("original_by_rule")
  properties["decomplex.sarif_results_retained_by_rule"] = selection.fetch("retained_by_rule")
  properties["decomplex.sarif_results_truncated_by_rule"] = selection.fetch("truncated_by_rule")
  File.write(path, JSON.pretty_generate(sarif))
  warn "truncated #{path} results from #{original_count} to #{max_results}"
end

def empty_sarif(tool_name, format)
  JSON.pretty_generate(
    NilKill::Sarif.document(
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

def run_decomplex_rust(binary, files, out_dir, repo)
  sarif_out = File.join(out_dir, "decomplex.sarif")
  md_out = File.join(out_dir, "decomplex.md")

  ok = system(binary, "report", "--format", "sarif", "--output", sarif_out, "--vcs=git", *files, chdir: repo)
  abort "decomplex-rust report --format sarif failed" unless ok
  cap_sarif_results(sarif_out, DECOMPLEX_SARIF_MAX_RESULTS)

  ok = system(binary, "report", "--format", "markdown", "--output", md_out, "--vcs=git", *files, chdir: repo)
  abort "decomplex-rust report --format markdown failed" unless ok

  warn "wrote #{sarif_out}"
  warn "wrote #{md_out}"
end

def build_espalier_manifest(files, repo, nil_kill_evidence = nil)
  evidence = Espalier::StaticEvidence.build(files, root: repo)
  modules = Espalier::StaticEvidence.project_modules(evidence)
  if nil_kill_evidence
    static_data = nil_kill_evidence["static"] || {}
    wrapped_data = FactMine::Syntax::TypeExpr.wrap_types!(static_data)
    espalier_nk = Espalier::NilKillEvidence.new(wrapped_data)
    espalier_nk.apply!(modules)
    aggregator = Espalier::Aggregator.new(
      nil_kill_data: espalier_nk.method_signatures,
      nil_kill_loops: espalier_nk.loop_counts,
      nil_kill_evidence: espalier_nk
    )
    aggregator.aggregate(modules)
  else
    Espalier::Aggregator.new.aggregate(modules)
  end
end


def build_nil_kill_evidence(files, repo)
  static = NilKill::StaticEvidence.build(files, root: repo)
  NilKill::Schema::EvidenceBundle.build(
    root: repo,
    static: static,
    runtime: nil,
    actions: [],
    diagnostics: [],
    metadata: {
      "source" => "tools/generate_generalized_gem_sarif.rb",
      "mode" => "static-only"
    }
  )
end

coverage_paths = options[:coverage].flat_map { |entry| entry.split(File::PATH_SEPARATOR) }
                                  .map(&:strip)
                                  .reject(&:empty?)
                                  .select { |path| File.file?(path) || File.directory?(path) }
coverage = coverage_paths.empty? ? nil : coverage_paths.join(File::PATH_SEPARATOR)

changed = changed_files(repo, options[:base], options[:head])
rel_files = source_files(repo, changed, options[:exclude])

scope_label = changed ? "changed" : "tracked"
warn "#{scope_label} supported source files: #{rel_files.size}"
if ENV["LINEAGE_VERBOSE_FILES"] == "1"
  rel_files.each { |path| warn "  #{path}" }
elsif changed
  warn "set LINEAGE_VERBOSE_FILES=1 to print scoped source file paths"
end

if rel_files.empty?
  {
    "decomplex" => ["Decomplex", "decomplex.report.sarif.v1"],
    "boobytrap" => ["Boobytrap", "boobytrap.report.sarif.v1"],
    "slopcop" => ["SlopCop", "slopcop.report.sarif.v1"],
    "espalier" => ["Espalier", "espalier.manifest.sarif.v1"],
    "nil-kill" => ["Nil-Kill", "nil-kill.report.sarif.v1"],
  }.each do |tool, (name, format)|
    next unless selected_tools.include?(tool)

    write(File.join(out_dir, "#{tool}.sarif"), empty_sarif(name, format))
    write(File.join(out_dir, "#{tool}.md"), empty_markdown(name))
  end
  exit 0
end

previous_parser = ENV["DECOMPLEX_PARSER"]
ENV["DECOMPLEX_PARSER"] = "tree_sitter"

fact_mine_temp = nil
churn_temp = nil

begin
  if (selected_tools & %w[espalier nil-kill]).any? &&
      (!ENV["FACT_MINE_FACTS_FILE"] || ENV["FACT_MINE_FACTS_FILE"].empty?)
    fact_mine_bin = ENV.fetch("FACT_MINE_RUST_BINARY", File.expand_path("gems/fact-mine/target/release/fact-mine-rust", ROOT))
    if File.executable?(fact_mine_bin)
      require "tempfile"
      fact_mine_temp = Tempfile.new(["fact-mine-facts", ".json"])
      fact_mine_temp.close
      warn "Pre-computing fact-mine static facts..."
      ok = system(fact_mine_bin, "profile", "nil-kill", "--output", fact_mine_temp.path, *rel_files, chdir: repo)
      if ok
        ENV["FACT_MINE_FACTS_FILE"] = fact_mine_temp.path
      else
        warn "Pre-computing fact-mine-rust facts failed"
      end
    end
  end

  if selected_tools.include?("decomplex")
    decomplex_bin = options[:decomplex_binary] || File.join(ROOT, "gems/decomplex/target/release/decomplex-rust")
    if File.executable?(decomplex_bin)
      run_decomplex_rust(decomplex_bin, rel_files, out_dir, repo)
    else
      abort "decomplex-rust binary not found at #{decomplex_bin}. Please build it or pass --decomplex-binary"
    end
  end

  boobytrap_bin = File.join(ROOT, "gems/boobytrap/exe/boobytrap")
  go_coverage = coverage_paths.find { |p| p.end_with?("coverage.out") } || coverage_paths.first
  if selected_tools.include?("boobytrap")
    args = ["report", "--repo=#{repo}", "--output=#{File.join(out_dir, "boobytrap.md")}", "--json=#{File.join(out_dir, "boobytrap.sarif")}", "--top=#{options[:top]}"]
    # The report subcommand otherwise defaults to coverage/.resultset.json.
    # An explicitly empty value is Boobytrap's supported no-coverage mode.
    args << "--coverage=#{go_coverage}"
    options[:exclude].each { |e| args << "--exclude=#{e}" }
    unless system(boobytrap_bin, *args)
      abort "Failed to execute boobytrap: #{boobytrap_bin} #{args.join(' ')}"
    end
  end

  if selected_tools.include?("slopcop")
    # Share Boobytrap's computed churn output with SlopCop to avoid re-deriving it.
    helper_args = ["--repo=#{repo}"]
    helper_args << "--coverage=#{go_coverage}" if go_coverage
    out, status = Open3.capture2(boobytrap_bin, *helper_args)
    unless status.success?
      abort "Failed to execute boobytrap helper: #{boobytrap_bin} #{helper_args.join(' ')}\nOutput:\n#{out}"
    end
    fix_scores = (JSON.parse(out)["fix_scores"] || {})

    require "tempfile"
    churn_temp = Tempfile.new(["boobytrap-churn", ".json"])
    churn_temp.write(JSON.generate(fix_scores))
    churn_temp.close
    ENV["BOOBYTRAP_CHURN_FILE"] = churn_temp.path

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
  end

  if (selected_tools & %w[espalier nil-kill]).any?
    Dir.chdir(repo) do
      nil_kill_evidence = build_nil_kill_evidence(rel_files, repo)
      if selected_tools.include?("espalier")
        manifest = build_espalier_manifest(rel_files, repo, nil_kill_evidence)
        write(File.join(out_dir, "espalier.sarif"), Espalier::Formatter.to_sarif(manifest))
        write(
          File.join(out_dir, "espalier.md"),
          Espalier::Reporter.new(manifest, root: repo, link_base: out_dir).to_markdown
        )
      end

      if selected_tools.include?("nil-kill")
        nil_kill_report = NilKill::Report.new(["--format", "sarif"], evidence: nil_kill_evidence)
        write(File.join(out_dir, "nil-kill.sarif"), nil_kill_report.to_sarif(nil_kill_evidence))
        write(
          File.join(out_dir, "nil-kill.md"),
          NilKill::Reporting::MultiLanguageReport.new(nil_kill_evidence).lines.join("\n") + "\n"
        )
      end
    end
  end
ensure
  previous_parser.nil? ? ENV.delete("DECOMPLEX_PARSER") : ENV["DECOMPLEX_PARSER"] = previous_parser
  if fact_mine_temp
    ENV.delete("FACT_MINE_FACTS_FILE")
    fact_mine_temp.unlink
  end
  if churn_temp
    ENV.delete("BOOBYTRAP_CHURN_FILE")
    churn_temp.unlink
  end
end
