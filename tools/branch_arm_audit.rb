#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

require_relative "../gems/slopcop/lib/slopcop/classifier"

ROOT = File.expand_path("..", __dir__)
DEFAULT_RESULTSET = File.join(ROOT, "coverage", ".resultset.json")

options = {
  resultset: DEFAULT_RESULTSET,
  only: "src/annotator",
  category: nil,
  top: 120,
  format: "md",
  diagnostic: []
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/branch_arm_audit.rb [options] [files...]"
  o.on("--coverage PATH", "SimpleCov .resultset.json path") { |v| options[:resultset] = File.expand_path(v, ROOT) }
  o.on("--only PREFIX", "Repo-relative file prefix when no files are passed") { |v| options[:only] = v }
  o.on("--category NAME", "Filter SlopCop category, e.g. genuine/type_norm/diagnostic") { |v| options[:category] = v.to_sym }
  o.on("--top N", Integer, "Maximum rows to print") { |v| options[:top] = v }
  o.on("--format NAME", "md or tsv") { |v| options[:format] = v }
  o.on("--diagnostic LIST", "Comma-separated project diagnostic helper names") do |v|
    options[:diagnostic] = v.split(",").reject(&:empty?).map(&:to_sym)
  end
end.parse!

abort "no #{options[:resultset]}" unless File.exist?(options[:resultset])

def tuple_parts(tuple)
  tuple.gsub(/[\[\]:]/, "").split(",").map(&:strip)
end

def repo_path(path)
  Pathname.new(path).relative_path_from(Pathname.new(ROOT)).to_s
rescue ArgumentError
  path
end

def target_files(resultset, only, explicit)
  return explicit.map { |f| File.expand_path(f, ROOT) } unless explicit.empty?

  prefix = only.end_with?("/") ? only : "#{only}/"
  files = []
  JSON.parse(File.read(resultset)).each_value do |entry|
    (entry["coverage"] || {}).each do |path, cov|
      next unless cov.is_a?(Hash) && cov["branches"]

      rel = repo_path(path)
      files << path if rel.start_with?(prefix) && rel.end_with?(".rb")
    end
  end
  files.uniq.sort
end

def branch_rows(resultset, abspath, diagnostic_mids)
  branches = SlopCop::Classifier.merged_branches(resultset, abspath)
  return [] if branches.empty?

  lines = File.readlines(abspath)
  methods = SlopCop::Classifier.method_index(lines)
  noise_lines = SlopCop::Classifier.declaration_noise_lines(lines)
  nodes = SlopCop::Classifier.ast_nodes(abspath)
  rows = []

  branches.each do |parent, arms|
    p = tuple_parts(parent)
    pkind = p[0].to_sym
    pnode = SlopCop::Classifier.node_for(nodes, p[2].to_i, p[3].to_i, p[4].to_i, p[5].to_i)
    cond = if pnode && %i[IF UNLESS WHILE UNTIL CASE].include?(pnode.type)
             pnode.children[0]
           else
             pnode
           end
    sibling_taken = arms.values.any? { |v| v.to_i.positive? }

    arms.each do |arm, count|
      next unless count.to_i.zero?

      a = tuple_parts(arm)
      line = a[2].to_i
      anode = SlopCop::Classifier.node_for(nodes, a[2].to_i, a[3].to_i, a[4].to_i, a[5].to_i)
      method = methods[line] || "(top-level)"
      source_line = line > lines.length ? "" : lines[line - 1]
      category = SlopCop::Classifier.categorize(
        method,
        pkind,
        anode,
        sibling_taken,
        cond,
        [],
        pnode,
        source_line,
        noise_lines.include?(line),
        diagnostic_mids
      )
      next unless category

      rows << {
        file: repo_path(abspath),
        line: line,
        method: method,
        category: category,
        decision: pkind,
        arm: a[0].to_sym,
        sibling_taken: sibling_taken,
        source: source_line.to_s.strip
      }
    end
  end

  rows
end

files = target_files(options[:resultset], options[:only], ARGV)
rows = files.flat_map { |file| branch_rows(options[:resultset], file, options[:diagnostic]) }
rows.select! { |row| row[:category] == options[:category] } if options[:category]
rows.sort_by! { |row| [row[:file], row[:line], row[:method], row[:decision].to_s, row[:arm].to_s] }

counts = rows.each_with_object(Hash.new(0)) { |row, h| h[row[:category]] += 1 }
puts "# Branch Arm Audit"
puts
puts "- Coverage: `#{repo_path(options[:resultset])}`"
puts "- Scope: `#{ARGV.empty? ? options[:only] : ARGV.join(", ")}`"
puts "- Rows: #{rows.length}"
puts "- Categories: #{counts.sort_by { |_, n| -n }.map { |k, v| "#{k}=#{v}" }.join(", ")}"
puts

selected = rows.first(options[:top])
if options[:format] == "tsv"
  puts %w[file line method category decision arm sibling_taken source].join("\t")
  selected.each do |row|
    puts [
      row[:file], row[:line], row[:method], row[:category], row[:decision],
      row[:arm], row[:sibling_taken], row[:source]
    ].join("\t")
  end
else
  puts "| file | line | method | category | decision | arm | sibling taken | source |"
  puts "|---|---:|---|---|---|---|---|---|"
  selected.each do |row|
    source = row[:source].gsub("|", "\\|")
    puts "| `#{row[:file]}` | #{row[:line]} | `#{row[:method]}` | #{row[:category]} | #{row[:decision]} | #{row[:arm]} | #{row[:sibling_taken]} | `#{source}` |"
  end
end
