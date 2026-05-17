require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/backends/transpiler"  # loads compiler, annotator, lexer, parser, ast
require_relative "../src/backends/pipeline_rewriter"

RSpec.describe PipelineRewriter do
  # Real pipeline order: lex -> parse -> annotate -> rewrite.
  # PipelineRewriter runs AFTER annotation in CompilerFrontend and
  # relies on typed nodes (the AST→MIR invariant). The old helper
  # skipped annotation, an unrealistic path that masked the contract.
  def parse_and_rewrite(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new(source_code: src)
    annotator.annotate!(ast)
    PipelineRewriter.new(annotator).rewrite!(ast)
    ast
  end

  it "rewrites simple function pipelines into FuncCall" do
    ast = parse_and_rewrite(<<~CLEAR)
      FN double(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
      FN main() RETURNS Void ->
          x = 5.0;
          result = x |> double;
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
    expect(bind.value).to be_a(AST::FuncCall)
    expect(bind.value.name).to eq("double")
    expect(bind.value.args.first).to be_a(AST::Identifier)
    expect(bind.value.args.first.name).to eq("x")
  end

  it "rewrites RECOVER pipelines into OR fallback expressions" do
    ast = parse_and_rewrite(<<~CLEAR)
      FN risky(n: Int64) RETURNS !Int64 -> RETURN n; END
      FN main() RETURNS Void ->
          result = risky(1_i64) |> RECOVER(0_i64);
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }

    expect(bind.value).to be_a(AST::BinaryOp)
    expect(bind.value.op).to eq(:OR_RESCUE)
    expect(bind.value.left).to be_a(AST::FuncCall)
    expect(bind.value.left.name).to eq("risky")
    expect(bind.value.right).to be_a(AST::Literal)
    expect(bind.value.right.value).to eq(0)
  end

  it "fuses WHERE and SELECT into a single ForEach loop" do
    ast = parse_and_rewrite(<<~CLEAR)
      FN main() RETURNS Void ->
          items = [1.0, 2.0, 3.0];
          result = items |> WHERE _ > 1.0 |> SELECT _ * 2.0;
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
    
    # result = BlockExpr { __res = []; FOR __it IN items DO IF __it > 1.0 DO __res.append(__it * 2.0) END END; __res }
    expect(bind.value).to be_a(AST::BlockExpr)
    expect(bind.value.body[0]).to be_a(AST::VarDecl) # res_var init
    expect(bind.value.body[1]).to be_a(AST::ForEach)
    
    foreach = bind.value.body[1]
    expect(foreach.collection).to be_a(AST::Identifier)
    expect(foreach.collection.name).to eq("items")
    
    # Body should be IfStatement
    expect(foreach.body[0]).to be_a(AST::IfStatement)
    if_stmt = foreach.body[0]
    expect(if_stmt.condition).to be_a(AST::BinaryOp)
    expect(if_stmt.condition.op).to eq(:GT)
    
    # Then branch: VarDecl for SELECT temp, then append MethodCall
    expect(if_stmt.then_branch[0]).to be_a(AST::VarDecl)
    expect(if_stmt.then_branch[0].name.to_s).to start_with("__sel")
    expect(if_stmt.then_branch[1]).to be_a(AST::MethodCall)
    expect(if_stmt.then_branch[1].name).to eq("append")
  end

  it "SELECT result is bound to a temp VarDecl before append" do
    # Ensures struct literals are never inlined in expression position (Zig limitation).
    ast = parse_and_rewrite(<<~CLEAR)
      STRUCT S { v: Float64 }
      FN main() RETURNS Void ->
          items = [1.0, 2.0];
          result = items |> SELECT S{ v: _ };
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }

    foreach = bind.value.body[1]
    # Body: [VarDecl(__sel1 = S{v: it}), MethodCall(append, __sel1)]
    expect(foreach.body[0]).to be_a(AST::VarDecl)
    expect(foreach.body[0].name.to_s).to start_with("__sel")
    expect(foreach.body[1]).to be_a(AST::MethodCall)
    expect(foreach.body[1].name).to eq("append")
  end

  it "SELECT then SUM: VarDecl temp used in accumulator assignment" do
    ast = parse_and_rewrite(<<~CLEAR)
      STRUCT S { v: Float64 }
      FN main() RETURNS Void ->
          items = [1.0, 2.0];
          total = items |> SELECT S{ v: _ } |> SUM _.v;
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "total" }

    foreach = bind.value.body[1]
    # Body: [VarDecl(__sel1 = S{v: it}), Assignment(sum += __sel1.v)]
    expect(foreach.body[0]).to be_a(AST::VarDecl)
    sel_name = foreach.body[0].name.to_s
    expect(sel_name).to start_with("__sel")
    expect(foreach.body[1]).to be_a(AST::Assignment)
    # The RHS of the add should reference the sel var, not the struct literal directly
    rhs = foreach.body[1].value
    expect(rhs).to be_a(AST::BinaryOp)
    expect(rhs.op).to eq(:ADD)
    # Right side of add should be a field access on the temp, not a struct literal
    field_access = rhs.right
    expect(field_access).to be_a(AST::GetField)
    expect(field_access.target).to be_a(AST::Identifier)
    expect(field_access.target.name.to_s).to eq(sel_name)
  end

  it "rewrites SUM pipelines into accumulation loops" do
    ast = parse_and_rewrite(<<~CLEAR)
      FN main() RETURNS Void ->
          items = [1.0, 2.0, 3.0];
          total = items |> SUM _;
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "total" }
    
    expect(bind.value).to be_a(AST::BlockExpr)
    expect(bind.value.body[0]).to be_a(AST::VarDecl) # sum_var init to 0.0
    expect(bind.value.body[1]).to be_a(AST::ForEach)
    
    foreach = bind.value.body[1]
    expect(foreach.body[0]).to be_a(AST::Assignment)
    expect(foreach.body[0].value).to be_a(AST::BinaryOp)
    expect(foreach.body[0].value.op).to eq(:ADD)
  end
end
