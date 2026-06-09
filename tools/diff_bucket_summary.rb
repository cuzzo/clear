#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "rexml/document"
require "set"

ROOT = File.expand_path("..", __dir__)
require_relative "../gems/nil-kill/lib/nil_kill"
require_relative "loom_atomic_coverage"
require_relative "vopr_coverage"
require_relative "wait_loop_coverage"

def sh(*args)
  IO.popen(args, chdir: ROOT, err: [:child, :out], &:read)
end

def sh_quiet(*args)
  IO.popen(args, chdir: ROOT, err: File::NULL, &:read)
end

def parse_options(argv)
  options = { format: "text" }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby tools/diff_bucket_summary.rb [BASE] [--format text|markdown]"
    parser.on("--format FORMAT", %w[text markdown], "Output format") { |value| options[:format] = value }
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
  return :md if path.end_with?(".md")

  :other
end

def added_lines(base)
  current = nil
  adds = Hash.new { |h, k| h[k] = Set.new }
  sh("git", "diff", "--unified=0", "#{base}...HEAD").each_line do |line|
    if line.start_with?("+++ b/")
      current = line.delete_prefix("+++ b/").strip
      next
    end
    next unless current

    if (m = line.match(/\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/))
      start = m[1].to_i
      count = (m[2] || "1").to_i
      @next_new_line = start
      @hunk_end = start + count
      next
    end
    next unless @next_new_line && @hunk_end

    if line.start_with?("+") && !line.start_with?("+++")
      adds[current] << @next_new_line
      @next_new_line += 1
    elsif line.start_with?("-") && !line.start_with?("---")
      next
    else
      @next_new_line += 1
    end
  end
  adds
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
        vals = [existing["lines"][i], lines[i]].compact
        vals.empty? ? nil : vals.max
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

def parse_simplecov(paths)
  paths.each_with_object({}) { |path, coverage| merge_simplecov_file!(coverage, path) if File.exist?(path) }
end

def tuple_line(tuple)
  tuple.to_s.split(",")[2].to_i
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
        next unless adds[path].include?(tuple_line(tuple))

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

def type_guardrail_findings(adds_by_path)
  NilKill::StaticDiffAudit.new(root: ROOT, added_lines: adds_by_path).findings +
    rubocop_guardrail_findings(adds_by_path)
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
  base = options[:base] || default_base_ref
  stats = numstat(base)
  adds_by_path = added_lines(base)
  guardrail_findings = type_guardrail_findings(adds_by_path)
  special_alerts = special_coverage_alerts(adds_by_path)

  bucket_order = [
    [:total, "total"],
    [:src_rb, "src/**/*.rb"],
    [:zig_src, "zig/**/*.zig prod"],
    [:spec, "spec/"],
    [:transpile_tests, "transpile-tests/"],
    [:tools, "tools/"],
    [:zig_tests, "zig/**/*-test.zig + vopr/loom harness"],
    [:md, "*.md"],
    [:other, "other"],
  ]

  grouped = Hash.new { |h, k| h[k] = [] }
  stats.each { |entry| grouped[bucket_for(entry[:path])] << entry }
  grouped[:total] = stats

  src_paths = grouped[:src_rb].map { |e| e[:path] }
  zig_paths = grouped[:zig_src].map { |e| e[:path] }
  zig_test_paths = grouped[:zig_tests].map { |e| e[:path] }
  src_cov = ruby_added_coverage(adds_by_path, src_paths)
  zig_cov = zig_added_coverage(adds_by_path, zig_paths)
  zig_test_cov = zig_added_coverage(adds_by_path, zig_test_paths)

  rows = [["bucket", "files", "additions", "deletions", "line cov additions", "branch cov additions"]]
  bucket_order.each do |key, label|
    entries = grouped[key]
    additions = entries.sum { |e| e[:additions] }
    deletions = entries.sum { |e| e[:deletions] }
    coverage = case key
               when :src_rb then src_cov
               when :zig_src then zig_cov
               when :zig_tests then zig_test_cov
               when :spec, :tools then ["not tracked", "not tracked"]
               else ["", ""]
               end
    rows << [label, entries.length.to_s, additions.to_s, deletions.to_s, coverage[0], coverage[1]]
  end

  if options[:format] == "markdown"
    print_markdown(base, rows)
    print_type_guardrails_markdown(guardrail_findings)
    print_special_coverage_markdown(special_alerts)
  else
    puts "Diff base: #{base}...HEAD"
    print_table(rows)
    print_type_guardrails_text(guardrail_findings)
    print_special_coverage_text(special_alerts)
  end
end
