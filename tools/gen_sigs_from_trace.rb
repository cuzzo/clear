# typed: false
# frozen_string_literal: true
#
# Aggregate JSONL observations from tools/trace_sigs.rb across all
# runs (specs / transpile-tests / benchmarks --leak / examples) and
# emit Sorbet `sig {}` blocks inline above each observed method in
# src/.
#
# Type policy per slot (param / kwarg / return):
#   - 0 observations             -> skip slot, don't sig method
#   - 1 class, never nil         -> tight class
#   - 1 class + nil seen         -> T.nilable(Class)
#   - 2-4 classes, no nil        -> T.any(C1, C2, ...)
#   - 2-4 classes + nil seen     -> T.nilable(T.any(...))
#   - 5+ classes                 -> T.untyped (too noisy to be useful)
#
# Method skipped entirely if:
#   - Already has a sig (line above def matches /\s*sig\s*\{/)
#   - Always raised (no return observation)
#   - Class isn't defined in src/ (anonymous, stdlib, etc.)
#
# Source param NAMES come from Prism (we don't get reliable param
# names from TracePoint — `parameters` would but we'd need to hook
# the original method, not the prepend wrapper).
#
# Usage:
#   bundle exec ruby tools/gen_sigs_from_trace.rb            # apply
#   DRY_RUN=1 bundle exec ruby tools/gen_sigs_from_trace.rb  # report only

require "json"
require "set"
require "prism"

OBS_DIR = File.expand_path("../tmp/sig_obs", __dir__)
SRC_DIR = File.expand_path("../src", __dir__)
DRY_RUN = ENV["DRY_RUN"] == "1"

# Slots that observed too many distinct classes get T.untyped. Most
# real-world contracts are <=4 (e.g. AST nodes that share an interface).
WIDE_THRESHOLD = 4

# Param types are widened to T.untyped by default. Return types remain
# observation-tight. Rationale: a method observed only with one shape
# of input is almost always too narrow (callers exercise sibling shapes
# on un-tested paths), but its return type is determined entirely by
# the body and is safer to lock down. Override with TIGHT_PARAMS=1 if
# you want observation-tight params for a high-precision pass.
LOOSE_PARAMS = ENV.fetch("TIGHT_PARAMS", "0") != "1"

# Body-nil-widening coverage threshold. When a method has at least this
# many observed calls AND never returned nil in any of them, trust the
# observation and skip widening to T.nilable even if the body has
# `return nil` / `if`-without-else / etc paths. Most large-corpus runs
# show that "return nil unless rare_invariant" guards are dead code in
# practice; widening forces ~100s of unnecessary nil-checks at call
# sites. Override with TRUST_HIGH_COVERAGE=0 for the strict policy.
COVERAGE_THRESHOLD = ENV.fetch("COVERAGE_THRESHOLD", "100").to_i
TRUST_HIGH_COVERAGE = ENV.fetch("TRUST_HIGH_COVERAGE", "1") == "1"

# Aggregate: { [klass, method, kind] => merged_record }
records = {}

Dir.glob(File.join(OBS_DIR, "*.jsonl")).each do |file|
  File.foreach(file) do |line|
    obs = JSON.parse(line)
    key = [obs["klass"], obs["method"], obs["kind"].to_sym]
    rec = records[key] ||= {
      calls: 0,
      params: [],
      kw: {},
      returns: Set.new,
      raised: Set.new,
      block_given_count: 0,
    }
    rec[:calls] += obs["calls"]
    rec[:block_given_count] += obs["block_given_count"]
    obs["params"].each_with_index do |slot, i|
      rec[:params][i] ||= Set.new
      slot.each { |c| rec[:params][i] << c }
    end
    obs["kw"].each do |k, v|
      rec[:kw][k] ||= Set.new
      v.each { |c| rec[:kw][k] << c }
    end
    obs["returns"].each { |c| rec[:returns] << c }
    obs["raised"].each { |c| rec[:raised] << c }
  end
end

puts "Loaded #{records.size} (klass, method, kind) records from #{OBS_DIR}"

