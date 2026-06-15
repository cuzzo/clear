#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "rexml/document"
require "set"

ROOT = File.expand_path("..", __dir__)
require_relative "../gems/nil-kill/lib/nil_kill"
require_relative "loom_atomic_coverage"
require_relative "src_ast_walk_guardrail"
require_relative "vopr_coverage"
require_relative "wait_loop_coverage"

def sh(*args)
  IO.popen(args, chdir: ROOT, err: [:child, :out], &:read)
end

def sh_quiet(*args)
  IO.popen(args, chdir: ROOT, err: File::NULL, &:read)
end

def parse_options(argv)
  options = {
    format: "text",
    src_visibility: false,
    src_visibility_only: false,
    src_visibility_path: "src",
  }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby tools/diff_bucket_summary.rb [BASE] [--format text|markdown] [--src-visibility]"
    parser.on("--format FORMAT", %w[text markdown], "Output format") { |value| options[:format] = value }
    parser.on("--src-visibility", "Append src/**/*.rb public/private/OTHER code-line breakdown") do
      options[:src_visibility] = true
    end
    parser.on("--src-visibility-only", "Print only the src/**/*.rb public/private/OTHER code-line breakdown") do
      options[:src_visibility] = true
      options[:src_visibility_only] = true
    end
    parser.on("--src-visibility-path PATH", "Directory to scan for --src-visibility (default: src)") do |value|
      options[:src_visibility] = true
      options[:src_visibility_path] = value
    end
  end.parse!(argv)
  options[:base] = argv.shift
  abort "unexpected arguments: #{argv.join(" ")}" unless argv.empty?
  options
end

def default_base_ref
  system("git", "rev-parse", "--verify", "origin/master", out: File::NULL, err: File::NULL) ? "origin/master" : "master"
end

def numstat(base)
  sh("git", "diff", "--numstat", "#{base}...HEAD").lines.filter_map do |line|
    add, del, path = line.chomp.split("\t", 3)
    next unless path

    {
      path: path,
      additions: add == "-" ? 0 : add.to_i,
      deletions: del == "-" ? 0 : del.to_i,
    }
  end
end

def diff_base_commit(base)
  commit = sh_quiet("git", "merge-base", base, "HEAD").strip
  commit.empty? ? base : commit
end

def zig_test_or_harness_file?(path)
  return false unless path.start_with?("zig/") && path.end_with?(".zig")

  name = File.basename(path)
  name.end_with?("-test.zig", "-vopr.zig", "-loom.zig") ||
    name.start_with?("vopr-", "loom-")
end

def bucket_for(path)
  return :src_rb if path.start_with?("src/") && path.end_with?(".rb")
  return :zig_tests if zig_test_or_harness_file?(path)
  return :zig_src if path.start_with?("zig/") && path.end_with?(".zig")
  return :spec if path.start_with?("spec/")
  return :transpile_tests if path.start_with?("transpile-tests/")
  return :tools if path.start_with?("tools/")
  return :gems if path.start_with?("gems/")
  return :md if path.end_with?(".md")

  :other
end

