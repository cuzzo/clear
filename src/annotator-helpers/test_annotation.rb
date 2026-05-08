# typed: true
require "sorbet-runtime"
require 'set'

# TestAnnotation — annotator-side handling of CLEAR's test grammar:
# `TEST` / `WHEN` / `TEST THAT` blocks, `ASSERT_RAISES`, `BENCHMARK`,
# `SMASH`, `PROFILE`, and `STUB` declarations.
#
# Mixed into SemanticAnnotator. All methods rely on the annotator's
# instance state (current_scope, with_new_scope, visit, etc.) and
# are intentionally thin: each visit_* method type-checks its
# children and stamps `full_type = :Void` on the test-grammar node.
#
# The strict-test mode IO-coverage check (`validate_strict_io!`)
# lives here too because it's only invoked from `visit_WhenBlock`.
# See examples/testing/*.cht for grammar examples.

module TestAnnotation
  # Known IO builtins that don't appear in @fn_nodes (runtime-level).
  # Used by `validate_strict_io!` to demand a STUB for any reachable
  # IO call when strict-test mode is on.
  IO_BUILTINS = %w[tcpRead tcpWrite accept connect readFile writeFile
                   readLine readLinePrompt listDir listAll fileSize
                   socketRead socketWrite socketClose].to_set.freeze

  def visit_TestBlock(node)
    T.bind(self, SemanticAnnotator) rescue nil
    with_new_scope do
      node.setup.each { |s| visit(s) }
      visit_test_lets(node)
      visit_test_hook_bodies(node)
      node.whens.each { |w| visit_WhenBlock(w) }
    end
    node.full_type = :Void
  end

  def visit_WhenBlock(node)
    T.bind(self, SemanticAnnotator) rescue nil
    node.setup.each { |s| visit(s) }
    visit_test_lets(node)
    visit_test_hook_bodies(node)

    # Strict test mode: verify all IO functions are stubbed in this WHEN block.
    if @strict_test
      stubbed_fns = node.setup
        .select { |s| s.is_a?(AST::StubDecl) }
        .map { |s| s.function_name }
        .to_set
      node.tests.each { |t| validate_strict_io!(t, stubbed_fns) }
    end

    node.tests.each do |t|
      with_new_scope(current_scope) do
        visit_TestThat(t)
      end
    end
    node.benchmarks.each { |b| visit(b) }
    node.full_type = :Void
  end

  # Visit LET fixture RHS expressions and declare each name in the
  # current scope. The names then resolve correctly in BEFORE EACH
  # bodies, AFTER EACH bodies, sibling LETs, and every TEST THAT
  # body inside the enclosing block. Lowering injects the actual
  # variable declarations at the top of each test body.
  def visit_test_lets(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.respond_to?(:lets)
    (node.lets || []).each do |let_node|
      visit(let_node.expr)
      let_type = let_node.expr.full_type
      # Declare as immutable (LET is by definition non-rebindable);
      # tests can still field-mutate / call methods on the bound
      # value just like a normal `name = expr;` decl.
      current_scope.declare(let_node.name, let_node, let_type, false, false, nil, :stack)
      og_declare(let_node.name, let_node, let_type) if respond_to?(:og_declare, true)
    end
  end

  # Visit BEFORE EACH / AFTER EACH / BEFORE ALL / AFTER ALL hook
  # bodies so their statements are type-checked against the enclosing
  # scope. EACH bodies run once per TEST THAT (composed by lowering);
  # ALL bodies become standalone Zig test blocks but still need to be
  # annotated against the enclosing scope so type errors surface at
  # compile time.
  def visit_test_hook_bodies(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.respond_to?(:before_each)
    (node.before_each || []).each { |body| body.each { |s| visit(s) } }
    (node.after_each  || []).each { |body| body.each { |s| visit(s) } }
    (node.before_all  || []).each { |body| body.each { |s| visit(s) } }
    (node.after_all   || []).each { |body| body.each { |s| visit(s) } }
  end

  def visit_TestThat(node)
    T.bind(self, SemanticAnnotator) rescue nil
    visit_stmts(node.body)
    node.full_type = :Void
  end

  def visit_AssertRaises(node)
    T.bind(self, SemanticAnnotator) rescue nil
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_BenchmarkStmt(node)
    T.bind(self, SemanticAnnotator) rescue nil
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_SmashStmt(node)
    T.bind(self, SemanticAnnotator) rescue nil
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_ProfileStmt(node)
    T.bind(self, SemanticAnnotator) rescue nil
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_StubDecl(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # Visit the value for type checking if it's an expression.
    # node.value is either an AST expression or a Symbol like :CAPTURES.
    # Only descend into AST expressions; Symbols are leaf metadata.
    visit(node.value) if node.value.is_a?(AST::Locatable)
    # CAPTURES stubs declare a variable in the current scope.
    if node.kind == :captures
      cap_name = node.value  # the variable name string
      # Declare as Int64 counter (tracks number of calls captured)
      current_scope.declare(cap_name, node, :Int64, true, false, nil, :stack)
      og_declare(cap_name, node, :Int64)
    end
    node.full_type = :Void
  end

  # Strict-test mode coverage check: walk the call graph from a
  # TEST THAT body and demand that every reachable IO-effect call
  # has been stubbed in the enclosing WHEN block. Both runtime-level
  # IO builtins (file/network) and user-defined functions whose
  # effect set includes :BLOCKING / :EXTERN qualify as IO.
  def validate_strict_io!(test_that, stubbed_fns)
    T.bind(self, SemanticAnnotator) rescue nil
    calls = scan_for_calls(test_that.body).first
    visited = Set.new
    queue = calls.to_a.dup

    until queue.empty?
      name = queue.shift
      next if visited.include?(name)
      visited << name
      next if stubbed_fns.include?(name)

      # Check if it's a known IO builtin
      if IO_BUILTINS.include?(name)
        error!(test_that, :STRICT_TEST_NEEDS_STUB, name: name)
        next
      end

      # Check if it's a user function with BLOCKING/EXTERN effects
      fn = @fn_nodes[name]
      if fn&.effects
        has_io = fn.effects.include?(:BLOCKING) || fn.effects.include?(:EXTERN)
        if has_io
          error!(test_that, :STRICT_TEST_HAS_IO_EFFECTS, name: name, effects: fn.effects.to_a.join(', '))
        end
      end

      # Continue down the call chain
      (@call_graph[name] || []).each { |c| queue << c }
    end
  end
end