# Static analysis: walk a Prism DefNode's body to detect whether any
# control-flow path returns nil. Catches:
#   - `return nil` / `return` (explicit early-return)
#   - `return X if cond` / `return X unless cond` (modifier returns
#     where the implicit fall-through after the modifier is the
#     end-of-method's last expression — but if the modifier itself
#     evaluates to nil on the not-taken branch, last-expr matters)
#   - method bodies whose final expression can be nil (an `if` without
#     `else`, a `case` with no default, a chain ending in `unless`/`if`)
#
# Runtime observation alone can't tell us about un-exercised paths, so
# pairing observation with static body inspection catches the
# Type.from_node / tense_type / wrapped_type pattern (legitimate
# nilable returns the corpus only saw on the non-nil path).
def body_can_return_nil?(def_node)
  walk_for_nil_return(def_node.body)
end

def walk_for_nil_return(node)
  return false unless node
  case node
  when Prism::ReturnNode
    args = node.arguments&.arguments
    return true if args.nil? || args.empty?
    args.any? { |a| nil_literal?(a) }
  when Prism::IfNode
    # An `if` without an `else` branch falls through to nil.
    sub = node.subsequent
    return true if sub.nil?
    walk_for_nil_return(node.statements) || walk_for_nil_return(sub)
  when Prism::UnlessNode
    sub = node.else_clause
    return true if sub.nil?
    walk_for_nil_return(node.statements) || walk_for_nil_return(sub)
  when Prism::CaseNode
    # `case` without an `else` branch falls through to nil.
    return true if node.else_clause.nil?
    node.conditions.any? { |c| walk_for_nil_return(c) } || walk_for_nil_return(node.else_clause)
  when Prism::WhenNode, Prism::ElseNode, Prism::InNode
    walk_for_nil_return(node.statements)
  when Prism::StatementsNode
    # Last expression is the implicit return; check it. Earlier
    # statements only matter if they have explicit returns.
    last_idx = node.body.length - 1
    node.body.each_with_index do |stmt, i|
      if i == last_idx
        return true if walk_for_nil_return(stmt) || expression_can_be_nil?(stmt)
      else
        return true if has_explicit_nil_return?(stmt)
      end
    end
    false
  else
    has_explicit_nil_return?(node)
  end
end

# Detect a top-level `return nil`-style escape inside an expression.
# Symmetric to body_can_return_nil?: detect whether any path in the
# body returns a non-nil value. Used to flag observation-only-nil
# methods whose body actually has reachable non-nil branches (the
# corpus probably hit only the early-exit path).
def body_can_return_non_nil?(def_node)
  walk_for_non_nil_return(def_node.body)
end

def walk_for_non_nil_return(node)
  return false unless node
  case node
  when Prism::ReturnNode
    args = node.arguments&.arguments
    return false if args.nil? || args.empty?
    args.any? { |a| !nil_literal?(a) }
  when Prism::IfNode
    walk_for_non_nil_return(node.statements) || walk_for_non_nil_return(node.subsequent)
  when Prism::UnlessNode
    walk_for_non_nil_return(node.statements) || walk_for_non_nil_return(node.else_clause)
  when Prism::CaseNode
    node.conditions.any? { |c| walk_for_non_nil_return(c) } || walk_for_non_nil_return(node.else_clause)
  when Prism::WhenNode, Prism::ElseNode, Prism::InNode
    walk_for_non_nil_return(node.statements)
  when Prism::StatementsNode
    last_idx = node.body.length - 1
    node.body.each_with_index do |stmt, i|
      if i == last_idx
        return true if !nil_literal?(stmt) && !expression_is_only_nil?(stmt)
        return true if walk_for_non_nil_return(stmt)
      else
        return true if has_explicit_non_nil_return?(stmt)
      end
    end
    false
  else
    !nil_literal?(node)
  end
end

def has_explicit_non_nil_return?(node)
  return false unless node
  case node
  when Prism::ReturnNode
    args = node.arguments&.arguments
    return false if args.nil? || args.empty?
    args.any? { |a| !nil_literal?(a) }
  when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode,
       Prism::CaseNode, Prism::BeginNode, Prism::StatementsNode,
       Prism::WhenNode, Prism::ElseNode, Prism::InNode
    if node.respond_to?(:child_nodes)
      node.child_nodes.compact.any? { |c| has_explicit_non_nil_return?(c) }
    else
      false
    end
  else
    false
  end
