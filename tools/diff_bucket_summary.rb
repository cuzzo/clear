#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "rexml/document"
require "set"

ROOT = File.expand_path("..", __dir__)

def sh(*args)
  IO.popen(args, chdir: ROOT, err: [:child, :out], &:read)
end

def base_ref
  ARGV[0] || (system("git", "rev-parse", "--verify", "origin/master", out: File::NULL, err: File::NULL) ? "origin/master" : "master")
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

def bucket_for(path)
  return :src_rb if path.start_with?("src/") && path.end_with?(".rb")
  return :zig_src if path.start_with?("zig/") && path.end_with?(".zig") && !path.end_with?("test.zig")
  return :spec if path.start_with?("spec/")
  return :transpile_tests if path.start_with?("transpile-tests/")
  return :tools if path.start_with?("tools/")
  return :zig_tests if path.start_with?("zig/") && path.end_with?("test.zig")
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

def stale?(coverage_path, paths)
  return :missing unless File.exist?(coverage_path)

  newest_source = paths.filter_map do |path|
    full = File.join(ROOT, path)
    File.mtime(full) if File.exist?(full)
  end.max
  return false unless newest_source

  File.mtime(coverage_path) < newest_source
end

def pct(covered, total)
  return "N/A" if total.zero?

  format("%.1f%%", (covered.to_f / total) * 100.0)
end

def parse_simplecov(path)
  payload = JSON.parse(File.read(path))
  coverage = {}
  payload.each_value do |entry|
    (entry["coverage"] || {}).each do |file, cov|
      rel = file.start_with?(ROOT) ? file.delete_prefix("#{ROOT}/") : file
      existing = coverage[rel]
      unless existing
        coverage[rel] = cov
        next
      end
      lines = cov["lines"] || []
      existing["lines"] ||= []
      max = [existing["lines"].length, lines.length].max
      existing["lines"] = Array.new(max) do |i|
        vals = [existing["lines"][i], lines[i]].compact
        vals.empty? ? nil : vals.max
      end
      existing["branches"] = (existing["branches"] || {}).merge(cov["branches"] || {})
    end
  end
  coverage
end

def tuple_line(tuple)
  tuple.to_s.split(",")[2].to_i
end

def ruby_added_coverage(adds, paths)
  cov_path = File.join(ROOT, "coverage/.resultset.json")
  state = stale?(cov_path, paths)
  return ["N/A (#{state == true ? "stale" : state})", "N/A (#{state == true ? "stale" : state})"] if state

  coverage = parse_simplecov(cov_path)
  line_total = line_hit = branch_total = branch_hit = 0
  paths.each do |path|
    cov = coverage[path]
    next unless cov

    lines = cov["lines"] || []
    adds[path].each do |line|
      hit = lines[line - 1]
      next if hit.nil?

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

def zig_added_coverage(adds, paths)
  cov_path = File.join(ROOT, "zig/zig-out/coverage/merged/kcov-merged/cobertura.xml")
  state = stale?(cov_path, paths)
  return ["N/A (#{state == true ? "stale" : state})", "N/A (#{state == true ? "stale" : state})"] if state

  coverage = parse_cobertura(cov_path)
  line_total = line_hit = branch_total = branch_hit = 0
  paths.each do |path|
    cov = coverage[path] || coverage["./#{path}"] || coverage[File.join(ROOT, path)]
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

def print_table(rows)
  widths = rows.transpose.map { |col| col.map(&:length).max }
  rows.each_with_index do |row, idx|
    puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ")
    puts widths.map { |w| "-" * w }.join("  ") if idx.zero?
  end
end

base = base_ref
stats = numstat(base)
adds_by_path = added_lines(base)

bucket_order = [
  [:total, "total"],
  [:src_rb, "src/**/*.rb"],
  [:zig_src, "zig/**/*.zig !*test.zig"],
  [:spec, "spec/"],
  [:transpile_tests, "transpile-tests/"],
  [:tools, "tools/"],
  [:zig_tests, "zig/**/*test.zig"],
  [:md, "*.md"],
  [:other, "other"],
]

grouped = Hash.new { |h, k| h[k] = [] }
stats.each { |entry| grouped[bucket_for(entry[:path])] << entry }
grouped[:total] = stats

src_paths = grouped[:src_rb].map { |e| e[:path] }
zig_paths = grouped[:zig_src].map { |e| e[:path] }
src_cov = ruby_added_coverage(adds_by_path, src_paths)
zig_cov = zig_added_coverage(adds_by_path, zig_paths)

rows = [["bucket", "files", "additions", "deletions", "line cov additions", "branch cov additions"]]
bucket_order.each do |key, label|
  entries = grouped[key]
  additions = entries.sum { |e| e[:additions] }
  deletions = entries.sum { |e| e[:deletions] }
  coverage = case key
             when :src_rb then src_cov
             when :zig_src then zig_cov
             else ["", ""]
             end
  rows << [label, entries.length.to_s, additions.to_s, deletions.to_s, coverage[0], coverage[1]]
end

puts "Diff base: #{base}...HEAD"
print_table(rows)
