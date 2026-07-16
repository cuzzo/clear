require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator)

RSpec.describe "ClearParser effect records" do
  def parse_function(effect_clause = "")
    source = <<~CLEAR
      FN work(n: Int64) RETURNS !Int64 #{effect_clause} ->
        RETURN n;
      END
    CLEAR
    ClearParser.new(Lexer.new(source).tokenize, source).parse.statements.first
  end

  it "uses an empty named parse result when EFFECTS is absent" do
    function = parse_function

    expect(function.effects_decl).to be_nil
    expect(function.effects_span).to be_nil
    expect(function.max_depth_n).to be_nil
    expect(function.tight_reentrance).to be(false)
  end

  it "records a plain reentrant clause with its source span" do
    function = parse_function("EFFECTS REENTRANT")

    expect(function.effects_decl).to eq(:reentrant)
    expect(function.effects_span).to be_a(AST::EffectSpan)
    expect(function.effects_span.start_token.text!).to eq("EFFECTS")
    expect(function.effects_span.end_token.text!).to eq("REENTRANT")
    expect(function.tight_reentrance).to be(false)
  end

  it "records a standalone TIGHT modifier" do
    function = parse_function("EFFECTS REENTRANT:TIGHT")

    expect(function.effects_decl).to eq(:reentrant)
    expect(function.effects_span.end_token.text!).to eq("TIGHT")
    expect(function.tight_reentrance).to be(true)
  end

  it "records named variants and their TIGHT modifier" do
    function = parse_function("EFFECTS REENTRANT:TIGHT:THUNK")

    expect(function.effects_decl).to eq(:reentrant_thunk)
    expect(function.effects_span.end_token.text!).to eq("THUNK")
    expect(function.tight_reentrance).to be(true)
  end

  it "records a bounded recursion depth and the closing-token span" do
    function = parse_function("EFFECTS REENTRANT:MAX_DEPTH(64)")

    expect(function.effects_decl).to eq(:reentrant_max_depth)
    expect(function.effects_span.end_token.value).to eq(")")
    expect(function.max_depth_n).to eq(64)
  end

  it "provides the typed span to effect-clause diagnostics" do
    function = parse_function("EFFECTS REENTRANT")
    edit = Annotator::Phases::TypeAnalysisSession.new.send(
      :effects_clause_edits,
      function,
      "EFFECTS REENTRANT:TAIL_CALL",
    ).first

    expect(edit.replacement).to eq("EFFECTS REENTRANT:TAIL_CALL")
    expect(edit.span.line).to eq(function.effects_span.start_token.line)
  end

  it "provides the typed start token to reentrance suggestions" do
    source = <<~CLEAR
      FN recursive(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
        RETURN recursive(n);
      END
    CLEAR
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse

    expect { SemanticAnnotator.new.annotate!(program) }.not_to raise_error
    expect(program.statements.first.reentrance_kind).to eq(:reentrant)
  end

  it "builds extern effects through a named parse result" do
    source = <<~CLEAR
      EXTERN FN plain() RETURNS Void FROM "native";
      EXTERN FN frame() RETURNS Void EFFECTS :alloc FROM "native";
      EXTERN FN heap() RETURNS Void EFFECTS :alloc:heap FROM "native";
      EXTERN FN direct() RETURNS Void EFFECTS :safe FROM "native";
      EXTERN FN both() RETURNS Void EFFECTS :safe, :alloc:frame FROM "native";
    CLEAR
    declarations = ClearParser.new(Lexer.new(source).tokenize, source).parse.statements

    expect(declarations.map(&:effects)).to eq([
      {},
      { alloc: :frame },
      { alloc: :heap },
      { safe: true },
      { safe: true, alloc: :frame },
    ])
  end

  it "rejects invalid bounded and tight variant combinations" do
    expect { parse_function("EFFECTS REENTRANT:MAX_DEPTH(0)") }
      .to raise_error(ParserError, /positive integer N/)
    expect { parse_function("EFFECTS REENTRANT:TIGHT:MAX_DEPTH(4)") }
      .to raise_error(ParserError, /MAX_DEPTH/)
    expect { parse_function("EFFECTS REENTRANT:TIGHT:NOT_LOGICAL") }
      .to raise_error(ParserError, /NOT_LOGICAL/)
  end
end