end

def expression_is_only_nil?(node)
  node.is_a?(Prism::NilNode)
end

def has_explicit_nil_return?(node)
  return false unless node
  case node
  when Prism::ReturnNode
    args = node.arguments&.arguments
    args.nil? || args.empty? || args.any? { |a| nil_literal?(a) }
  when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode,
       Prism::CaseNode, Prism::BeginNode, Prism::StatementsNode,
       Prism::WhenNode, Prism::ElseNode, Prism::InNode
    if node.respond_to?(:child_nodes)
      node.child_nodes.compact.any? { |c| has_explicit_nil_return?(c) }
    else
      false
    end
  else
    false
  end
end

# Stdlib methods whose return type is intrinsically nilable. Sorbet
# tracks these accurately, so a method whose body's last expression is
# one of these calls also returns nilable.
NILABLE_STDLIB_METHODS = Set[
  :find, :detect, :assoc, :rassoc, :index, :rindex,
  :first, :last, :pop, :shift, :peek,
  :fetch, :dig, :match,
  :[],  # Array#[] / Hash#[] both nilable
  # Project-specific iterators that return T.nilable. These are
  # frequent enough that hardcoding is simpler than the multi-pass
  # alternative; add new entries when an autogen 7005 error points to
  # a callsite whose method ends in one of these.
  :walk_body,
].freeze

# Detect when an expression's value can be nil:
# - `nil` literal
# - `if`/`unless` without `else` branch
# - `case` without `else` branch
# - `&&` / `||` where one side can be nil
# - call to a stdlib method that returns nilable (Array#find, Hash#dig)
def expression_can_be_nil?(node)
  return true if node.nil?
  case node
  when Prism::NilNode then true
  when Prism::IfNode
    # No subsequent (else) branch → evaluates to nil on the not-taken
    # branch.
    node.subsequent.nil?
  when Prism::UnlessNode
    node.else_clause.nil?
  when Prism::CaseNode
    node.else_clause.nil?
  when Prism::AndNode, Prism::OrNode
    expression_can_be_nil?(node.left) || expression_can_be_nil?(node.right)
  when Prism::CallNode
    NILABLE_STDLIB_METHODS.include?(node.name)
  else
    false
  end
end

def nil_literal?(node)
  node.is_a?(Prism::NilNode)
end

# Detect a def whose keyword-param ordering Sorbet rejects: a required
# keyword (RequiredKeywordParameterNode) that appears AFTER an optional
# keyword (OptionalKeywordParameterNode) in source order.
# Methods whose entire body is a single nilable-accessor call:
#   def foo; @stack.last; end
#   def foo; @hash[k]; end
#   def foo; @list.first; end
#
# These methods inherently can return nil (the underlying accessor
# can), but they're often called inside contexts where the caller
# knows nil is impossible. Sigging them as T.nilable(X) cascades into
# 100s of caller-side errors because Sorbet can't narrow through
# method-call returns. Sig as T.untyped to preserve the existing
# call-site idiom.
NILABLE_ACCESSORS = Set[:last, :first, :pop, :peek, :shift, :[]].freeze

def delegating_accessor?(def_node)
  body = def_node.body
  return false unless body.is_a?(Prism::StatementsNode)
  return false unless body.body.length == 1
  stmt = body.body.first
  return false unless stmt.is_a?(Prism::CallNode)
  return false unless NILABLE_ACCESSORS.include?(stmt.name)
  recv = stmt.receiver
  recv.is_a?(Prism::InstanceVariableReadNode) || recv.is_a?(Prism::LocalVariableReadNode)
end

def bad_kw_order?(params)
  saw_optional = false
  params.keywords.each do |kw|
    if kw.is_a?(Prism::OptionalKeywordParameterNode)
      saw_optional = true
    elsif kw.is_a?(Prism::RequiredKeywordParameterNode) && saw_optional
      return true
    end
  end
  false
end

# Detect whether a method body uses `yield` (and thus accepts an
# implicit block, even without `&blk` in the param list).
def method_yields?(def_node)
  walk_for_yield(def_node.body)