def diff_header_path(line, prefix)
  path = line.delete_prefix(prefix).strip
  return nil if path == "/dev/null"

  path.sub(/\A[ab]\//, "")
end

def changed_lines(base)
  old_path = nil
  new_path = nil
  old_line = nil
  new_line = nil
  adds = Hash.new { |h, k| h[k] = Set.new }
  dels = Hash.new { |h, k| h[k] = Set.new }
  sh("git", "diff", "--unified=0", "#{base}...HEAD").each_line do |line|
    if line.start_with?("diff --git ")
      old_path = nil
      new_path = nil
      old_line = nil
      new_line = nil
      next
    end
    if line.start_with?("--- ")
      old_path = diff_header_path(line, "--- ")
      next
    end
    if line.start_with?("+++ ")
      new_path = diff_header_path(line, "+++ ")
      next
    end
    next unless old_path || new_path

    if (m = line.match(/\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/))
      old_line = m[1].to_i
      new_line = m[2].to_i
      next
    end
    next unless old_line && new_line
    next if line.start_with?("\\")

    if line.start_with?("+") && !line.start_with?("+++")
      adds[new_path] << new_line if new_path
      new_line += 1
    elsif line.start_with?("-") && !line.start_with?("---")
      dels[old_path] << old_line if old_path
      old_line += 1
    else
      old_line += 1
      new_line += 1
    end
  end
  { added: adds, deleted: dels }
end

def added_lines(base)
  changed_lines(base)[:added]
end

SrcRubyMethodSpan = Struct.new(:name, :visibility, :start_line, :end_line, :singleton, keyword_init: true)

SRC_RUBY_CHANGE_BUCKETS = {
  src_public_fn: "src/**/*.rb public functions",
  src_private_fn: "src/**/*.rb private functions",
  src_other: "src/**/*.rb OTHER",
}.freeze

SRC_RUBY_VISIBILITY_BUCKET_LABELS = {
  src_public_fn: "public functions",
  src_private_fn: "private functions",
  src_other: "OTHER",
}.freeze

SRC_RUBY_VISIBILITY_CALLS = {
  public: :public,
  private: :private,
  protected: :protected,
}.freeze

SRC_RUBY_CLASS_VISIBILITY_CALLS = {
  public_class_method: :public,
  private_class_method: :private,
}.freeze

def ruby_ast_node?(value)
  defined?(RubyVM::AbstractSyntaxTree::Node) && value.is_a?(RubyVM::AbstractSyntaxTree::Node)
end

def ruby_method_spans(source)
  ruby_method_spans_result(source)[:spans]
end

def ruby_method_spans_result(source)
  { spans: collect_ruby_method_spans(RubyVM::AbstractSyntaxTree.parse(source)), parse_error: nil }
rescue SyntaxError => e
  { spans: [], parse_error: e.message }
end

def collect_ruby_method_spans(node, singleton_context: false)
  return [] unless ruby_ast_node?(node)

  case node.type
  when :SCOPE
    collect_ruby_method_spans(node.children[2], singleton_context: singleton_context)
  when :CLASS
    collect_ruby_method_spans(node.children[2], singleton_context: false)
  when :MODULE
    collect_ruby_method_spans(node.children[1], singleton_context: false)
  when :SCLASS
    collect_ruby_method_spans(node.children[1], singleton_context: true)
  when :BLOCK
    collect_ruby_method_spans_from_statements(node.children, singleton_context: singleton_context)
  else
    node.children.flat_map { |child| collect_ruby_method_spans(child, singleton_context: singleton_context) }
  end
end

def collect_ruby_method_spans_from_statements(statements, singleton_context:)
  visibility = :public
  direct_spans = []
  nested_spans = []
  overrides = { instance: {}, singleton: {} }

  statements.each do |statement|
    next unless ruby_ast_node?(statement)

    if statement.type == :DEFN || statement.type == :DEFS
      direct_spans << ruby_method_span_from_ast(statement, visibility, singleton_context)
      next
    end

    if (call_visibility = src_ruby_visibility_call(statement))
      visibility = update_ruby_visibility_from_call(
        statement,
        call_visibility,
        singleton_context,
        direct_spans,
        overrides,
      ) || visibility
      next
    end

    nested_spans.concat(collect_ruby_method_spans(statement, singleton_context: singleton_context))
  end

  direct_spans.each do |span|
    target = span.singleton ? :singleton : :instance
    override = overrides[target][span.name]
    span.visibility = override if override
  end

  direct_spans + nested_spans
end

def src_ruby_visibility_call(node)
  name = src_ruby_call_name(node)
  SRC_RUBY_VISIBILITY_CALLS[name] || SRC_RUBY_CLASS_VISIBILITY_CALLS[name]
end

def src_ruby_call_name(node)
  return nil unless ruby_ast_node?(node)
  return nil unless node.type == :VCALL || node.type == :FCALL

  node.children[0]
end

def src_ruby_call_args(node)
  return nil unless ruby_ast_node?(node)
  return nil unless node.type == :FCALL

  node.children[1]
end

def update_ruby_visibility_from_call(node, call_visibility, singleton_context, direct_spans, overrides)
  args = src_ruby_call_args(node)
  if (defs = src_ruby_method_defs(args)).any?
    defs.each do |definition|
      direct_spans << ruby_method_span_from_ast(definition, call_visibility, singleton_context, forced_visibility: call_visibility)
    end
    return nil
  end

  names = src_ruby_symbol_literals(args)
  return call_visibility if args.nil?
  return nil if names.empty?

  target = if SRC_RUBY_CLASS_VISIBILITY_CALLS.key?(src_ruby_call_name(node))
             :singleton
           elsif singleton_context
             :singleton
           else
             :instance
           end
  names.each { |name| overrides[target][name] = call_visibility }
  nil
end

def src_ruby_method_defs(node)
  return [] unless ruby_ast_node?(node)
  return [node] if node.type == :DEFN || node.type == :DEFS

  node.children.flat_map { |child| src_ruby_method_defs(child) }
end

def src_ruby_symbol_literals(node)
  return [] unless ruby_ast_node?(node)

  case node.type
  when :LIT
    value = node.children[0]
    value.is_a?(Symbol) ? [value] : []
  when :STR
    [node.children[0].to_s.to_sym]
  else
    node.children.flat_map { |child| src_ruby_symbol_literals(child) }
  end
end

def ruby_method_span_from_ast(node, current_visibility, singleton_context, forced_visibility: nil)
  singleton = node.type == :DEFS || singleton_context
  visibility = forced_visibility || (node.type == :DEFS && !singleton_context ? :public : current_visibility)
  name = node.type == :DEFS ? node.children[1] : node.children[0]
  SrcRubyMethodSpan.new(
    name: name,
    visibility: visibility,
    start_line: node.first_lineno,
    end_line: node.last_lineno,
    singleton: singleton,
  )
end

def src_ruby_line_bucket(line, spans)
  span = spans.select { |candidate| line.between?(candidate.start_line, candidate.end_line) }
              .min_by { |candidate| candidate.end_line - candidate.start_line }
  return :src_other unless span

  case span.visibility
  when :public
    :src_public_fn
  when :private
    :src_private_fn
  else
    :src_other
  end
end

def empty_src_ruby_change_breakdown
  SRC_RUBY_CHANGE_BUCKETS.keys.to_h do |bucket|
    [bucket, { additions: 0, deletions: 0, added_lines: Set.new }]
  end
end

def classify_src_ruby_line_changes(new_source:, old_source:, added_lines:, deleted_lines:)
  breakdown = empty_src_ruby_change_breakdown
  new_spans = ruby_method_spans(new_source.to_s)
  old_spans = ruby_method_spans(old_source.to_s)

  added_lines.each do |line|
    bucket = src_ruby_line_bucket(line, new_spans)
    breakdown[bucket][:additions] += 1
    breakdown[bucket][:added_lines] << line
  end
  deleted_lines.each do |line|
    bucket = src_ruby_line_bucket(line, old_spans)
    breakdown[bucket][:deletions] += 1
  end
  breakdown
end

def empty_src_ruby_visibility_counts
  SRC_RUBY_CHANGE_BUCKETS.keys.to_h { |bucket| [bucket, 0] }
end

def src_ruby_code_line?(line)
  stripped = line.strip
  !stripped.empty? && !stripped.start_with?("#")
end

def classify_src_ruby_source_lines(source)
  parsed = ruby_method_spans_result(source.to_s)
  counts = empty_src_ruby_visibility_counts
  source.to_s.lines.each_with_index do |line, idx|
    next unless src_ruby_code_line?(line)

    bucket = src_ruby_line_bucket(idx + 1, parsed[:spans])
    counts[bucket] += 1
  end
  {
    counts: counts,
    total: counts.values.sum,
    parse_error: parsed[:parse_error],
  }
end

def src_ruby_visibility_files(root: ROOT, directory: "src")
  scan_root = File.expand_path(directory, root)
  Dir.glob(File.join(scan_root, "**", "*.rb")).select { |path| File.file?(path) }.sort
end

def relative_to_root(path, root)
  value = path.to_s
  prefix = "#{root}/"
  value.start_with?(prefix) ? value.delete_prefix(prefix) : value
end

def src_ruby_visibility_breakdown(root: ROOT, directory: "src")
  files = src_ruby_visibility_files(root: root, directory: directory)
  counts = empty_src_ruby_visibility_counts
  parse_failures = []

  files.each do |path|
    result = classify_src_ruby_source_lines(File.read(path))
    result[:counts].each { |bucket, count| counts[bucket] += count }
    next unless result[:parse_error]

    parse_failures << {
      path: relative_to_root(path, root),
      error: result[:parse_error],
    }
  end

  {
    directory: directory,
    files: files.length,
    counts: counts,
    total: counts.values.sum,
    parse_failures: parse_failures,
  }
end

def current_source(path, root: ROOT)
  full_path = File.join(root, path)
  File.file?(full_path) ? File.read(full_path) : ""
end

def source_at_commit(commit, path)
  sh_quiet("git", "show", "#{commit}:#{path}")
end

def bucketed_diff_entries(stats, line_changes, base_commit:, root: ROOT)
  grouped = Hash.new { |h, k| h[k] = [] }
  src_adds_by_bucket = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Set.new } }

  stats.each do |entry|
    path = entry[:path]
    if bucket_for(path) != :src_rb
      grouped[bucket_for(path)] << entry
      next
    end

    breakdown = classify_src_ruby_line_changes(
      new_source: current_source(path, root: root),
      old_source: source_at_commit(base_commit, path),
      added_lines: line_changes.fetch(:added, {}).fetch(path, Set.new),
      deleted_lines: line_changes.fetch(:deleted, {}).fetch(path, Set.new),
    )
    if breakdown.values.none? { |bucket| bucket[:additions].positive? || bucket[:deletions].positive? }
      grouped[:src_other] << entry
      next
    end

    breakdown.each do |bucket, counts|
      next unless counts[:additions].positive? || counts[:deletions].positive?

      grouped[bucket] << {
        path: path,
        additions: counts[:additions],
        deletions: counts[:deletions],
      }
      src_adds_by_bucket[bucket][path].merge(counts[:added_lines])
    end
  end

  grouped[:total] = stats
  { grouped: grouped, src_adds_by_bucket: src_adds_by_bucket }
