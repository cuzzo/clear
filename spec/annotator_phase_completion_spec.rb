require "spec_helper"

require_relative "../src/backends/transpiler"
require_relative "../src/semantic/pass_state"

RSpec.describe "annotator completion phases" do
  def tok(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def parse(source)
    Parser.new(Lexer.new(source).tokenize, source).parse
  end

  it "initializes builtin environment during annotator construction" do
    scope = SemanticAnnotator.new.current_scope

    expect(scope.resolve_entry!("argv").type.resolved).to eq(:String)
    expect(scope.types.fetch(:Range).fetch(:schema)).to be_a(Schemas::StructSchema)
    expect(scope.types.fetch(:File).fetch(:schema)).to be_a(Schemas::ResourceSchema)
    expect(scope.types.fetch(:TCPServer).fetch(:schema)).to be_a(Schemas::ResourceSchema)
    expect(scope.types.fetch(:TCPClient).fetch(:schema)).to be_a(Schemas::ResourceSchema)
  end

  it "marks an empty program annotated through the boundary phase" do
    program = AST::Program.new(tok, [])

    SemanticAnnotator.new.annotate!(program)

    expect(program.full_type!.resolved).to eq(:Void)
    expect(MIRPassState.for!(program).completed_stages).to eq([:annotated])
  end

  it "runs body analysis and program finalization for executable statements" do
    program = parse(<<~CLEAR)
      FN one() RETURNS Int64 ->
        RETURN 1;
      END

      one();
    CLEAR

    SemanticAnnotator.new.annotate!(program)

    expect(program.full_type!.resolved).to eq(:Int64)
    expect(MIRPassState.for!(program).completed_stages).to eq([:annotated])
  end

  it "appends synthesized functions during body analysis" do
    annotator = SemanticAnnotator.new
    program = AST::Program.new(tok, [])
    index = Annotator::Phases::DeclarationIndexer.index(program)
    synthetic = AST::FunctionDef.new(
      tok("generated"),
      "generated",
      [],
      [],
      Type.new(:Void),
      nil,
      [],
      [],
      nil,
      :pub,
      [],
      false
    )
    annotator.send(:synthetic_function_definitions) << synthetic

    annotator.analyze_program_bodies!(index, program)

    expect(program.statements).to eq([synthetic])
    expect(annotator.semantic_function_nodes.fetch("generated")).to eq(synthetic)
  end

  it "skips non-signature function metadata while finalizing summaries" do
    annotator = SemanticAnnotator.new
    fn = AST::FunctionDef.new(tok("helper"), "helper", [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    fn.full_type = Type.new(:Void)
    annotator.semantic_function_nodes["helper"] = fn

    expect {
      annotator.send(:restamp_function_metadata!)
    }.not_to raise_error
  end

  it "rejects annotation completion if deferred validations remain" do
    program = AST::Program.new(tok, [])
    annotator = SemanticAnnotator.new
    program.full_type = Type.new(:Void)
    with_node = AST::WithBlock.new(tok("WITH"), [], [], [])
    var_node = AST::Identifier.new(tok("cell"), "cell")
    var_node.full_type = Type.new(:Int64)
    annotator.record_deferred_with_validation!(with_node, var_node, :EXCLUSIVE)

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /pending deferred validations/)
  end

  it "flushes deferred ATOMIC validations instead of dropping them" do
    annotator = SemanticAnnotator.new(source_code: "")
    with_node = AST::WithBlock.new(tok("WITH"), [], [], [])
    var_node = AST::Identifier.new(tok("cell"), "cell")
    var_node.full_type = Type.new(:Int64)
    var_node.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: true, storage: :stack)
    var_node.symbol.is_param = true
    annotator.record_deferred_with_validation!(with_node, var_node, :ATOMIC)

    expect {
      annotator.run_deferred_validations!
    }.to raise_error(CompilerError, /WITH ATOMIC requires/)
  end

  it "rejects annotation completion if the program remains unstamped" do
    program = AST::Program.new(tok, [])
    annotator = SemanticAnnotator.new

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /unresolved type info/)
  end

  it "rejects annotation completion if a function lacks a signature" do
    program = AST::Program.new(tok, [])
    annotator = SemanticAnnotator.new
    fn = AST::FunctionDef.new(tok("bad"), "bad", [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    program.full_type = Type.new(:Void)
    fn.full_type = Type.new(:Void)
    annotator.semantic_function_nodes["bad"] = fn

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /missing function signature/)
  end
end