end

def walk_for_yield(node)
  return false unless node
  return true if node.is_a?(Prism::YieldNode)
  # Don't descend into nested DefNodes — `yield` inside an inner def
  # belongs to that def, not the outer one.
  return false if node.is_a?(Prism::DefNode)
  return false unless node.respond_to?(:child_nodes)
  node.child_nodes.compact.any? { |c| walk_for_yield(c) }
end

# Type formatter.
def fmt_type(class_set, allow_nilable: true)
  # Drop empty/nil names (anonymous classes from .class.name = nil → "").
  class_set = class_set.reject { |c| c.nil? || c.empty? }
  return "T.untyped" if class_set.empty?
  has_nil = class_set.include?("NilClass")
  others = class_set.reject { |c| c == "NilClass" }
  return "NilClass" if others.empty?
  # Drop classes with funky names (Sorbet won't accept them).
  others = others.reject { |c| c.include?("#") || c.start_with?("Sorbet::Private::") }
  return has_nil ? "T.untyped" : "T.untyped" if others.empty?

  # Normalize TrueClass / FalseClass to T::Boolean. A method observed
  # returning only TrueClass might still return FalseClass on an
  # un-exercised path; the wider type avoids override-incompatibility
  # errors when subclasses' contracts differ.
  if others.all? { |c| c == "TrueClass" || c == "FalseClass" }
    base = "T::Boolean"
    return has_nil && allow_nilable ? "T.nilable(#{base})" : base
  end

  # AST::* and MIR::* are polymorphic hierarchies. A single observation
  # of e.g. AST::FuncCall is almost certainly too narrow — callers pass
  # AST::Identifier, AST::GetField, etc., on un-exercised paths. Widen
  # to T.untyped to avoid Sorbet "method does not exist" errors at
  # typed:true. Multi-class observations (already a union) stay as-is.
  if others.size == 1 && (others.first.start_with?("AST::") || others.first.start_with?("MIR::"))
    # T.nilable(T.untyped) is the same as T.untyped (Sorbet 5070).
    return "T.untyped"
  end

  if others.size > WIDE_THRESHOLD
    # T.nilable(T.untyped) is the same as T.untyped (Sorbet 5070).
    return "T.untyped"
  end
  if others.size == 1
    base = others.first
  else
    # Multi-class observation. Cross-hierarchy unions (e.g.
    # `T.any(Integer, String, Array)`) cause caller-side errors when
    # methods exist on one class but not others. Without a known common
    # ancestor, T.untyped is more permissive and avoids the cascade.
    base = "T.untyped"
  end
  # T.nilable(T.untyped) is the same as T.untyped (Sorbet 5070).
  return "T.untyped" if has_nil && allow_nilable && base == "T.untyped"
  has_nil && allow_nilable ? "T.nilable(#{base})" : base
end

