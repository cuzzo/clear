#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "set"

begin
  require "prism"
rescue LoadError
  abort "prism is required; run `bundle install`"
end

require_relative "../gems/slopcop/lib/slopcop/classifier"

ROOT = File.expand_path("..", __dir__)
DEFAULT_RESULTSET = File.join(ROOT, "coverage", ".resultset.json")

options = {
  resultset: DEFAULT_RESULTSET,
  only: "compiler/ruby/annotator",
  category: nil,
  top: 80,
  format: "md",
  min_repeats: 2,
  diagnostic: []
}

OptionParser.new do |o|
  o.banner = "Usage: ruby tools/fact_flow_audit.rb [options] [files...]"
  o.on("--coverage PATH", "SimpleCov .resultset.json path") { |v| options[:resultset] = File.expand_path(v, ROOT) }
  o.on("--only PREFIX", "Repo-relative file prefix when no files are passed") { |v| options[:only] = v }
  o.on("--category NAME", "Filter SlopCop category, e.g. genuine/type_norm/diagnostic") { |v| options[:category] = v.to_sym }
  o.on("--top N", Integer, "Maximum rows to print") { |v| options[:top] = v }
  o.on("--min-repeats N", Integer, "Minimum repeated fact checks per method") { |v| options[:min_repeats] = v }
  o.on("--format NAME", "md or tsv") { |v| options[:format] = v }
  o.on("--diagnostic LIST", "Comma-separated diagnostic helper names for SlopCop classification") do |v|
    options[:diagnostic] = v.split(",").reject(&:empty?).map(&:to_sym)
  end
end.parse!

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

  if File.exist?(resultset)
    prefix = only.end_with?("/") ? only : "#{only}/"
    files = []
    JSON.parse(File.read(resultset)).each_value do |entry|
      (entry["coverage"] || {}).each do |path, cov|
        next unless cov.is_a?(Hash) && cov["branches"]

        rel = repo_path(path)
        files << path if rel.start_with?(prefix) && rel.end_with?(".rb")
      end
    end
    return files.uniq.sort unless files.empty?
  end

  Dir.glob(File.join(ROOT, only, "**", "*.rb")).sort
end

def branch_rows(resultset, abspath, diagnostic_mids)
  return [] unless File.exist?(resultset)

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
        source: source_line.to_s.strip
      }
    end
  end

  rows
end

def each_ast(node, &block)
  return unless node.is_a?(Prism::Node)

  yield node
  node.compact_child_nodes.each { |child| each_ast(child, &block) }
end

def method_label(class_stack, node)
  name = node.name.to_s
  name = "self.#{name}" if node.receiver&.slice == "self"
  klass = class_stack.reject(&:empty?).join("::")
  klass.empty? ? name : "#{klass}##{name}"
end

def const_name(node)
  node&.slice.to_s
end

def stable_expr(node)
  return nil unless node

  text = node.slice.to_s.strip
  return nil if text.empty? || text.length > 80
  return nil unless text.match?(/\A[@$]?[A-Za-z_]\w*(?:(?:\.|::)[A-Za-z_]\w*[!?=]?)*\z/)

  text
end

