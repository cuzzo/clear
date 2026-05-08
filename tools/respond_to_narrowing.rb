#!/usr/bin/env ruby
# tools/respond_to_narrowing.rb
#
# Per-site receiver-type narrowing analysis for `respond_to?(:X)`.
# Walks each call site and inspects the surrounding AST for prior
# is_a? checks, case/when arms, and assignments that constrain the
# receiver's possible type.
#
# Output: tmp/respond_to_inventory/narrowing.csv with columns
#   file, line, attr, receiver, narrowing, classification
#
# narrowing: comma-separated list of facts found ("is_a?(AST::X) at L42",
#            "case AST::Y arm", "from .value of Y", "param of method M")
# classification: one of
#   ast_locatable    — receiver is constrained to AST::Locatable subtype;
#                      Locatable attrs (`value`, `full_type`, etc.) are
#                      universal — guard is dead
#   typed_specific   — receiver is constrained to specific AST classes;
#                      check inventory if attr is in their fields
#   from_locatable_attr — receiver = some_ast.value (and value's type
#                         is locatable per ast.rb), so receiver is AST
#   walker_yielded   — inside a generic walker block; receiver is
#                      whatever yields produced (could be heterogeneous)
#   unknown          — no narrowing facts found
#
# Usage: bundle exec ruby tools/respond_to_narrowing.rb [attr1 attr2 ...]
# Default attrs: value full_type
require "prism"
require "csv"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
OUT_DIR = File.join(ROOT, "tmp", "respond_to_inventory")
FileUtils.mkdir_p(OUT_DIR)

TARGET_ATTRS = ARGV.empty? ? %w[value full_type] : ARGV

# Walker names that signal "I yield arbitrary values":
WALKER_BLOCK_NAMES = %w[
  walk_body walk_idents walk_expr walk_expr_skip_copy
  each_bg_block each_bg_block_in_stmt each_capture_analysis
  each_pair AST.walk_body each
].freeze

# attrs that AST::Locatable provides (or all AST nodes have via member);
# load from existing attrs_by_class.csv inventory.
def load_locatable_attrs
  csv_path = File.join(OUT_DIR, "attrs_by_class.csv")
  return [] unless File.exist?(csv_path)
  rows = CSV.read(csv_path, headers: true)
  by_attr = Hash.new { |h, k| h[k] = 0 }
  classes = rows.map { |r| r["class"] }.uniq
  rows.each { |r| by_attr[r["attr"]] += 1 }
  total = classes.size
  # An attr present on every (or nearly every) class is essentially
  # Locatable-universal. Use 95% threshold to allow a few specialty
  # nodes that aren't AST proper.
  by_attr.select { |_, n| n >= total * 0.95 }.keys
end

LOCATABLE_ATTRS = load_locatable_attrs

class SiteAnalyzer < Prism::Visitor
  attr_reader :findings

  def initialize(file, target_lines)
    super()
    @file = file
    @targets = target_lines  # Set of line numbers to analyze
    @findings = {}           # line -> { receiver:, attr:, narrowing: [], scope: [] }
    @scope_stack = []
  end

  def visit_def_node(node)
    @scope_stack.push({ kind: :def, name: node.name.to_s, params:
                          (node.parameters&.requireds || []).map(&:name).map(&:to_s),
                        location: node.location.start_line })
    super
    @scope_stack.pop
  end

  def visit_block_node(node)
    block_params = begin
      (node.parameters&.parameters&.requireds || []).map(&:name).map(&:to_s)
    rescue StandardError
      []
    end
    @scope_stack.push({ kind: :block, params: block_params, location: node.location.start_line })
    super
    @scope_stack.pop
  end

  def visit_case_node(node)
    @scope_stack.push({ kind: :case, location: node.location.start_line })
    super
    @scope_stack.pop
  end

  def visit_when_node(node)
    types = (node.conditions || []).filter_map do |c|
      c.respond_to?(:slice) ? c.slice : nil
    end
    @scope_stack.push({ kind: :when, types: types,
                        location: node.location.start_line })
    super
    @scope_stack.pop
  end

  def visit_if_node(node)
    cond_text = node.predicate&.slice
    @scope_stack.push({ kind: :if, cond: cond_text,
                        location: node.location.start_line })
    super
    @scope_stack.pop
  end

  def visit_call_node(node)
    if node.name == :respond_to? && node.arguments&.arguments&.length == 1
      arg = node.arguments.arguments.first
      if arg.is_a?(Prism::SymbolNode) && @targets.include?(node.location.start_line)
        receiver = node.receiver&.slice
        @findings[node.location.start_line] = {
          receiver: receiver,
          attr: arg.unescaped,
          scope: @scope_stack.dup
        }
      end
    end
    super
  end
end

# Build a per-file map of (file, [line]) for all target sites.
sites_csv = File.join(OUT_DIR, "sites.csv")
unless File.exist?(sites_csv)
  abort "Missing #{sites_csv} — run tools/respond_to_inventory.rb first."