# Build Prism index: per file, map (class_name, method_name, kind) ->
# DefNode + param info, and remember `extend T::Sig` presence per class
# so we know whether to add it.
class FileIndex
  attr_reader :src_lines, :defs, :class_sig_extended, :class_def_lines

  def initialize(file)
    @file = file
    @src_lines = File.readlines(file)
    parsed = Prism.parse_file(file)
    @defs = {}                  # [class, method, kind] => DefNode
    @class_sig_extended = {}    # class_name => bool
    @class_def_lines = {}       # class_name => insert-line (1-based) just below `class X` line
    walk(parsed.value, [])
  end

  def walk(node, scope)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = constant_path_name(node.constant_path)
      full = (scope + [name]).join("::")
      @class_sig_extended[full] ||= false
      @class_def_lines[full] ||= node.location.start_line + 1
      detect_sig_extend(node, full)
      child_walk(node.body, scope + [name])
    when Prism::DefNode
      cls = scope.join("::")
      kind = node.receiver.is_a?(Prism::SelfNode) ? :class : :instance
      @defs[[cls, node.name.to_s, kind]] = node
      child_walk(node.body, scope)
    when Prism::SingletonClassNode
      child_walk(node.body, scope)
    else
      node.respond_to?(:child_nodes) && node.child_nodes.compact.each { |c| walk(c, scope) }
    end
  end

  def child_walk(body, scope)
    return unless body
    if body.respond_to?(:body) && body.body.respond_to?(:each)
      body.body.each { |c| walk(c, scope) }
    elsif body.respond_to?(:child_nodes)
      body.child_nodes.compact.each { |c| walk(c, scope) }
    end
  end

  def detect_sig_extend(node, full)
    body = node.body
    return unless body
    stmts = body.respond_to?(:body) ? body.body : []
    stmts.each do |stmt|
      if stmt.is_a?(Prism::CallNode) && stmt.name == :extend &&
         stmt.arguments&.arguments&.any? { |a| sig_module?(a) }
        @class_sig_extended[full] = true
      end
    end
  end

  def sig_module?(arg)
    return false unless arg.is_a?(Prism::ConstantPathNode)
    parts = []
    n = arg
    while n.is_a?(Prism::ConstantPathNode)
      parts.unshift(n.name.to_s)
      n = n.parent
    end
    parts.unshift(n.name.to_s) if n.is_a?(Prism::ConstantReadNode)
    parts == %w[T Sig]
  end

  def constant_path_name(node)
    case node
    when Prism::ConstantReadNode
      node.name.to_s
    when Prism::ConstantPathNode
      parts = []
      n = node
      while n.is_a?(Prism::ConstantPathNode)
        parts.unshift(n.name.to_s)
        n = n.parent
      end
      parts.unshift(n.name.to_s) if n.is_a?(Prism::ConstantReadNode)
      parts.join("::")
    end
  end
end

# Index every src/ file.
indexes = {}
Dir.glob(File.join(SRC_DIR, "**/*.rb")).each do |file|
  indexes[file] = FileIndex.new(file)
end

# Reverse map: [class, method, kind] -> file
def_lookup = {}
indexes.each do |file, idx|
  idx.defs.each_key { |k| def_lookup[k] = file }
end

# Plan the inserts.
# Per file: { line => sig_text } and { line => "  extend T::Sig\n" }
# (must keep order so we apply bottom-up)
inserts = Hash.new { |h, k| h[k] = [] }

stats = {
  total_records: records.size,
  matched_def: 0,
  no_def: 0,
  already_sigged: 0,
  always_raised: 0,
  yield_skipped: 0,
  applied: 0,
  tight_params: 0,
  loose_params: 0,
  tight_returns: 0,
  loose_returns: 0,
  files_touched: Set.new,
}

