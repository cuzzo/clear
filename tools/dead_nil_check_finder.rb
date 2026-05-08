#!/usr/bin/env ruby
# Find dead nil checks in src/*.rb using Prism.
#
# Detects patterns where a `&.` or `.nil?` is provably redundant
# because the receiver is already known to be non-nil in the
# enclosing scope.
#
# Patterns detected:
#
#   1. Truthy-guard scope:
#        if foo                           |    return unless foo
#          foo&.bar       # DEAD          |    foo&.bar     # DEAD
#        end                              |
#
#   2. is_a? narrowing:
#        if foo.is_a?(SomeClass)
#          foo&.method   # DEAD (is_a? implies non-nil)
#        end
#
#   3. unless foo.nil? / unless foo.nil?:
#        unless foo.nil?
#          foo&.bar      # DEAD
#        end
#
#   4. Reassignment from literal:
#        foo = "string"
#        foo&.length     # DEAD
#
# Pure read-only — prints a report; does not modify files.
#
# Usage:
#   bundle exec ruby tools/dead_nil_check_finder.rb [src/]
#
# Output format (sortable by file/line):
#   src/foo.rb:42  PATTERN  receiver&.method   reason

require "prism"

class DeadCheckFinder
  Finding = Struct.new(:file, :line, :pattern, :code, :reason)

  LITERAL_NON_NIL_TYPES = [
    Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode,
    Prism::FloatNode, Prism::TrueNode, Prism::FalseNode,
    Prism::ArrayNode, Prism::HashNode, Prism::RegularExpressionNode,
    Prism::LambdaNode,
  ].freeze

  def initialize
    @findings = []
  end

  def scan(file)
    src = File.read(file)
    parsed = Prism.parse(src)
    return if parsed.failure?
    visit_methods(file, parsed.value, [])
  end

  def report
    @findings.sort_by { |f| [f.file, f.line] }.each do |f|
      puts "#{f.file}:#{f.line}  #{f.pattern}  #{f.code.strip[0..70]}  -- #{f.reason}"
    end
    puts
    by_pattern = @findings.group_by(&:pattern).map { |p, fs| [p, fs.size] }
    puts "Total: #{@findings.size}"
    by_pattern.sort_by { |_, n| -n }.each { |p, n| puts "  #{n}\t#{p}" }
  end

  private

  # Walk every DefNode and analyze its body with a flow-sensitive scan.
  def visit_methods(file, node, ancestors)
    case node
    when Prism::DefNode
      analyze_method(file, node)
    end
    return unless node.respond_to?(:compact_child_nodes)
    node.compact_child_nodes.each { |c| visit_methods(file, c, ancestors + [node]) }
  end

  # Per-method: walk statements, tracking which locals are known non-nil.
  # `non_nil` is a Set<String> of local-var names known non-nil at this point.
  def analyze_method(file, def_node)
    body = def_node.body
    return unless body.is_a?(Prism::StatementsNode)
    walk_stmts(file, body.body, Set.new)
  end

  def walk_stmts(file, stmts, non_nil)
    stmts.each do |stmt|
      check_dead_calls(file, stmt, non_nil)
      update_facts!(stmt, non_nil)
    end
  end

  # Update non_nil set based on a statement's effect.
  def update_facts!(stmt, non_nil)
    case stmt
    when Prism::LocalVariableWriteNode
      name = stmt.name.to_s
      if non_nil_value?(stmt.value)
        non_nil.add(name)
      else
        non_nil.delete(name)
      end
    when Prism::ReturnNode, Prism::BreakNode, Prism::NextNode
      # No-op for facts continuing
    when Prism::IfNode
      # `return unless x` / `raise unless x` patterns:
      # IfNode where condition uses .nil? + body has return/raise
      handle_guard_modifier(stmt, non_nil)
    when Prism::UnlessNode
      handle_unless_modifier(stmt, non_nil)
    end
  end

  # `return unless x` is parsed as: IfNode { predicate: x; statements: [Return] }
  # Wait — actually `return unless x` is UnlessNode in Prism with the return as body.
  # Let me handle the 2 modifier shapes:
  #   `unless x then return end` → UnlessNode predicate=x, statements=[ReturnNode]
  #   `return unless x` → UnlessModifier — same UnlessNode shape
  def handle_unless_modifier(unless_node, non_nil)
    pred = unless_node.predicate
    stmts = unless_node.statements&.body || []
    if stmts.any? { |s| terminator?(s) } && (name = simple_var_name(pred))
      # After this point, we know `name` was truthy (otherwise we'd have terminated).
      non_nil.add(name)
    end
  end

  def handle_guard_modifier(if_node, non_nil)
    pred = if_node.predicate
    stmts = if_node.statements&.body || []
    return unless stmts.any? { |s| terminator?(s) }
    # `if x.nil? then return end` → after, x is non-nil
    if (name = nil_check_var(pred))
      non_nil.add(name)
    end
  end

  def terminator?(node)
    node.is_a?(Prism::ReturnNode) || node.is_a?(Prism::BreakNode) ||
      node.is_a?(Prism::NextNode) ||
      (node.is_a?(Prism::CallNode) && [:raise, :error!, :fixable!].include?(node.name))
  end

  # Recurse into structural nodes that contain executable code.
  # On entering an `if cond` body, we add facts about cond.
  def check_dead_calls(file, node, non_nil)
    return unless node.respond_to?(:compact_child_nodes)
    case node
    when Prism::CallNode
      check_safe_nav(file, node, non_nil)
      node.compact_child_nodes.each { |c| check_dead_calls(file, c, non_nil) }
    when Prism::IfNode
      branch_facts = if_branch_facts(node.predicate)
      then_facts = non_nil + branch_facts[:then_non_nil]
      walk_stmts_in_branch(file, node.statements&.body || [], then_facts)
      # else / elsif
      visit_else(file, node.consequent, non_nil + branch_facts[:else_non_nil])
    when Prism::UnlessNode
      branch_facts = if_branch_facts(node.predicate)
      # `unless x` body runs when x is FALSY
      then_facts = non_nil + branch_facts[:else_non_nil]
      else_facts = non_nil + branch_facts[:then_non_nil]
      walk_stmts_in_branch(file, node.statements&.body || [], then_facts)
      visit_else(file, node.consequent, else_facts)
    when Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode, Prism::UntilNode
      node.compact_child_nodes.each { |c| check_dead_calls(file, c, non_nil) }
    when Prism::BlockNode, Prism::LambdaNode
      # Block body: separate scope for new locals; existing facts carry in
      walk_stmts_in_branch(file, (node.body.is_a?(Prism::StatementsNode) ? node.body.body : []), non_nil.dup)
    else
      node.compact_child_nodes.each { |c| check_dead_calls(file, c, non_nil) }
    end
  end

  def walk_stmts_in_branch(file, stmts, non_nil)
    stmts.each do |s|
      check_dead_calls(file, s, non_nil)
      update_facts!(s, non_nil)
    end
  end

  def visit_else(file, node, non_nil)
    return unless node
    case node
    when Prism::ElseNode
      walk_stmts_in_branch(file, node.statements&.body || [], non_nil)
    when Prism::IfNode, Prism::UnlessNode
      check_dead_calls(file, node, non_nil)
    end
  end

  # Check if this CallNode is a `receiver&.method` and the receiver is non-nil.
  def check_safe_nav(file, call, non_nil)
    if call.safe_navigation?
      recv = call.receiver
      if recv
        if recv.is_a?(Prism::SelfNode)
          add_finding(file, call, "DEAD_SAFE_NAV_SELF", "self is never nil")
        else
          name = simple_var_name(recv)
          if name && non_nil.include?(name)
            add_finding(file, call, "DEAD_SAFE_NAV", "#{name} known non-nil at this scope")
          end
        end
      end
    end
    # Dead .nil? on a known-non-nil receiver
    if call.name == :nil? && call.receiver
      name = simple_var_name(call.receiver)
      if name && non_nil.include?(name)
        add_finding(file, call, "DEAD_NIL_CHECK", "#{name} known non-nil — .nil? always false")
      end
    end
  end

  # Returns { then_non_nil: [names], else_non_nil: [names] } given a predicate.
  def if_branch_facts(pred)
    facts = { then_non_nil: [], else_non_nil: [] }
    case pred
    when Prism::LocalVariableReadNode
      facts[:then_non_nil] << pred.name.to_s
    when Prism::CallNode
      # x.is_a?(Type) → then x non-nil
      if pred.name == :is_a? && (name = simple_var_name(pred.receiver))
        facts[:then_non_nil] << name
      end
      # x.nil? → else x non-nil
      if pred.name == :nil? && (name = simple_var_name(pred.receiver))
        facts[:else_non_nil] << name
      end
      # !x.nil? handled as unary !
      # x.respond_to?(:foo) → then x non-nil
      if pred.name == :respond_to? && (name = simple_var_name(pred.receiver))
        facts[:then_non_nil] << name
      end
    when Prism::AndNode
      facts[:then_non_nil].concat(if_branch_facts(pred.left)[:then_non_nil])
      facts[:then_non_nil].concat(if_branch_facts(pred.right)[:then_non_nil])
    end
    facts
  end

  def simple_var_name(node)
    node.is_a?(Prism::LocalVariableReadNode) ? node.name.to_s : nil
  end

  def nil_check_var(pred)
    if pred.is_a?(Prism::CallNode) && pred.name == :nil?
      simple_var_name(pred.receiver)
    end
  end

  def non_nil_value?(node)
    return false unless node
    return true if LITERAL_NON_NIL_TYPES.any? { |k| node.is_a?(k) }
    # Constructor calls: SomeClass.new(...) is non-nil (unless impl returns nil)
    if node.is_a?(Prism::CallNode) && node.name == :new
      return true
    end
    false
  end

  def add_finding(file, call, pattern, reason)
    line = call.location.start_line
    @findings << Finding.new(file, line, pattern, source_at(file, line), reason)
  end

  def source_at(file, line)
    @file_lines ||= {}
    @file_lines[file] ||= File.readlines(file)
    @file_lines[file][line - 1] || ""
  end
end

dir = ARGV[0] || "src"
finder = DeadCheckFinder.new
Dir.glob("#{dir}/**/*.rb").each { |f| finder.scan(f) }
finder.report