end

def coverage_paths(env_name, default_paths)
  raw = ENV[env_name].to_s
  return Array(default_paths).map { |path| File.join(ROOT, path) } if raw.empty?

  raw.split(/[#{Regexp.escape(File::PATH_SEPARATOR)},]/).map(&:strip).reject(&:empty?).map do |path|
    File.expand_path(path, ROOT)
  end
end

def explicit_coverage_paths?(env_name)
  !ENV[env_name].to_s.empty?
end

def stale?(coverage_paths, paths)
  existing = coverage_paths.select { |path| File.exist?(path) }
  return :missing if existing.empty?

  newest_source = paths.filter_map do |path|
    full = File.join(ROOT, path)
    File.mtime(full) if File.exist?(full)
  end.max
  return false unless newest_source

  existing.map { |path| File.mtime(path) }.max < newest_source
end

def coverage_state(env_name, cov_paths, paths)
  if explicit_coverage_paths?(env_name)
    cov_paths.any? { |path| File.exist?(path) } ? false : :missing
  else
    stale?(cov_paths, paths)
  end
end

def pct(covered, total)
  return "N/A" if total.zero?

  format("%.1f%%", (covered.to_f / total) * 100.0)
end

def merge_simplecov_file!(coverage, path)
  payload = JSON.parse(File.read(path))
  payload.each_value do |entry|
    (entry["coverage"] || {}).each do |file, cov|
      rel = file.start_with?(ROOT) ? file.delete_prefix("#{ROOT}/") : file
      existing = coverage[rel]
      unless existing
        coverage[rel] = {
          "lines" => (cov["lines"] || []).dup,
          "branches" => JSON.parse(JSON.generate(cov["branches"] || {})),
        }
        next
      end
      lines = cov["lines"] || []
      existing["lines"] ||= []
      max = [existing["lines"].length, lines.length].max
      existing["lines"] = Array.new(max) do |i|
        merge_simplecov_line_hit(existing["lines"][i], lines[i])
      end
      existing["branches"] ||= {}
      (cov["branches"] || {}).each do |parent, children|
        existing["branches"][parent] ||= {}
        children.each do |tuple, hits|
          prior = existing["branches"][parent][tuple]
          existing["branches"][parent][tuple] = [prior, hits].compact.map(&:to_i).max
        end
      end
    end
  end
  coverage
end

def merge_simplecov_line_hit(existing, incoming)
  vals = [existing, incoming]
  positive = vals.compact.select { |hit| hit.to_i.positive? }
  return positive.max unless positive.empty?
  return nil if vals.any?(&:nil?)

  vals.compact.max
end

def parse_simplecov(paths)
  paths.each_with_object({}) { |path, coverage| merge_simplecov_file!(coverage, path) if File.exist?(path) }
end

def tuple_line(tuple)
  tuple.to_s.split(",")[2].to_i
end

def ruby_synthetic_branch_line?(stripped)
  stripped.start_with?("sig ") ||
    stripped == "sig do" ||
    stripped.start_with?("def ") ||
    stripped.start_with?("T.bind(") ||
    stripped.include?("T.let(") ||
    stripped.include?("T.cast(")
end

def ruby_added_coverage(adds, paths)
  return ["", ""] if paths.empty?

  cov_paths = coverage_paths("RUBY_COVERAGE_PATHS", "coverage/.resultset.json")
  state = coverage_state("RUBY_COVERAGE_PATHS", cov_paths, paths)
  return ["N/A (#{state == true ? "stale" : state})", "N/A (#{state == true ? "stale" : state})"] if state

  coverage = parse_simplecov(cov_paths)
  source_lines_by_path = {}
  line_total = line_hit = branch_total = branch_hit = 0
  paths.each do |path|
    cov = coverage[path]
    next unless cov

    lines = cov["lines"] || []
    adds[path].each do |line|
      hit = lines[line - 1]
      next if hit.nil?
      source_lines = source_lines_by_path[path] ||= begin
        full = File.join(ROOT, path)
        File.exist?(full) ? File.readlines(full) : []
      end
      stripped = source_lines[line - 1].to_s.strip
      next if stripped.empty? || stripped.start_with?("#") || stripped == "end"

      line_total += 1
      line_hit += 1 if hit.to_i.positive?
    end
    (cov["branches"] || {}).each_value do |children|
      children.each do |tuple, hits|
        line = tuple_line(tuple)
        next unless adds[path].include?(line)
        next if lines[line - 1].nil?
        source_lines = source_lines_by_path[path] ||= begin
          full = File.join(ROOT, path)
          File.exist?(full) ? File.readlines(full) : []
        end
        stripped = source_lines[line - 1].to_s.strip
        next if stripped.empty? || stripped.start_with?("#") || stripped == "end"
        next if ruby_synthetic_branch_line?(stripped)

        branch_total += 1
        branch_hit += 1 if hits.to_i.positive?
      end
    end
  end
  [pct(line_hit, line_total), pct(branch_hit, branch_total)]
end

def parse_cobertura(path)
  doc = REXML::Document.new(File.read(path))
  files = {}
  REXML::XPath.each(doc, "//class") do |klass|
    filename = klass.attributes["filename"].to_s
    line_hits = {}
    branch_hits = {}
    REXML::XPath.each(klass, "lines/line") do |line|
      nr = line.attributes["number"].to_i
      line_hits[nr] = line.attributes["hits"].to_i
      next unless line.attributes["branch"] == "true"

      raw = line.attributes["condition-coverage"].to_s
      if (m = raw.match(/\((\d+)\/(\d+)\)/))
        branch_hits[nr] = [m[1].to_i, m[2].to_i]
      end
    end
    files[filename] = { lines: line_hits, branches: branch_hits }
  end
  files
end

def parse_coberturas(paths)
  paths.each_with_object({}) do |path, merged|
    next unless File.exist?(path)

    parse_cobertura(path).each do |filename, cov|
      existing = merged[filename]
      unless existing
        merged[filename] = cov
        next
      end
      cov[:lines].each do |line, hits|
        existing[:lines][line] = [existing[:lines][line], hits].compact.max
      end
      cov[:branches].each do |line, counts|
        prior = existing[:branches][line]
        existing[:branches][line] = if prior
                                      [[prior[0], counts[0]].max, [prior[1], counts[1]].max]
                                    else
                                      counts
                                    end
      end
    end
  end
end

def zig_added_coverage(adds, paths)
  return ["", ""] if paths.empty?

  cov_paths = coverage_paths("ZIG_COVERAGE_PATHS", [
    "zig/zig-out/coverage/merged/cobertura.xml",
    "zig/zig-out/coverage/merged/kcov-merged/cobertura.xml",
  ])
  state = coverage_state("ZIG_COVERAGE_PATHS", cov_paths, paths)
  return ["N/A (#{state == true ? "stale" : state})", "N/A (#{state == true ? "stale" : state})"] if state

  coverage = parse_coberturas(cov_paths)
  line_total = line_hit = branch_total = branch_hit = 0
  paths.each do |path|
    zig_relative = path.delete_prefix("zig/")
    cov = coverage[path] || coverage["./#{path}"] || coverage[zig_relative] || coverage["./#{zig_relative}"] || coverage[File.join(ROOT, path)]
    next unless cov

    adds[path].each do |line|
      next unless cov[:lines].key?(line)

      line_total += 1
      line_hit += 1 if cov[:lines][line].positive?
      next unless cov[:branches].key?(line)

      covered, total = cov[:branches][line]
      branch_total += total
      branch_hit += covered
    end
  end
  [pct(line_hit, line_total), pct(branch_hit, branch_total)]
end

SPECIAL_ZIG_SCOPE_PREFIXES = ["zig/runtime/", "zig/lib/"].freeze

def special_zig_source_path?(path)
  bucket_for(path) == :zig_src && SPECIAL_ZIG_SCOPE_PREFIXES.any? { |prefix| path.start_with?(prefix) }
end

def zig_coverage_for_path(coverage, path)
  zig_relative = path.delete_prefix("zig/")
  coverage[path] ||
    coverage["./#{path}"] ||
    coverage[zig_relative] ||
    coverage["./#{zig_relative}"] ||
    coverage[File.join(ROOT, path)]
end

def source_line_at(root, path, line)
  full = File.join(root, path)
  return "" unless File.exist?(full)

  File.readlines(full)[line - 1].to_s.rstrip
end

def added_loom_site?(source)
  stripped = source.sub(LoomAtomicCoverage::COMMENT_RE, "")
  LoomAtomicCoverage::ATOMIC_PATTERNS.any? { |pattern| stripped.match?(pattern) }
end

def added_vopr_category(source)
  return :retry if source.match?(VoprCoverage::RETRY_BEGIN_RE) || source.match?(VoprCoverage::RETRY_SINGLE_RE)

  VoprCoverage.categorize(source.sub(VoprCoverage::COMMENT_RE, ""))
end

def covered_or_elided_for_loom?(cov, line, source)
  return false unless cov

  hits = cov[:lines][line]
  return true if hits&.positive?
  return false if hits.nil?

  LoomAtomicCoverage.classify_artifact(cov[:lines], line, source)
end

def covered_by_zig?(cov, line)
  return false unless cov

  cov[:lines][line]&.positive? == true
end

def wait_loop_indexes(root)
  source_files = WaitLoopCoverage.scan_source_files(["zig/runtime", "zig/lib"], root)
  test_files = WaitLoopCoverage.scan_hammer_test_files(["zig", "zig/runtime"], root)
  loops, issues = WaitLoopCoverage.parse_loops(source_files, root)
  covers = WaitLoopCoverage.parse_covers(test_files, root)
  {
    issues: issues,
    loop_tags: loops.map(&:tag).to_set,
    cover_tags: covers.map(&:tag).to_set,
  }
end

def special_coverage_alerts(adds_by_path, root: ROOT, cov_paths: nil)
  paths = adds_by_path.keys.select { |path| special_zig_source_path?(path) }
  return [] if paths.empty?

  cov_paths ||= coverage_paths("ZIG_COVERAGE_PATHS", [
    "zig/zig-out/coverage/merged/cobertura.xml",
    "zig/zig-out/coverage/merged/kcov-merged/cobertura.xml",
  ])
  coverage = parse_coberturas(cov_paths)
  wait_indexes = nil
  alerts = []

  paths.sort.each do |path|
    cov = zig_coverage_for_path(coverage, path)
    adds_by_path[path].sort.each do |line|
      source = source_line_at(root, path, line)
      next if source.empty?

      if added_loom_site?(source) && !covered_or_elided_for_loom?(cov, line, source)
        alerts << {
          path: path,
          line: line,
          rule: "loom",
          finding: "added atomic/interleaving site has no merged Zig coverage evidence",
          source: source.strip,
        }
      end

      if (category = added_vopr_category(source)) && !covered_by_zig?(cov, line)
        alerts << {
          path: path,
          line: line,
          rule: "vopr",
          finding: "added #{VoprCoverage::CATEGORY_LABEL.fetch(category, category)} site has no merged Zig coverage evidence",
          source: source.strip,
        }
      end

      if (begin_match = WaitLoopCoverage::BEGIN_RE.match(source))
        wait_indexes ||= wait_loop_indexes(root)
        tag = begin_match[1]
        unless wait_indexes[:cover_tags].include?(tag)
          alerts << {
            path: path,
            line: line,
            rule: "wait_loop",
            finding: "added wait-loop tag `#{tag}` has no HAMMER-COVERS marker",
            source: source.strip,
          }
        end
      elsif (cover_match = WaitLoopCoverage::COVER_RE.match(source))
        wait_indexes ||= wait_loop_indexes(root)
        tag = cover_match[1]
        unless wait_indexes[:loop_tags].include?(tag)
          alerts << {
            path: path,
            line: line,
            rule: "wait_loop",
            finding: "added HAMMER-COVERS tag `#{tag}` has no source wait-loop marker",
            source: source.strip,
          }
        end
      end
    end
  end

  if wait_indexes && wait_indexes[:issues].any?
    wait_indexes[:issues].each do |issue|
      alerts << {
        path: "zig",
        line: 0,
        rule: "wait_loop",
        finding: "wait-loop marker syntax issue: #{issue}",
        source: "",
      }
    end
  end

  alerts
end

def print_table(rows)
  widths = rows.transpose.map { |col| col.map(&:length).max }
  rows.each_with_index do |row, idx|
    puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ")
    puts widths.map { |w| "-" * w }.join("  ") if idx.zero?
  end
end

def markdown_escape(value)
  value.to_s.gsub("|", "\\|")
end

def print_markdown(base, rows)
  puts "## Diff Coverage Buckets"
  puts
  puts "**Diff base:** `#{base}...HEAD`"
  puts
  rows.each_with_index do |row, idx|
    puts "| #{row.map { |cell| markdown_escape(cell) }.join(" | ")} |"
    next unless idx.zero?

    puts "| #{row.map.with_index { |_cell, i| i.between?(1, 3) ? "---:" : "---" }.join(" | ")} |"
  end
end

def src_ruby_visibility_rows(breakdown)
  total = breakdown[:total]
  rows = [["bucket", "lines", "share"]]
  SRC_RUBY_VISIBILITY_BUCKET_LABELS.each do |bucket, label|
    count = breakdown[:counts].fetch(bucket, 0)
    rows << [label, count.to_s, pct(count, total)]
  end
  rows << ["total", total.to_s, pct(total, total)]
end

def src_ruby_visibility_scope(breakdown)
  File.join(breakdown[:directory].to_s, "**", "*.rb")
end

def print_src_ruby_visibility_text(breakdown)
  puts
  puts "Src Ruby visibility breakdown:"
  puts "  scope: #{src_ruby_visibility_scope(breakdown)}"
  puts "  files: #{breakdown[:files]}"
  puts "  counted lines: nonblank, non-comment Ruby source lines; protected methods are grouped into OTHER"
  print_table(src_ruby_visibility_rows(breakdown))
  return if breakdown[:parse_failures].empty?

  puts "  parse failures:"
  breakdown[:parse_failures].first(10).each do |failure|
    puts "    #{failure[:path]} - #{failure[:error].lines.first.to_s.strip}"
  end
  puts "    ... #{breakdown[:parse_failures].length - 10} more" if breakdown[:parse_failures].length > 10
end

def print_src_ruby_visibility_markdown(breakdown)
  puts
  puts "## Src Ruby Visibility Breakdown"
  puts
  puts "**Scope:** `#{src_ruby_visibility_scope(breakdown)}`"
  puts
  puts "**Files:** #{breakdown[:files]}"
  puts
  puts "Counts are nonblank, non-comment Ruby source lines. Protected methods are grouped into `OTHER`."
  puts
  src_ruby_visibility_rows(breakdown).each_with_index do |row, idx|
    puts "| #{row.map { |cell| markdown_escape(cell) }.join(" | ")} |"
    puts "| --- | ---: | ---: |" if idx.zero?
  end
  return if breakdown[:parse_failures].empty?

  puts
  puts "**Parse failures:**"
  breakdown[:parse_failures].first(10).each do |failure|
    puts "- `#{failure[:path]}` - #{markdown_escape(failure[:error].lines.first.to_s.strip)}"
  end
  puts "- _#{breakdown[:parse_failures].length - 10} more parse failures omitted._" if breakdown[:parse_failures].length > 10
end

def type_guardrail_findings(adds_by_path)
  ruby_paths = src_ruby_added_paths(adds_by_path)
  NilKill::StaticDiffAudit.new(
    root: ROOT,
    added_lines: added_lines_for_paths(adds_by_path, ruby_paths),
    context_paths: src_ruby_context_paths
  ).findings +
    rubocop_guardrail_findings(adds_by_path) +
    src_ast_walk_guardrail_findings(adds_by_path)
end

RUBOCOP_GUARDRAIL_COPS = [
  "Lint/DuplicateBranch",
  "Lint/RedundantSafeNavigation",
  "Lint/SafeNavigationConsistency",
].freeze

RUBOCOP_GUARDRAIL_KIND = {
  "Lint/DuplicateBranch" => "rubocop_duplicate_branch",
  "Lint/RedundantSafeNavigation" => "rubocop_redundant_safe_navigation",
  "Lint/SafeNavigationConsistency" => "rubocop_safe_navigation_consistency",
}.freeze

def src_ruby_added_paths(adds_by_path, root: ROOT)
  adds_by_path.keys.select do |path|
    path.start_with?("src/") && path.end_with?(".rb") && File.file?(File.join(root, path))
  end.sort
end

def src_ruby_context_paths(root: ROOT)
  Dir.glob(File.join(root, "src/**/*.rb")).filter_map do |path|
    next unless File.file?(path)

    path.delete_prefix("#{root}/")
  end.sort
end

def added_lines_for_paths(adds_by_path, paths)
  paths.to_h { |path| [path, adds_by_path.fetch(path, Set.new)] }
end

def rubocop_guardrail_findings(adds_by_path, root: ROOT)
  paths = src_ruby_added_paths(adds_by_path, root: root)
  return [] if paths.empty?

  output = sh_quiet(
    "bundle", "exec", "rubocop",
    "--only", RUBOCOP_GUARDRAIL_COPS.join(","),
    "--format", "json",
    *paths,
  )
  rubocop_guardrail_findings_from_json(adds_by_path, output, root: root)
rescue StandardError => e
  [rubocop_guardrail_unavailable_finding(e.message)]
end

def rubocop_guardrail_findings_from_json(adds_by_path, output, root: ROOT)
  payload = JSON.parse(output)
  payload.fetch("files", []).flat_map do |file|
    path = normalize_rubocop_path(file.fetch("path", ""), root)
    added = adds_by_path.fetch(path, Set.new)
    next [] if added.empty? || !path.start_with?("src/") || !path.end_with?(".rb")

    file.fetch("offenses", []).filter_map do |offense|
      cop = offense.fetch("cop_name", "")
      next unless RUBOCOP_GUARDRAIL_COPS.include?(cop)
      location = offense.fetch("location", {})
      next unless rubocop_location_lines(location).any? { |line| added.include?(line) }

      line = location.fetch("line", 0).to_i
      column = location.fetch("column", 0).to_i
      message = offense.fetch("message", "RuboCop offense")
      code = source_line_at(root, path, line).strip
      NilKill::StaticDiffAudit::Finding.new(
        kind: RUBOCOP_GUARDRAIL_KIND.fetch(cop),
        path: path,
        line: line,
        message: "added src line trips #{cop}",
        detail: [message, column.positive? ? "column #{column}" : nil].compact.join("; "),
        code: code,
      )
    end
  end.sort_by { |finding| [finding.path, finding.line, finding.kind] }
rescue JSON::ParserError => e
  [rubocop_guardrail_unavailable_finding("could not parse RuboCop JSON: #{e.message}")]
end

def rubocop_location_lines(location)
  first = location.fetch("line", 0).to_i
  last = location.fetch("last_line", first).to_i
  return [] unless first.positive?

  (first..[last, first].max).to_a
end

def normalize_rubocop_path(path, root)
  value = path.to_s
  absolute_prefix = "#{root}/"
  value.start_with?(absolute_prefix) ? value.delete_prefix(absolute_prefix) : value
end

def rubocop_guardrail_unavailable_finding(message)
  NilKill::StaticDiffAudit::Finding.new(
    kind: "rubocop_guardrail_unavailable",
    path: "src",
    line: 0,
    message: "RuboCop guardrail check did not run",
    detail: message.to_s,
    code: "",
  )
end

def src_ast_walk_guardrail_findings(adds_by_path, root: ROOT)
  paths = src_ruby_added_paths(adds_by_path, root: root)
  return [] if paths.empty?

  absolute_paths = paths.map { |path| File.join(root, path) }
  SrcAstWalkGuardrail.scan(root: root, paths: absolute_paths).filter_map do |finding|
    next if finding.allowed
    next unless adds_by_path.fetch(finding.path, Set.new).include?(finding.line)

    NilKill::StaticDiffAudit::Finding.new(
      kind: "late_ast_walk",
      path: finding.path,
      line: finding.line,
      message: "added src line introduces forbidden source AST walk",
      detail: "#{finding.reason}; call=#{finding.call}",
      code: finding.source,
    )
  end.sort_by { |finding| [finding.path, finding.line, finding.kind] }
end

def print_type_guardrails_text(findings)
  puts
  puts "Src type guardrails:"
  if findings.empty?
    puts "  none"
    return
  end
  findings.first(30).each do |finding|
    puts "  #{finding.path}:#{finding.line} #{finding.kind} - #{finding.message}"
    puts "    #{finding.detail}" unless finding.detail.empty?
  end
  puts "  ... #{findings.length - 30} more" if findings.length > 30
end

def print_type_guardrails_markdown(findings)
  puts
  puts "## Src Type Guardrails"
  puts
  if findings.empty?
    puts "No added `src/**/*.rb` type guardrail findings."
    return
  end

  puts "| path | rule | finding |"
  puts "| --- | --- | --- |"
  findings.first(30).each do |finding|
    location = "`#{finding.path}:#{finding.line}`"
    message = "#{finding.message}; #{finding.detail}".sub(/; \z/, "")
    puts "| #{markdown_escape(location)} | `#{markdown_escape(finding.kind)}` | #{markdown_escape(message)} |"
  end
  puts
  puts "_#{findings.length - 30} more findings omitted._" if findings.length > 30
end

def print_special_coverage_text(alerts)
  puts
  puts "Zig special coverage alerts:"
  if alerts.empty?
    puts "  none"
    return
  end

  alerts.first(30).each do |alert|
    location = alert[:line].positive? ? "#{alert[:path]}:#{alert[:line]}" : alert[:path].to_s
    puts "  #{location} #{alert[:rule]} - #{alert[:finding]}"
    puts "    #{alert[:source]}" unless alert[:source].empty?
  end
  puts "  ... #{alerts.length - 30} more" if alerts.length > 30
end

def print_special_coverage_markdown(alerts)
  puts
  puts "## Zig Special Coverage Alerts"
  puts
  if alerts.empty?
    puts "No added production Zig lines require missing Loom/VOPR/wait-loop coverage alerts."
    return
  end

  puts "| path | rule | finding |"
  puts "| --- | --- | --- |"
  alerts.first(30).each do |alert|
    location = alert[:line].positive? ? "`#{alert[:path]}:#{alert[:line]}`" : "`#{alert[:path]}`"
    detail = [alert[:finding], alert[:source]].reject(&:empty?).join("; ")
    puts "| #{markdown_escape(location)} | `#{markdown_escape(alert[:rule])}` | #{markdown_escape(detail)} |"
  end
  puts
  puts "_#{alerts.length - 30} more alerts omitted._" if alerts.length > 30
end

if $PROGRAM_NAME == __FILE__
  options = parse_options(ARGV)
  if options[:src_visibility_only]
    src_visibility = src_ruby_visibility_breakdown(directory: options[:src_visibility_path])
    if options[:format] == "markdown"
      print_src_ruby_visibility_markdown(src_visibility)
    else
      print_src_ruby_visibility_text(src_visibility)
    end
    exit
  end

  base = options[:base] || default_base_ref
  stats = numstat(base)
  line_changes = changed_lines(base)
  adds_by_path = line_changes[:added]
  guardrail_findings = type_guardrail_findings(adds_by_path)
  special_alerts = special_coverage_alerts(adds_by_path)
  src_visibility = options[:src_visibility] ? src_ruby_visibility_breakdown(directory: options[:src_visibility_path]) : nil

  bucket_order = [
    [:total, "total"],
    *SRC_RUBY_CHANGE_BUCKETS.to_a,
    [:zig_src, "zig/**/*.zig prod"],
    [:spec, "spec/"],
    [:transpile_tests, "transpile-tests/"],
    [:tools, "tools/"],
    [:gems, "gems/"],
    [:zig_tests, "zig/**/*-test.zig + vopr/loom harness"],
    [:md, "*.md"],
    [:other, "other"],
  ]

  bucketed = bucketed_diff_entries(stats, line_changes, base_commit: diff_base_commit(base))
  grouped = bucketed[:grouped]
  src_adds_by_bucket = bucketed[:src_adds_by_bucket]

  zig_paths = grouped[:zig_src].map { |e| e[:path] }
  zig_test_paths = grouped[:zig_tests].map { |e| e[:path] }
  src_cov_by_bucket = SRC_RUBY_CHANGE_BUCKETS.keys.to_h do |bucket|
    bucket_adds = src_adds_by_bucket[bucket]
    [bucket, ruby_added_coverage(bucket_adds, bucket_adds.keys)]
  end
  zig_cov = zig_added_coverage(adds_by_path, zig_paths)
  zig_test_cov = zig_added_coverage(adds_by_path, zig_test_paths)

  rows = [["bucket", "files", "additions", "deletions", "line cov additions", "branch cov additions"]]
  bucket_order.each do |key, label|
    entries = grouped[key]
    additions = entries.sum { |e| e[:additions] }
    deletions = entries.sum { |e| e[:deletions] }
    coverage = case key
               when *SRC_RUBY_CHANGE_BUCKETS.keys then src_cov_by_bucket.fetch(key)
               when :zig_src then zig_cov
               when :zig_tests then zig_test_cov
               when :spec, :tools then ["not tracked", "not tracked"]
               else ["", ""]
               end
    rows << [label, entries.length.to_s, additions.to_s, deletions.to_s, coverage[0], coverage[1]]
  end

  if options[:format] == "markdown"
    print_markdown(base, rows)
    print_src_ruby_visibility_markdown(src_visibility) if src_visibility
    print_type_guardrails_markdown(guardrail_findings)
    print_special_coverage_markdown(special_alerts)
  else
    puts "Diff base: #{base}...HEAD"
    print_table(rows)
    print_src_ruby_visibility_text(src_visibility) if src_visibility
    print_type_guardrails_text(guardrail_findings)
    print_special_coverage_text(special_alerts)
  end
end
