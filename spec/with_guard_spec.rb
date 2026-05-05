require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/transpiler"

RSpec.describe "WITH GUARD clauses" do
  def parse(src)
    tokens = Lexer.new(src).tokenize
    Parser.new(tokens, src).parse
  end

  def annotate(src)
    ast = parse(src)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  it "parses GUARD after the AS alias" do
    ast = parse(<<~CLEAR)
      FN main() RETURNS Void ->
        WITH EXCLUSIVE c AS y GUARD y.value > 0 { RETURN; }
        RETURN;
      END
    CLEAR

    with_node = ast.statements.first.body.first
    cap = with_node.capabilities.first
    expect(cap[:alias]).to eq("y")
    expect(cap[:guard_expr]).to be_a(AST::BinaryOp)
  end

  it "accepts a pure predicate over the guarded alias" do
    ast = annotate(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN positive?(c: Counter) RETURNS Bool ->
        RETURN c.value > 0;
      END
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD positive?(y) {
          v = y.value;
        }
        RETURN;
      END
    CLEAR

    with_node = ast.statements.last.body[1]
    expect(with_node.capabilities.first[:guard_expr].type_info.resolved).to eq(:Bool)
  end

  it "allows repeated use of the guarded alias inside predicate arguments" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN above?(c: Counter, n: Int64) RETURNS Bool ->
          RETURN c.value > n;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 2 } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD above?(y, y.value - 1) {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects guard references to any symbol besides the guarded alias" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          other = 0;
          WITH EXCLUSIVE c AS y GUARD y.value > other {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /can only reference the guarded alias 'y'.*other/m)
  end

  it "rejects mutable guarded aliases in v1" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS MUTABLE y GUARD y.value > 0 {
            y.value = 2;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /GUARD aliases cannot be MUTABLE/)
  end

  it "rejects non-Bool guard expressions" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD y.value {
            v = y.value;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /GUARD expression must return Bool/)
  end

  it "rejects impure guard predicates" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { name: String }
        FN main() RETURNS !Void ->
          c = Counter{ name: "12" } @shared:locked;
          WITH EXCLUSIVE c AS y GUARD toInt(y.name) > 0 {
            n = 1;
          }
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /GUARD clauses must be pure.*toInt.*can fail/m)
  end

  it "supports guarded polymorphic access" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN positive?(c: Counter) RETURNS Bool ->
          RETURN c.value > 0;
        END
        FN read(c: SHARED Counter) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH POLYMORPHIC c AS y GUARD positive?(y) {
            v = y.value;
          }
          RETURN;
        END
        FN main() RETURNS Void ->
          c = Counter{ value: 1 } @shared:locked;
          read(c);
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "wraps the lowered WITH body in an if guard" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        }
        RETURN;
      END
    CLEAR

    expect(zig).to include("if ((y.value > 0))")
  end

  it "parses ON GuardFail for guarded WITH blocks" do
    ast = parse(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        } ON GuardFail PASS
        RETURN;
      END
    CLEAR

    with_node = ast.statements.last.body[1]
    expect(with_node.lock_error_clause[:selectors].first[:name]).to eq(:GuardFail)
  end

  it "parses ON GuardFail RETURN for guarded WITH blocks" do
    ast = parse(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Bool ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          RETURN TRUE;
        } ON GuardFail RETURN FALSE
      END
    CLEAR

    clause = ast.statements.last.body[1].lock_error_clause
    expect(clause[:action]).to eq(:return)
    expect(clause[:value]).to be_a(AST::Literal)
  end

  it "allows ON GuardFail on guard-only non-locking access" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 };
          WITH BORROWED c AS y GUARD y.value > 0 {
            v = y.value;
          } ON GuardFail PASS
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "rejects unrelated ON selectors on guard-only non-locking access" do
    expect {
      annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 1 };
          WITH BORROWED c AS y GUARD y.value > 0 {
            v = y.value;
          } ON LockTimeout PASS
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /do not match any error.*GuardFail/m)
  end

  it "lowers ON GuardFail PASS as the false branch of the guard" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        } ON GuardFail PASS
        RETURN;
      END
    CLEAR

    expect(zig).to include("if ((y.value > 0))")
    expect(zig).to include("else")
    expect(zig).to include("break :__with_")
  end

  it "lowers ON GuardFail RAISE with the GuardFail error name" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS !Void ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          v = y.value;
        } ON GuardFail RAISE
        RETURN;
      END
    CLEAR

    expect(zig).to include("ErrorName.GuardFail")
    expect(zig).to include("WITH GUARD predicate failed")
  end

  it "lowers ON GuardFail RETURN for ordinary guarded WITH blocks" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Bool ->
        c = Counter{ value: 1 } @shared:locked;
        WITH EXCLUSIVE c AS y GUARD y.value > 0 {
          RETURN TRUE;
        } ON GuardFail RETURN FALSE
      END
    CLEAR

    expect(zig).to include("if ((y.value > 0))")
    expect(zig).to include("else")
    expect(zig).to include("return false;")
  end

  it "uses the flow helper for guarded universal polymorphic WITH returns" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN positive(c: Counter) RETURNS !Bool ->
        WITH POLYMORPHIC c AS y GUARD y.value > 0 {
          RETURN TRUE;
        } ON GuardFail RETURN FALSE
      END
    CLEAR

    expect(zig).to include("CheatLib.polymorphicMutateFlow(")
    expect(zig).to include(".ret_commit")
    expect(zig).to include(".ret_no_commit")
    expect(zig).to include("return __poly_flow.ret")
  end

  it "keeps mutation-only universal polymorphic WITH on the non-flow helper" do
    zig = transpile(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN bump!(MUTABLE c: Counter) RETURNS !Void ->
        WITH POLYMORPHIC c AS y {
          y.value = y.value + 1;
        }
        RETURN;
      END
    CLEAR

    expect(zig).to include("CheatLib.polymorphicMutate(")
    expect(zig).not_to include("CheatLib.polymorphicMutateFlow(")
  end
end