records.each do |(klass, mname, kind), rec|
  file = def_lookup[[klass, mname, kind]]
  unless file
    stats[:no_def] += 1
    next
  end
  stats[:matched_def] += 1
  idx = indexes[file]
  def_node = idx.defs[[klass, mname, kind]]

  # Skip if already sigged.
  start_line = def_node.location.start_line
  prev = idx.src_lines[start_line - 2]
  if prev&.match?(/\s*sig\s*\{/)
    stats[:already_sigged] += 1
    next
  end

  # Skip if every observation raised (no real return type to record).
  if rec[:returns].empty? && !rec[:raised].empty?
    stats[:always_raised] += 1
    next
  end

  params = def_node.parameters
  sig_parts = []
  loose = false
  tight = false

  # Skip methods that yield without an explicit `&blk` param. Sorbet
  # requires both the def and sig to declare the block — adding only
  # `blk: T.untyped` to the sig is rejected. These need manual
  # treatment (add `&blk` to the def, then re-run autogen).
  if (params.nil? || !params.block) && method_yields?(def_node)
    stats[:yield_skipped] += 1
    next
  end

  # Skip methods whose def has a required keyword AFTER an optional
  # keyword. Sorbet (5049) rejects sigs for these defs even when the
  # sig itself is in canonical order. Fixing requires reordering the
  # def — out of scope for autogen.
  if params && bad_kw_order?(params)
    stats[:bad_kw_order_skipped] ||= 0
    stats[:bad_kw_order_skipped] += 1
    next
  end

  if params
    # Sorbet validates sigs by grouping params: required-positional,
    # optional-positional, rest, required-keyword, optional-keyword,
    # keyword-rest, block. Required kws and optional kws can be
    # interleaved in the def, but the SIG must list keyreqs before
    # optkeys regardless of source order.
    params.requireds.each_with_index do |p, i|
      slot = rec[:params][i] || Set.new
      type = LOOSE_PARAMS ? "T.untyped" : fmt_type(slot)
      tight ||= !type.include?("T.untyped")
      loose ||= type.include?("T.untyped")
      sig_parts << "#{p.name}: #{type}"
    end
    params.optionals.each_with_index do |p, i|
      slot = rec[:params][params.requireds.size + i] || Set.new
      type = LOOSE_PARAMS ? "T.untyped" : fmt_type(slot)
      sig_parts << "#{p.name}: #{type}"
    end
    if params.rest
      rest_name = params.rest.name&.to_s || "args"
      sig_parts << "#{rest_name}: T.untyped"
    end
    keyreqs, optkeys = params.keywords.partition do |kw|
      kw.is_a?(Prism::RequiredKeywordParameterNode)
    end
    keyreqs.each do |kw|
      slot = rec[:kw][kw.name.to_s] || Set.new
      type = LOOSE_PARAMS ? "T.untyped" : fmt_type(slot)
      sig_parts << "#{kw.name}: #{type}"
    end
    optkeys.each do |kw|
      slot = rec[:kw][kw.name.to_s] || Set.new
      type = LOOSE_PARAMS ? "T.untyped" : fmt_type(slot)
      sig_parts << "#{kw.name}: #{type}"
    end
    if params.keyword_rest
      krest_name = params.keyword_rest.name&.to_s || "kwargs"
      sig_parts << "#{krest_name}: T.untyped"
    end
    if params.block
      bname = params.block.name&.to_s || "blk"
      sig_parts << "#{bname}: T.untyped"
    end
  end

  # Static analysis: if the method body has a path that returns nil
  # (explicit `return nil`, bare `return`, or an `unless` / `if` guard
  # whose fall-through is the implicit nil at end-of-method), widen the
  # return type to T.nilable. Runtime observation may have missed these
  # paths if the corpus didn't exercise them.
  #
  # Coverage override: when observation is high-volume AND never saw
  # nil, trust observation even if the body has nil-returning paths.
  # The empirical evidence says those paths are dead at runtime (or so
  # rare the corpus never hit them) — they cascade into 7003 "method
  # does not exist on NilClass" errors at every call site if widened.
  # A method with 100+ observed calls that never returned nil is a
  # strong signal the nil path is unreachable in practice.
  # Detect single-expression "delegating accessor" methods:
  # `def foo; @ivar.last; end`, `def foo; @ivar[k]; end`, etc.
  # These are inherent-nilable but the method's *contract* in the
  # codebase is usually "the caller knows what's there". Sigging them
  # as `T.nilable(X)` cascades into every caller (Sorbet won't narrow
  # method-call returns through guards, only locals). Widen to
  # T.untyped instead — preserves the call-site idiom without forcing
  # local binding rewrites everywhere.
  if delegating_accessor?(def_node)
    rec[:returns] = Set["T.untyped"]
  end

  body_nilable = body_can_return_nil?(def_node)
  observation_includes_nil = rec[:returns].include?("NilClass")
  observation_only_nil = rec[:returns].size == 1 && observation_includes_nil

  # Reconcile body-static-analysis vs runtime observation. Sorbet at
  # `# typed: true` cascades each nilable return into N "method does
  # not exist on NilClass" errors at every caller without a nil-check
  # — so a nilable sig that's "correct" by observation can introduce
  # 100s of caller-side errors. We only emit `T.nilable(X)` when both
  # the body AND observation agree on it.
  #
  # Decision matrix:
  #
  #   body has nil-paths + obs saw nil       -> T.nilable(X) (consistent;
  #                                              callers that don't
  #                                              nil-check are real bugs)
  #   body has nil-paths + obs never nil     -> AMBIGUOUS (paths likely
  #                                              dead). T.untyped — keeps
  #                                              `&.` legal and doesn't
  #                                              cascade caller errors.
  #   no nil-paths        + obs only nil     -> ANOMALY. T.untyped.
  #   no nil-paths        + obs sometimes nil -> T.nilable(X). Trust the
  #                                              observation — sorbet
  #                                              runtime checks WILL fire
  #                                              if we lie (specs break).
  #   no nil-paths        + obs always X      -> returns(X) (tight)
  #
  # The asymmetry is deliberate: it's worse to mark something nilable
  # incorrectly (cascade) than to miss a rare nil case (one local crash).
  ret_type =
    if body_nilable && !observation_includes_nil
      "T.untyped"
    elsif observation_only_nil && body_can_return_non_nil?(def_node)
      "T.untyped"
    else
      fmt_type(rec[:returns])
    end
  # Always emit `returns(...)`. Don't use `void` based on observation —
  # `void` returns Sorbet's VOID sentinel to callers, breaking any code
  # that uses the result. A method observed always returning nil might
  # still have callers that check the return value.
  ret_clause = "returns(#{ret_type})"

  if ret_type.include?("T.untyped")
    stats[:loose_returns] += 1
  else
    stats[:tight_returns] += 1
  end

  if tight && !loose
    stats[:tight_params] += 1
  elsif loose
    stats[:loose_params] += 1
  end

  sig_line = sig_parts.empty? ? "sig { #{ret_clause} }" : "sig { params(#{sig_parts.join(', ')}).#{ret_clause} }"

  def_indent = idx.src_lines[start_line - 1][/^\s*/]
  inserts[file] << [start_line, "#{def_indent}#{sig_line}\n", klass]
  stats[:applied] += 1
  stats[:files_touched] << file
end

# Apply per file: insert require 'sorbet-runtime' if missing, then
# extend T::Sig if needed, then sig lines bottom-up.
inserts.each do |file, items|
  idx = indexes[file]
  classes_needing_extend = items.map { |_, _, k| k }.uniq.reject { |c| idx.class_sig_extended[c] }
  classes_needing_extend.each do |c|
    line = idx.class_def_lines[c]
    next unless line
    items << [line, "#{idx.src_lines[line - 1][/^\s*/]}  extend T::Sig\n\n", c]
    idx.class_sig_extended[c] = true
  end

  src_lines = idx.src_lines.dup

  # Ensure sorbet-runtime is required. Skip if already present anywhere
  # in the file (could be via require_relative).
  has_runtime = src_lines.any? { |l| l.include?("sorbet-runtime") }
  unless has_runtime
    # Insert after frozen_string_literal / encoding magic comments.
    insert_at = 0
    src_lines.each_with_index do |line, i|
      if line.start_with?("#") || line.strip.empty?
        insert_at = i + 1
      else
        break
      end
    end
    src_lines.insert(insert_at, "require \"sorbet-runtime\"\n", "\n")
    # Bump line numbers for subsequent inserts (we added 2 lines).
    items = items.map { |line, text, k| [line + 2, text, k] }
  end

  items.sort_by { |line, _, _| -line }.each do |line, text, _|
    src_lines.insert(line - 1, text)
  end

  if DRY_RUN
    puts "DRY: #{file} -> +#{items.size} insertions"
  else
    File.write(file, src_lines.join)
  end
end

puts
puts "==== Stats ===="
puts "  Total observation records:      #{stats[:total_records]}"
puts "  Matched src/ method def:        #{stats[:matched_def]}"
puts "  No matching def in src/:        #{stats[:no_def]}"
puts "  Already sigged (skipped):       #{stats[:already_sigged]}"
puts "  Always raised (skipped):        #{stats[:always_raised]}"
puts "  Yield-without-&blk (skipped):   #{stats[:yield_skipped]}"
puts "  Sigs applied:                   #{stats[:applied]}"
puts "  Files touched:                  #{stats[:files_touched].size}"
puts "  Tight param sets (no T.untyped): #{stats[:tight_params]}"
puts "  Loose param sets (some T.untyped): #{stats[:loose_params]}"
puts "  Tight return types:             #{stats[:tight_returns]}"
puts "  Loose (T.untyped) returns:      #{stats[:loose_returns]}"
puts
puts DRY_RUN ? "(DRY_RUN — no files modified)" : "Applied to disk."
