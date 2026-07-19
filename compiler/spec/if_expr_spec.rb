require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/type" unless defined?(Type)
require_relative "../ruby/ast/source_error" unless defined?(CompilerError)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

def compile_if_expr_src(src)
  ZigTranspiler.new.transpile(src, test_mode: true)
end

def parse_if_expr_src(src)
  tokens = Lexer.new(src).tokenize
  ClearParser.new(tokens, src).parse
end

def annotate_if_expr_src(src)
  tokens = Lexer.new(src).tokenize
  ast    = ClearParser.new(tokens, src).parse
  SemanticAnnotator.new.annotate!(ast)
  ast
end

RSpec.describe "IF/MATCH as expressions" do

  # =========================================================================
  # ClearParser: IF in expression position
  # =========================================================================
  describe "ClearParser" do
    it "parses 'x = IF cond THEN a ELSE b END' as BindExpr with IfStatement value" do
      ast = parse_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          x = IF TRUE THEN 1 ELSE 2 END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      expect(bind).not_to be_nil
      expect(bind.value).to be_a(AST::IfStatement)
    end

    it "parses 'MUTABLE x = IF ...' as VarDecl with IfStatement value" do
      ast = parse_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE x = IF TRUE THEN 1 ELSE 2 END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      decl = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      expect(decl).to be_a(AST::VarDecl)
      expect(decl.value).to be_a(AST::IfStatement)
    end

    it "parses 'RETURN IF ...' as ReturnNode with IfStatement value" do
      ast = parse_if_expr_src(<<~CLEAR)
        FN pick(flag: Bool) RETURNS Int64 ->
          RETURN IF flag THEN 1 ELSE 2 END;
        END
      CLEAR
      fn   = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "pick" }
      ret  = fn.body.find { |s| s.is_a?(AST::ReturnNode) }
      expect(ret.value).to be_a(AST::IfStatement)
    end

    it "parses 'x = MATCH ...' as BindExpr with MatchStatement value" do
      ast = parse_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          n = 1;
          x = PARTIAL MATCH n START
            1 -> "one",
            DEFAULT -> "other"
          END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      expect(bind).not_to be_nil
      expect(bind.value).to be_a(AST::MatchStatement)
    end

    it "parses ELSE_IF chain used as expression" do
      ast = parse_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          x = IF TRUE THEN 1 ELSE_IF FALSE THEN 2 ELSE 3 END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      expect(bind.value).to be_a(AST::IfStatement)
      expect(bind.value.else_branch.first).to be_a(AST::IfStatement)
    end
  end

  # =========================================================================
  # Annotator: type inference and promotion
  # =========================================================================
  describe "Annotator" do
    it "promotes IF expression to expr_mode with correct type" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          x = IF TRUE THEN 1 ELSE 2 END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      if_node = bind.value
      expect(if_node.expr_mode).to be true
      expect(if_node.resolved_type).to eq(:Int64)
    end

    it "promotes IF expressions used in struct field assignments" do
      ast = annotate_if_expr_src(<<~CLEAR)
        STRUCT Settings { enabled: Bool }
        FN configure(MUTABLE settings: Settings, override: ?Bool) RETURNS Void ->
          settings.enabled = IF override == NIL THEN FALSE ELSE override END;
          RETURN;
        END
      CLEAR
      fn = ast.statements.find { |stmt| stmt.is_a?(AST::FunctionDef) }
      assignment = fn.body.find { |stmt| stmt.is_a?(AST::Assignment) }
      expect(assignment.value).to be_a(AST::IfStatement)
      expect(assignment.value.expr_mode).to be true
      expect(assignment.value.resolved_type).to eq(:Bool)
    end

    it "promotes MATCH expression to expr_mode with correct type" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          n = 1;
          x = PARTIAL MATCH n START
            1 -> "one",
            DEFAULT -> "other"
          END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      match_node = bind.value
      expect(match_node.expr_mode).to be true
      expect(match_node.resolved_type).to eq(:String)
    end

    it "infers declared variable type from IF expression result" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          flag = TRUE;
          x = IF flag THEN 10 ELSE 20 END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      expect(bind.full_type.resolved).to eq(:Int64)
    end

    it "promotes symbol IF expression" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          flag = TRUE;
          status = IF flag THEN :ok ELSE :error END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "status" }
      expect(bind.value.expr_mode).to be true
      expect(bind.full_type.symbol?).to be true
    end

    it "promotes IF expressions used as struct literal field values" do
      ast = annotate_if_expr_src(<<~CLEAR)
        STRUCT Shape {
          payload: ?String@symbol
        }

        FN main(flag: Bool) RETURNS Void ->
          s = Shape{ payload: IF flag THEN :ok ELSE NIL END };
          RETURN;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      bind = fn.body.find { |s| s.respond_to?(:name) && s.name == "s" }
      if_node = bind.value.fields.fetch("payload")
      expect(if_node.expr_mode).to be true
      expect(if_node.full_type.optional?).to be true
      expect(T.must(if_node.full_type.wrapped_type).symbol?).to be true
    end

    it "promotes IF expressions used as binary operands" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN matches(value: ?Int64) RETURNS Bool ->
          RETURN (IF value != NIL THEN value ELSE NIL END) == 42;
        END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "matches" }
      ret = fn.body.find { |s| s.is_a?(AST::ReturnNode) }
      if_node = ret.value.left
      expect(if_node).to be_a(AST::IfStatement)
      expect(if_node.expr_mode).to be true
      expect(if_node.full_type.optional?).to be true
      expect(T.must(if_node.full_type.wrapped_type).resolved).to eq(:Int64)
    end

    it "promotes Bool IF expression" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN pick(n: Int64) RETURNS Bool ->
          RETURN IF n > 0 THEN TRUE ELSE FALSE END;
        END
      CLEAR
      fn  = ast.statements.first
      ret = fn.body.find { |s| s.is_a?(AST::ReturnNode) }
      expect(ret.value.expr_mode).to be true
      expect(ret.value.resolved_type).to eq(:Bool)
    end

    it "promotes ELSE_IF chain as expression" do
      ast = annotate_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          n = 2;
          x = IF n == 1 THEN "one" ELSE_IF n == 2 THEN "two" ELSE "other" END;
          RETURN;
        END
      CLEAR
      body = ast.statements.first.body
      bind = body.find { |s| s.respond_to?(:name) && s.name == "x" }
      outer = bind.value
      nested = outer.else_branch.first
      expect(outer.expr_mode).to be true
      expect(nested.expr_mode).to be true
      expect(outer.resolved_type).to eq(:String)
    end

    # --- Error cases ---

    it "errors when IF expression is missing ELSE branch" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN main() RETURNS Void ->
            x = IF TRUE THEN 1 END;
            RETURN;
          END
        CLEAR
      }.to raise_error(StandardError, /ELSE/)
    end

    it "errors when IF expression THEN/ELSE branches have incompatible types" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN main() RETURNS Void ->
            x = IF TRUE THEN 1 ELSE "text" END;
            RETURN;
          END
        CLEAR
      }.to raise_error(StandardError, /incompatible types.*Int64.*String|incompatible types.*String.*Int64/)
    end

    it "errors when IF expression THEN branch returns Int64 and ELSE returns Bool" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN main() RETURNS Void ->
            x = IF TRUE THEN 1 ELSE FALSE END;
            RETURN;
          END
        CLEAR
      }.to raise_error(StandardError, /incompatible types/)
    end

    it "errors when RETURN IF branches have incompatible types" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN pick() RETURNS Int64 ->
            RETURN IF TRUE THEN 1 ELSE "text" END;
          END
        CLEAR
      }.to raise_error(StandardError, /incompatible types/)
    end

    it "errors when MATCH expression branches have incompatible types" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN main() RETURNS Void ->
            n = 1;
            x = PARTIAL MATCH n START
              1 -> 1,
              2 -> "two",
              DEFAULT -> 3
            END;
            RETURN;
          END
        CLEAR
      }.to raise_error(StandardError, /incompatible types/)
    end

    it "errors when MATCH expression has DEFAULT with a different type" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN main() RETURNS Void ->
            n = 1;
            x = PARTIAL MATCH n START
              1 -> "one",
              DEFAULT -> 99
            END;
            RETURN;
          END
        CLEAR
      }.to raise_error(StandardError, /incompatible types/)
    end

    it "coerces MATCH payload branches to an explicitly declared union result" do
      ast = annotate_if_expr_src(<<~CLEAR)
        STRUCT Named { value: Int64 }
        STRUCT Text { value: String }
        UNION Value { Named: Named, Text: Text }

        FN choose(input: Value) RETURNS Value ->
          result: Value = MATCH input START
            Value.Named AS named -> named,
            Value.Text AS text -> text
          END;
          RETURN result;
        END
      CLEAR

      fn = ast.statements.find { |stmt| stmt.is_a?(AST::FunctionDef) }
      declaration = T.must(fn).body.find { |stmt| stmt.respond_to?(:name) && stmt.name == "result" }
      match = T.must(declaration).value
      expect(match).to be_a(AST::MatchStatement)
      expect(match.full_type!.resolved).to eq(:Value)
    end

    it "errors when MATCH expression is missing DEFAULT (non-exhaustive)" do
      expect {
        annotate_if_expr_src(<<~CLEAR)
          FN main() RETURNS Void ->
            n = 1;
            x = PARTIAL MATCH n START
              1 -> "one",
              2 -> "two"
            END;
            RETURN;
          END
        CLEAR
      }.to raise_error(StandardError, /DEFAULT.*MATCH|MATCH.*DEFAULT/)
    end
  end

  # =========================================================================
  # Zig code generation
  # =========================================================================
  describe "Zig code generation" do
    it "emits expression IF as labeled block with break statements" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN pick(flag: Bool) RETURNS Int64 ->
          RETURN IF flag THEN 1 ELSE 2 END;
        END
      CLEAR
      expect(zig).to include("__if_")
      expect(zig).to include("break :")
      expect(zig).to include("if (flag)")
    end

    it "emits both branch values in labeled block" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN pick(flag: Bool) RETURNS Int64 ->
          RETURN IF flag THEN 10 ELSE 20 END;
        END
      CLEAR
      expect(zig).to include("10")
      expect(zig).to include("20")
      expect(zig).to include("break :")
    end

    it "emits IF expression assigned to variable" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          flag = TRUE;
          x = IF flag THEN 1 ELSE 2 END;
          RETURN;
        END
      CLEAR
      expect(zig).to include("__if_")
      expect(zig).to include("break :")
    end

    it "emits symbol IF expression correctly" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN status(ok: Bool) RETURNS String ->
          RETURN IF ok THEN "ok" ELSE "error" END;
        END
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      expect(zig).to include('"ok"')
      expect(zig).to include('"error"')
      expect(zig).to include("break :")
    end

    it "emits MATCH expression with DEFAULT as labeled block" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN label(n: Int64) RETURNS String ->
          RETURN PARTIAL MATCH n START
            1 -> "one",
            2 -> "two",
            DEFAULT -> "other"
          END;
        END
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      expect(zig).to include("__match_")
      expect(zig).to include("break :")
      expect(zig).to include('"one"')
      expect(zig).to include('"other"')
    end

    it "emits ELSE_IF chain as nested labeled blocks" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN grade(n: Int64) RETURNS String ->
          RETURN IF n >= 90 THEN "A" ELSE_IF n >= 80 THEN "B" ELSE "C" END;
        END
        FN main() RETURNS Void ->
          RETURN;
        END
      CLEAR
      expect(zig).to include("break :")
      expect(zig).to include('"A"')
      expect(zig).to include('"B"')
      expect(zig).to include('"C"')
    end

    it "does not emit extra cleanup for implicitly-copyable results" do
      zig = compile_if_expr_src(<<~CLEAR)
        FN main() RETURNS Void ->
          flag = TRUE;
          x = IF flag THEN 42 ELSE 0 END;
          RETURN;
        END
      CLEAR
      # Only the user-emitted fn clearMain body should be checked — the runtime
      # boilerplate always has deinit calls for scheduler/allocator teardown.
      start = zig.index("fn clearMain") || 0
      stop  = zig.index(/\npub fn /, start) || zig.length
      user_fn = zig[start...stop]
      expect(user_fn).not_to include("deinit")
    end
  end

end