end

target_sites = []
CSV.foreach(sites_csv, headers: true) do |row|
  next unless TARGET_ATTRS.include?(row["attr"])
  target_sites << row.to_h
end

by_file = target_sites.group_by { |s| s["file"] }

results = []
by_file.each do |file, sites|
  abs = File.join(ROOT, file)
  next unless File.exist?(abs)
  src = File.read(abs)
  lines = src.lines  # 1-indexed via [n-1]
  target_lines = sites.map { |s| s["line"].to_i }.to_set

  visitor = SiteAnalyzer.new(file, target_lines)
  Prism.parse(src).value.accept(visitor)

  sites.each do |s|
    line = s["line"].to_i
    f = visitor.findings[line]
    receiver = f&.dig(:receiver) || s["receiver"]
    scope = f&.dig(:scope) || []

    # Narrow by walking back through the file looking for is_a? guards
    # or assignments on this receiver.
    narrowing = []

    # 1. when AST::X arm above this line, in the enclosing case
    when_scope = scope.reverse.find { |s| s[:kind] == :when }
    if when_scope
      narrowing << "in `when #{when_scope[:types].join(', ')}` arm"
    end

    # 2. if/elsif with is_a? on the receiver above
    (scope.reverse.find { |s| s[:kind] == :if && s[:cond]&.include?("is_a?") }&.dig(:cond)).then do |cond|
      narrowing << "in `if #{cond}` block" if cond
    end

    # 3. Local lines preceding the call: look for `is_a?(AST::Y)` checks
    #    on the same receiver name in the prior 30 lines (within scope).
    enclosing = scope.reverse.find { |s| s[:kind] == :def || s[:kind] == :block }
    method_start = enclosing&.dig(:location) || (line - 30)
    scan_start = [method_start, line - 30].max
    if receiver
      ((scan_start)..(line - 1)).each do |ln|
        text = lines[ln - 1].to_s
        # is_a?(AST::Y) on this receiver
        if md = text.match(/\b#{Regexp.escape(receiver)}\.is_a\?\(([A-Z][\w:]+)\)/)
          narrowing << "is_a?(#{md[1]}) at L#{ln}"
        end
        # receiver = something.value or .X (Locatable attr return)
        if md = text.match(/\b#{Regexp.escape(receiver)}\s*=\s*([\w.]+)\.([a-z_]+)\b/)
          if LOCATABLE_ATTRS.include?(md[2])
            narrowing << "= .#{md[2]} of #{md[1]} at L#{ln}"
          end
        end
        # case receiver / when AST::Y on this receiver
        if text =~ /\bcase\s+#{Regexp.escape(receiver)}\b/
          # Look forward for the matching when arm covering this line.
          # Heuristic only — full match would need richer AST inspection.
          narrowing << "in case-on-#{receiver} starting at L#{ln}"
        end
      end
    end

    # 4. Walker-context: enclosing block/method has a generic param
    #    name AND receiver is that param.
    if enclosing && receiver
      params = enclosing[:params] || []
      if params.include?(receiver)
        if params.any? { |p| %w[node stmt expr value val n v item arg].include?(p) }
          narrowing << "param of #{enclosing[:kind]}(#{params.join(',')})"
        end
      end
    end

    # Classify
    classification =
      if narrowing.any? { |n| n.start_with?("is_a?(AST::") || n.include?("when AST::") || n.include?("in `when AST::") }
        "typed_specific"
      elsif narrowing.any? { |n| n.start_with?("= .") }
        "from_locatable_attr"
      elsif narrowing.any? { |n| n.start_with?("param of") }
        "walker_yielded"
      else
        "unknown"
      end

    results << {
      file: file, line: line, attr: s["attr"],
      receiver: receiver, narrowing: narrowing.join("; "),
      classification: classification
    }
  end
end

out_csv = File.join(OUT_DIR, "narrowing.csv")
CSV.open(out_csv, "w") do |csv|
  csv << %w[file line attr receiver narrowing classification]
  results.each do |r|
    csv << [r[:file], r[:line], r[:attr], r[:receiver], r[:narrowing], r[:classification]]
  end
end

# Summary
by_class = results.group_by { |r| r[:classification] }.transform_values(&:size)
puts "Wrote #{out_csv} (#{results.size} sites for attrs: #{TARGET_ATTRS.join(', ')})"
puts ""
puts "Classification breakdown:"
by_class.sort_by { |_, n| -n }.each { |k, n| puts "  #{k.ljust(20)} #{n}" }

# Print suggestions per class
puts "\nLikely-dead candidates (typed_specific + from_locatable_attr):"
likely_dead = results.select { |r| %w[typed_specific from_locatable_attr].include?(r[:classification]) }
likely_dead.first(15).each do |r|
  puts "  #{r[:file]}:#{r[:line]}  #{r[:receiver]}.#{r[:attr]}  -> #{r[:narrowing]}"
end
puts "  ... (+#{likely_dead.size - 15} more)" if likely_dead.size > 15
