require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(AST::DestructuringAssignment)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/mir/cleanup_classifier" unless defined?(CleanupClassifier)
require_relative "../ruby/mir/control_flow" unless defined?(OwnershipDataflow)
require_relative "../ruby/mir/fsm_transform/segments" unless defined?(FsmTransform::Segments)

RSpec.describe "destructuring assignment" do
  def parse_first_stmt(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    fn = ast.statements.find { |stmt| stmt.is_a?(AST::FunctionDef) }
    fn.body.first
  end

  def transpile(source)
    ZigTranspiler.new.transpile(source)
  end

  it "parses explicit typed mutable target lists" do
    stmt = parse_first_stmt(<<~CLEAR)
      FN main() RETURNS Void ->
        MUTABLE a: Int32, b: Float64 = [1_i32, 2_i32];
        RETURN;
      END
    CLEAR

    expect(stmt).to be_a(AST::DestructuringAssignment)
    expect(stmt.targets.map { |target| [target.name, target.type&.to_s, target.mutable] })
      .to eq([["a", "Int32", true], ["b", "Float64", true]])
  end

  it "classifies destructuring without moving the parser cursor" do
    parser = ClearParser.new(Lexer.new("a, b;").tokenize, "a, b;")

    expect(parser.send(:destructuring_assignment?)).to eq(true)
    expect(parser.instance_variable_get(:@pos)).to eq(0)
  end

  it "parses destructuring inside value block statements" do
    source = "a, b = [1_i64, 2_i64];"
    parser = ClearParser.new(Lexer.new(source).tokenize, source)

    expect(parser.send(:parse_statement)).to be_a(AST::DestructuringAssignment)
  end

  it "parses control-flow statements inside lambda value blocks before the result" do
    source = "cb: FN() -> Int64 = %() -> { IF TRUE THEN PASS END 1_i64 };"
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse

    lambda_body = ast.statements.first.value.body
    expect(lambda_body).to be_a(AST::BlockExpr)
    expect(lambda_body.body.first).to be_a(AST::IfStatement)
    expect(lambda_body.result).to be_a(AST::Literal)
  end

  it "coerces target type setters through Type" do
    target = AST::DestructureTarget.new(Lexer::Token.new(:VAR_ID, "a", 1, 1), "a", nil, false)

    target.type = "Int64"

    expect(target.type).to be_a(Type)
    expect(target.type.to_s).to eq("Int64")
  end

  it "routes destructuring values through loop cleanup extension classification" do
    target = AST::DestructureTarget.new(Lexer::Token.new(:VAR_ID, "a", 1, 1), "a", Type.new(:Int64), false)
    value = AST::Identifier.new(Lexer::Token.new(:VAR_ID, "outer", 1, 5), "outer")
    value.full_type = Type.new(:Int64)
    stmt = AST::DestructuringAssignment.new(nil, [target], value)

    expect { CleanupClassifier.send(:stamp_loop_extensions!, [stmt], {}) }.not_to raise_error
  end

  it "treats destructuring as a statement-like expression container" do
    target = AST::DestructureTarget.new(Lexer::Token.new(:VAR_ID, "a", 1, 1), "a", Type.new(:Int64), false)
    stmt = AST::DestructuringAssignment.new(nil, [target], AST::Literal.new(1, :Int64))

    expect(LoopFrameAnalysis.statement_like_expression_container?(stmt)).to eq(true)
  end

  it "classifies destructuring NEXT values as FSM suspend points" do
    target = AST::DestructureTarget.new(Lexer::Token.new(:VAR_ID, "a", 1, 1), "a", Type.new(:Int64), false)
    promise = AST::Identifier.new(Lexer::Token.new(:VAR_ID, "promise", 1, 5), "promise")
    promise.full_type = Type.new(:"~Int64")
    value = AST::NextExpr.new(nil, promise)
    value.full_type = Type.new(:Int64)
    stmt = AST::DestructuringAssignment.new(nil, [target], value)

    expect(FsmTransform::Segments.send(:classify_suspend, stmt)).to be_a(FsmTransform::Segments::NextSuspend)
  end

  it "emits direct Zig destructuring declarations and assignments" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Int64 ->
        MUTABLE a: Int64, b: Int64 = [1_i64, 2_i64];
        a = a + 1_i64;
        RETURN a + b;
      END
    CLEAR

    expect(zig).to include("var a: i64, const b: i64 = __hoist_")
    expect(zig).to include("return CheatLib.intAdd(a, b);")

    reassignment = transpile(<<~CLEAR)
      FN main() RETURNS Int64 ->
        MUTABLE a: Int64 = 0_i64;
        MUTABLE b: Int64 = 0_i64;
        a, b = [1_i64, 2_i64];
        RETURN a + b;
      END
    CLEAR
    expect(reassignment).to include("a, b = __hoist_")
  end

  it "uses fixed identifier shape when destructuring non-literal values" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Int64 ->
        pair: [2]Int64 = [13_i64, 14_i64];
        a, b = pair;
        RETURN a + b;
      END
    CLEAR

    expect(zig).to include("const a, const b = pair;")
  end

  it "supports mixed existing and new mutable targets" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Int64 ->
        MUTABLE a: Int64 = 0_i64;
        a, MUTABLE b: Int64 = [1_i64, 2_i64];
        b = b + 1_i64;
        RETURN a + b;
      END
    CLEAR

    expect(zig).to include("a, var b: i64 = __hoist_")
    expect(zig).to include("return CheatLib.intAdd(a, b);")
  end

  it "supports discard targets" do
    zig = transpile(<<~CLEAR)
      FN main() RETURNS Int64 ->
        a: Int64, _ = [1_i64, 2_i64];
        RETURN a;
      END
    CLEAR

    expect(zig).to include("const a: i64, _ = __hoist_")
  end

  it "rejects arity mismatch and dynamic RHS shapes" do
    expect {
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          a: Int64, b: Int64 = [1_i64];
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /target count 2 does not match RHS size 1/)

    expect {
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          xs: []Int64 = [];
          a: Int64, b: Int64 = xs;
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /requires a fixed-size RHS/)

    expect {
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          a: Bool, b: Bool = [1_i64, 2_i64];
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /Type Mismatch|expected/)

    expect {
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          a, b = ["x", "y"];
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /requires a copyable RHS/)

    expect {
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          a: Int64 = 0_i64;
          b: Int64 = 0_i64;
          a, b = [1_i64, 2_i64];
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /immutable|ASSIGN_VAR_IMMUTABLE/)

    expect {
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE a: Int64 = 0_i64;
          WITH RESTRICT a {
            a, MUTABLE b: Int64 = [1_i64, 2_i64];
          }
        END
      CLEAR
    }.to raise_error(CompilerError, /currently borrowed/)
  end

  it "falls back to plain immutable errors when no mutable fix is locatable" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        a: Int64 = 0_i64;
        b: Int64 = 0_i64;
        a, b = [1_i64, 2_i64];
        RETURN;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    ann = SemanticAnnotator.new
    allow(ann).to receive(:build_declare_mutable_fix).and_return(nil)
    FixCollector.disable!

    expect { ann.annotate!(ast) }.to raise_error(CompilerError, /immutable/)
  end
end