def symbol_arg(node)
  text = node&.slice.to_s
  return Regexp.last_match(1) if text.match?(/\A:([A-Za-z_]\w*[!?=]?)\z/)
  return Regexp.last_match(1) if text.match?(/\A["']([A-Za-z_]\w*[!?=]?)["']\z/)

  nil
end

def fact_for_call(node)
  return nil unless node.is_a?(Prism::CallNode)

  receiver = stable_expr(node.receiver)
  args = node.arguments&.arguments || []
  line = node.location.start_line
  code = node.slice.split("\n").first.to_s.strip[0, 120]

  if node.safe_navigation? && receiver
    return {
      kind: "safe_nav",
      key: "non_nil:#{receiver}",
      subject: receiver,
      line: line,
      code: code
    }
  end

  case node.name
  when :nil?
    return nil unless receiver

    { kind: "nil_check", key: "non_nil:#{receiver}", subject: receiver, line: line, code: code }
  when :is_a?, :kind_of?
    return nil unless receiver && args.size == 1

    type = const_name(args.first)
    return nil if type.empty?

    { kind: "type_check", key: "type:#{receiver}:#{type}", subject: receiver, line: line, code: code }
  when :respond_to?
    return nil unless receiver && args.size == 1

    method = symbol_arg(args.first)
    return nil unless method

    { kind: "protocol_check", key: "respond_to:#{receiver}:#{method}", subject: receiver, line: line, code: code }
  else
    nil
  end
end

def add_line_normalizer_facts(facts, source_lines, start_line, end_line)
  (start_line..end_line).each do |line_no|
    line = source_lines[line_no - 1].to_s.strip
    next unless line.include?("is_a?(Type)") && line.include?("Type.new")

    recv = line[/([@A-Za-z_]\w*)\.is_a\?\(Type\)/, 1]
    next unless recv

    facts << {
      kind: "type_normalizer",
      key: "type_normalizer:#{recv}:Type",
      subject: recv,
      line: line_no,
      code: line[0, 120]
    }
  end
end

def collect_method_facts(abspath)
  source = File.read(abspath)
  parsed = Prism.parse(source)
  return [] unless parsed.success?

  lines = source.lines
  rows = []
  walk = lambda do |node, class_stack|
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = node.constant_path&.slice.to_s
      node.compact_child_nodes.each { |child| walk.call(child, class_stack + [name]) }
    when Prism::DefNode
      facts = []
      each_ast(node.body) do |child|
        fact = fact_for_call(child)
        facts << fact if fact
      end
      add_line_normalizer_facts(facts, lines, node.location.start_line, node.location.end_line)
      facts.group_by { |fact| fact[:key] }.each do |key, group|
        rows << {
          file: repo_path(abspath),
          method: method_label(class_stack, node),
          method_line: node.location.start_line,
          key: key,
          kind: group.map { |fact| fact[:kind] }.uniq.sort.join("+"),
          subject: group.first[:subject],
          occurrences: group.length,
          lines: group.map { |fact| fact[:line] }.uniq.sort,
          examples: group.map { |fact| fact[:code] }.uniq.first(3)
        }
      end
    else
      node.compact_child_nodes.each { |child| walk.call(child, class_stack) } if node.respond_to?(:compact_child_nodes)
    end
  end
  walk.call(parsed.value, [])
  rows
rescue SyntaxError, StandardError => e
  warn "skip #{repo_path(abspath)}: #{e.class}: #{e.message}"
  []
end

def attach_branch_pressure(fact_rows, branch_rows, category)
  branches_by_file = branch_rows.group_by { |row| row[:file] }
  fact_rows.each do |row|
    file_branches = Array(branches_by_file[row[:file]])
    exact_uncovered = file_branches.select do |branch|
      row[:lines].include?(branch[:line]) && (!category || branch[:category] == category)
    end
    method_uncovered = file_branches.select do |branch|
      branch[:method] == row[:method].split("#").last && (!category || branch[:category] == category)
    end
    row[:exact_uncovered_arms] = exact_uncovered.length
    row[:method_uncovered_arms] = method_uncovered.length
    row[:categories] = method_uncovered.each_with_object(Hash.new(0)) { |branch, h| h[branch[:category]] += 1 }
    row[:exact_decisions] = exact_uncovered.map { |branch| "#{branch[:decision]}/#{branch[:arm]}@#{branch[:line]}" }.uniq.first(6)
    row[:method_decisions] = method_uncovered.map { |branch| "#{branch[:decision]}/#{branch[:arm]}@#{branch[:line]}" }.uniq.first(6)
    row[:score] = row[:exact_uncovered_arms] * 20 + row[:method_uncovered_arms] * 2 + row[:occurrences]
  end
end

files = target_files(options[:resultset], options[:only], ARGV).select { |path| File.file?(path) }
branches = files.flat_map { |file| branch_rows(options[:resultset], file, options[:diagnostic]) }
branches.select! { |row| row[:category] == options[:category] } if options[:category]
facts = files.flat_map { |file| collect_method_facts(file) }
facts.select! { |row| row[:occurrences] >= options[:min_repeats] }
attach_branch_pressure(facts, branches, options[:category])
facts.sort_by! { |row| [-row[:score], -row[:exact_uncovered_arms], -row[:method_uncovered_arms], -row[:occurrences], row[:file], row[:method], row[:key]] }

counts = branches.each_with_object(Hash.new(0)) { |row, h| h[row[:category]] += 1 }
selected = facts.first(options[:top])

if options[:format] == "tsv"
  puts %w[file method key kind occurrences exact_arms method_arms categories lines examples exact_decisions method_decisions].join("\t")
  selected.each do |row|
    puts [
      row[:file],
      row[:method],
      row[:key],
      row[:kind],
      row[:occurrences],
      row[:exact_uncovered_arms],
      row[:method_uncovered_arms],
      row[:categories].sort_by { |_, n| -n }.map { |k, v| "#{k}=#{v}" }.join(","),
      row[:lines].join(","),
      row[:examples].join(" | "),
      row[:exact_decisions].join(","),
      row[:method_decisions].join(",")
    ].join("\t")
  end
  exit
end

puts "# Fact Flow Audit"
puts
puts "- Coverage: `#{File.exist?(options[:resultset]) ? repo_path(options[:resultset]) : "missing"}`"
puts "- Scope: `#{ARGV.empty? ? options[:only] : ARGV.join(", ")}`"
puts "- Files: #{files.length}"
puts "- Repeated fact groups: #{facts.length}"
puts "- Uncovered arms in scope: #{branches.length}"
puts "- Categories: #{counts.sort_by { |_, n| -n }.map { |k, v| "#{k}=#{v}" }.join(", ")}"
puts "- Minimum repeats: #{options[:min_repeats]}"
puts
puts "| file | method | fact | kind | checks | exact arms | method arms | categories | lines | examples |"
puts "|---|---|---|---|---:|---:|---:|---|---|---|"
selected.each do |row|
  categories = row[:categories].sort_by { |_, n| -n }.map { |k, v| "#{k}=#{v}" }.join(", ")
  examples = row[:examples].map { |code| "`#{code.gsub("|", "\\|")}`" }.join("<br>")
  lines = row[:lines].map { |line| "`#{line}`" }.join(", ")
  fact = row[:key].gsub("|", "\\|")
  puts "| `#{row[:file]}` | `#{row[:method]}` | `#{fact}` | #{row[:kind]} | #{row[:occurrences]} | #{row[:exact_uncovered_arms]} | #{row[:method_uncovered_arms]} | #{categories} | #{lines} | #{examples} |"
end
