# typed: true
require "sorbet-runtime"

require_relative "../ast/lexer"
require_relative "../ast/parser"
require_relative "../annotator"

# Shared helpers for the migration-suggester family
# (AtomicMigrationSuggester, AtomicPtrMigrationSuggester, future
# upgrades). Each suggester provides its own eligibility policy
# (candidate_decl_info + classify_with_block!); this module owns the
# AST-walking boilerplate that's identical across all of them.
#
# Why this lives separately rather than being inherited from a base
# class: the suggesters are `module_function`-style modules (so the
# doctor calls `Suggester.analyze(source)` directly), and Ruby's
# class-vs-module split makes mixing module_function with class
# inheritance awkward. A plain module that each suggester `extend`s
# gives them the shared methods at module level cleanly.
#
# Public surface (call from the per-suggester `analyze` entry point):
#   run_analyze(source) { |suggester| ... } -- parses + annotates,
#                                              iterates fns, returns
#                                              candidates. Yields the
#                                              suggester itself so the
#                                              policy methods (defined
#                                              on each module) can be
#                                              called as `self.foo`.
module MigrationSuggesterHelpers
    extend T::Sig

  # Shared `analyze` shape: parse + annotate + walk fns + collect.
  # Each suggester's `analyze(source)` calls this with `self`; the
  # suggester provides the per-fn policy via `analyze_fn`.
  sig { params(source: String).returns(T::Array[Hash]) }
  def run_analyze(source)
    tokens = Lexer.new(source).tokenize
    ast    = Parser.new(tokens, source).parse
    ann    = SemanticAnnotator.new
    ann.source_code = source
    ann.annotate!(ast)
    candidates = []
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      candidates.concat(analyze_fn(stmt, ann))
    end
    candidates.sort_by { |c| c[:line] || 0 }
  rescue StandardError
    []
  end

  # Shared per-fn analyze: collect candidate decls (Phase 1), then
  # walk body to classify uses + disqualify (Phase 2). The suggester
  # provides:
  #   - candidate_decl_info(node, annotator) -- returns a hash or nil
  #   - classify_with_block!(with_node, candidates) -- mutates entries
  # `classify_uses!` (also shared) handles the non-WITH cases
  # (Identifier disqualify, FuncCall/MethodCall arg disqualify,
  # ReturnNode disqualify).
  sig { params(fn_node: AST::FunctionDef, annotator: SemanticAnnotator).returns(T.nilable(T::Array[Hash])) }
  def analyze_fn(fn_node, annotator)
    candidates = {}
    walk_recursive(fn_node.body) do |node|
      decl = candidate_decl_info(node, annotator)
      candidates[decl[:name]] = decl if decl
    end
    return [] if candidates.empty?

    walk_recursive(fn_node.body) do |node|
      next if node.is_a?(AST::FunctionDef) && !node.equal?(fn_node)
      classify_uses!(node, candidates)
    end

    candidates.values.reject { |c| c[:disqualified] || c[:n_uses] == 0 }
  end

  # AST.walk_body covers control-flow nodes (IF / WHILE / FOR / WITH /
  # BG / DO / TestBlock) but does NOT descend into expression-position
  # bodies -- most importantly the `bg = BG { ... }` shape, where the
  # BgBlock lives on the surrounding BindExpr.value and never gets
  # yielded directly. Suggesters need to see WITH blocks nested inside
  # those BG bodies, so descend into VarDecl / BindExpr / Assignment
  # values too.
  sig { params(body: Array, visitor: T.untyped).returns(T.nilable(Array)) }
  def walk_recursive(body, &visitor)
    AST.walk_body(body) do |node|
      yield node
      case node
      when AST::VarDecl, AST::BindExpr, AST::Assignment
        v = node.value
        if v.is_a?(AST::BgBlock) || v.is_a?(AST::BgStreamBlock)
          walk_recursive(v.body, &visitor)
        end
      end
    end
  end

  # Generic non-WITH disqualifications:
  #   - bare Identifier reference (alias used for something other than
  #     a WITH capture)
  #   - FuncCall / MethodCall arg (binding escapes via fn-arg)
  #   - ReturnNode value (binding escapes via RETURN)
  # Per-suggester WITH handling is dispatched to the suggester's
  # `classify_with_block!`.
  sig { params(node: T.untyped, candidates: T::Hash[String, Hash]).returns(T.nilable(T::Array[Hash])) }
  def classify_uses!(node, candidates)
    case node
    when AST::WithBlock
      classify_with_block!(node, candidates)
    when AST::Identifier
      info = candidates[node.name]
      info[:disqualified] = true if info
    when AST::FuncCall, AST::MethodCall
      (node.args || []).each do |arg|
        next unless arg.is_a?(AST::Identifier)
        info = candidates[arg.name]
        info[:disqualified] = true if info
      end
    when AST::ReturnNode
      val = node.value
      info = val.is_a?(AST::Identifier) ? candidates[val.name] : nil
      info[:disqualified] = true if info
    end
  end

  # Class-name-based control-flow detection. Used by the body-stmt
  # eligibility check to disqualify nested control-flow inside a WITH
  # body (the body shape we can't 1:1 rewrite into atomic ops).
  sig { params(stmt: AST::IfStatement).returns(T::Boolean) }
  def control_flow_stmt?(stmt)
    return false unless stmt.respond_to?(:class)
    name = stmt.class.name.to_s
    name.include?("IfStatement") || name.include?("WhileLoop") ||
      name.include?("ForRange") || name.include?("ForEach") ||
      name.include?("WithBlock") || name.include?("MatchStatement") ||
      name.include?("WhileBindLoop") || name.include?("DoBlock") ||
      name.include?("BgBlock") || name.include?("BgStreamBlock") ||
      name.include?("ReturnNode")
  end

  # Recursive AST walk: does `expr` reference an Identifier with this
  # name anywhere? Used by both suggesters' body-eligibility checks
  # to detect bare alias references (which DISQUALIFY) vs field-only
  # references (which are eligible reads).
  sig { params(expr: T.untyped, alias_name: String).returns(T::Boolean) }
  def references_alias?(expr, alias_name)
    found = false
    walk = lambda do |n|
      return if found
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass
      when Array then n.each { |x| walk.call(x) }
      when AST::Identifier
        found = true if n.name == alias_name
      else
        n.each_pair { |_, v| walk.call(v) } if n.respond_to?(:each_pair)
      end
    end
    walk.call(expr)
    found
  end

  # Recursive AST walk: are all references to `alias_name` either
  # absent or restricted to a `target.field` GetField? `field_name`
  # optional -- when nil, ANY field on the alias is eligible
  # (atomic-ptr semantics: read any field of the snapshot); when set,
  # only the matching field is eligible (atomic-primitive semantics:
  # the single primitive field is the cell).
  sig { params(expr: AST::BindExpr, alias_name: String, field_name: T.untyped).returns(T::Boolean) }
  def rhs_uses_alias_only_for_field_get?(expr, alias_name, field_name = nil)
    eligible = true
    walk = lambda do |n|
      return unless eligible
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass
      when Array then n.each { |x| walk.call(x) }
      when AST::Identifier
        eligible = false if n.name == alias_name
      when AST::GetField
        if n.target.is_a?(AST::Identifier) && n.target.name == alias_name
          # alias.field -- check field_name when constrained.
          eligible = false if field_name && n.field.to_s != field_name
        else
          n.each_pair { |_, v| walk.call(v) } if n.respond_to?(:each_pair)
        end
      else
        n.each_pair { |_, v| walk.call(v) } if n.respond_to?(:each_pair)
      end
    end
    walk.call(expr)
    eligible
  end
end
