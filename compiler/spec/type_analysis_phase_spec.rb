# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/type_analysis_phase"

RSpec.describe Annotator::Phases::TypeAnalysisPhase do
  def token(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  it "keeps mutable type-analysis state behind one explicit operation" do
    public_operations = Annotator::Phases::TypeAnalysisSession.public_instance_methods - Object.public_instance_methods

    expect(public_operations).to contain_exactly(:execute_type_analysis!)
  end

  it "runs directly on a phase-owned session and rejects unresolved output" do
    source = ""
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program,
      importer: nil,
      source_dir: Dir.pwd,
      source_code: source
    )
    session = Annotator::Phases::TypeAnalysisSession.new(source_code: source)

    result = described_class.run(resolution: resolution, session: session).typed_program

    expect(result.resolution).to equal(resolution)
    expect(result.typed_node_count).to eq(1)
    expect(result.unresolved_node_count).to eq(0)
  end

  it "publishes complete type facts from real CLEAR body analysis" do
    source = <<~CLEAR
      FN identity(value: Int64) RETURNS Int64 ->
        copy = value;
        RETURN copy;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(ast)
    products = annotator.annotation_products
    typed_program = products.typed_program

    expect(typed_program).to be_a(Annotator::Phases::TypedProgramFacts)
    expect(T.must(typed_program).resolution).to equal(products.resolution)
    expect(T.must(typed_program).typed_node_count).to be > 0
    expect(T.must(typed_program).unresolved_node_count).to eq(0)
    expect(T.must(typed_program).body_summaries.keys).to include("identity")
  end

  it "rejects a mutating method call while its receiver is restricted" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE items: Int64[] = [];
        WITH RESTRICT items {
          items.append(1_i64);
        }
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse

    expect {
      SemanticAnnotator.new(source_code: source).annotate!(ast)
    }.to raise_error(CompilerError, /Cannot assign to 'items' because it is currently borrowed/)
  end

  it "routes every rare AST family through its phase-owned visitor" do
    session = Annotator::Phases::TypeAnalysisSession.new
    cases = [
      [:dispatch_error_visit, AST::DieNode.new(token("DIE"), nil), :visit_DieNode],
      [:dispatch_expression_visit, AST::Placeholder.new(token("_")), :visit_Placeholder],
      [:dispatch_lifetime_visit, AST::Copy.new(token("COPY"), nil), :visit_Copy],
      [:dispatch_member_visit, AST::DefaultArrayLit.new(token("DEFAULT"), nil, nil), :visit_DefaultArrayLit],
      [:dispatch_test_visit, AST::WhenBlock.new(token("WHEN"), "case", [], [], []), :visit_WhenBlock],
      [:dispatch_test_visit, AST::TestThat.new(token("THAT"), "case", []), :visit_TestThat],
      [:dispatch_test_visit, AST::AssertRaises.new(token("ASSERT_RAISES"), :System, nil, nil), :visit_AssertRaises],
    ]

    cases.each do |dispatcher, node, visitor|
      expect(session).to receive(visitor).with(node)
      session.send(dispatcher, node)
    end
  end

  it "fails explicitly when an AST node has no annotation visitor" do
    session = Annotator::Phases::TypeAnalysisSession.new
    unknown = AST::LetBinding.new(token("LET"), "value", AST::Placeholder.new(token("_")))

    expect {
      session.send(:dispatch_visit, unknown)
    }.to raise_error(RuntimeError, /no annotation visitor for AST::LetBinding/)
  end

  it "reports source-located unresolved nodes independently of the annotator" do
    program = AST::Program.new(token, [])

    inventory = Annotator::Phases::AnnotationTypeInventory.scan(program)

    expect(inventory.unresolved_node_count).to eq(1)
    expect(inventory.violations.first.location).to eq("1:1")
    expect(inventory.violations.first.type_name).to eq("Untyped")
  end
end
