require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering)
require_relative "../ruby/mir/lower/pipeline/pipeline_context" unless defined?(PipelinePlaceholderRewriter)

RSpec.describe "ClearParser WITH MATCH records" do
  def parse_statement(source)
    ClearParser.new(Lexer.new(source).tokenize, source).send(:parse_statement)
  end

  def parse_match
    parse_statement(<<~CLEAR)
      WITH cell AS value MATCH
        WHEN LOCKED -> { PASS; } ON LockTimeout RAISE
        WHEN VERSIONED -> { PASS; }
      END
    CLEAR
  end

  def annotate(source)
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new.annotate!(program)
    program
  end

  it "parses every closed arm field into a named record" do
    node = parse_match
    locked, versioned = node.arms

    expect(locked).to be_a(AST::WithMatchArm)
    expect([locked.family, locked.body.length, locked.lock_error_clauses.length])
      .to eq([:LOCKED, 1, 1])
    expect(locked.token.text!).to eq("WHEN")
    expect([versioned.family, versioned.body.length, versioned.lock_error_clauses.length])
      .to eq([:VERSIONED, 1, 0])
  end

  it "exposes arm bodies through the canonical AST body traversal" do
    node = parse_match

    expect(AST.child_bodies(node)).to eq([node.body, *node.arms.map(&:body)])
    expect(AST.body_slots(node).map(&:body)).to eq([node.body, *node.arms.map(&:body)])
  end

  it "allows canonical body slots to replace a WITH MATCH arm body" do
    node = parse_match
    replacement = parse_statement("RETURN;")

    AST.body_slots(node)[1].replace([replacement])

    expect(node.arms.first.body).to eq([replacement])
    expect(node.arms.last.body.first).to be_a(AST::PassStmt)
  end

  it "rewrites pipeline placeholders inside arm bodies" do
    node = parse_statement("WITH cell AS value MATCH WHEN LOCKED -> { work(_); } WHEN VERSIONED -> { PASS; } END")
    call = node.arms.first.body.first
    [node, call, call.args.first].each { |item| item.full_type = Type.new(:Any) }
    context = PipelineContextState.empty.with_pipeline_values("item", nil)

    rewritten = PipelinePlaceholderRewriter.new(context).substitute(node)

    expect(rewritten).not_to equal(node)
    expect(rewritten.arms.first.body.first.args.first.name).to eq("item")
  end

  it "synthesizes policy clauses through typed VERSIONED arms" do
    program = annotate(<<~CLEAR)
      STRUCT Cfg { port: Int64 }
      FN bump!(MUTABLE cell: Cfg) RETURNS !Void
        REQUIRES cell: VERSIONED | ATOMIC
      ->
        WITH SNAPSHOT cell AS MUTABLE value MATCH
          WHEN VERSIONED -> { value.port = value.port + 1; }
          WHEN ATOMIC -> { value.port = value.port + 1; }
        END
        RETURN;
      END
    CLEAR
    function = program.statements.find { |node| node.is_a?(AST::FunctionDef) }
    versioned = function.body.first.arms.find { |arm| arm.family == :VERSIONED }

    expect(versioned.lock_error_clauses.first.selectors.first.name).to eq(:MvccConflict)
  end

  it "rejects conflict clauses on typed ATOMIC arms" do
    source = <<~CLEAR
      STRUCT Cfg { port: Int64 }
      FN bump!(MUTABLE cell: Cfg) RETURNS !Void
        REQUIRES cell: VERSIONED | ATOMIC
      ->
        WITH SNAPSHOT cell AS MUTABLE value MATCH
          WHEN VERSIONED -> { value.port = value.port + 1; } ON MvccConflict RAISE
          WHEN ATOMIC -> { value.port = value.port + 1; } ON MvccConflict RAISE
        END
        RETURN;
      END
    CLEAR

    expect { annotate(source) }.to raise_error(CompilerError, /ATOMIC.*conflict handler/i)
  end

  it "rejects multi-cell snapshots when a typed arm admits ATOMIC" do
    source = <<~CLEAR
      STRUCT Cfg { port: Int64 }
      FN update!(MUTABLE left: Cfg, MUTABLE right: Cfg) RETURNS !Void
        REQUIRES left, right: VERSIONED | ATOMIC
      ->
        WITH SNAPSHOT left AS MUTABLE a, SNAPSHOT right AS MUTABLE b MATCH
          WHEN VERSIONED -> { a.port = b.port; } ON MvccConflict RAISE
          WHEN ATOMIC -> { a.port = b.port; }
        END
        RETURN;
      END
    CLEAR

    expect { annotate(source) }.to raise_error(CompilerError, /Multi-object WITH cannot admit ATOMIC/i)
  end

  it "lowers typed arm fields into MIR dispatch records" do
    program = annotate(<<~CLEAR)
      STRUCT Counter { value: Int64 }
      FN read!(MUTABLE cell: Counter) RETURNS Int64
        REQUIRES cell: VERSIONED | LOCKED
      ->
        MUTABLE result: Int64 = 0;
        WITH cell AS value MATCH
          WHEN VERSIONED -> { result = value.value; }
          WHEN LOCKED -> { result = value.value; }
        END
        RETURN result;
      END
    CLEAR
    function = program.statements.find { |node| node.is_a?(AST::FunctionDef) }
    with_block = function.body.find { |node| node.is_a?(AST::WithBlock) }
    lowering = MIRLowering.new
    lowering.define_singleton_method(:lower_body) { |_body| [MIR::Noop.new] }

    dispatch = lowering.send(:lower_with_match_block, with_block).body.first

    expect(dispatch.arms.map(&:family)).to eq([:VERSIONED, :LOCKED])
  end

  it "rejects MATCH without a WHEN arm" do
    expect { parse_statement("WITH cell AS value MATCH END") }
      .to raise_error(ParserError, /at least one WHEN arm/i)
  end

  it "reports an unknown WITH MATCH family without fabricating one" do
    expect {
      parse_statement("WITH cell AS value MATCH WHEN LOKCED -> { PASS; } END")
    }.to raise_error(ParserError, /Unknown REQUIRES family 'LOKCED'/)
  end
end
