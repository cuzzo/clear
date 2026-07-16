require "spec_helper"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/semantic/pass_state" unless defined?(MIRPassState::StageSpec)

RSpec.describe "annotator completion phases" do
  def tok(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def typed_phase(source = "")
    program = parse(source)
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program, importer: nil, source_dir: Dir.pwd, source_code: source
    )
    session = SemanticAnnotator.new(source_code: source)
    typed_program = Annotator::Phases::TypeAnalysisPhase.run(
      resolution: resolution, session: session
    )
    [session, typed_program]
  end

  def audit_session_for(type_session, typed_program, source = "")
    Annotator::Phases::CapabilityAuditSession.new(
      typed_program: typed_program,
      inputs: type_session.release_capability_audit_inputs!,
      source_code: source,
      language_mode: type_session.language_mode,
      strict_test: type_session.strict_test?
    )
  end

  it "initializes builtin environment inside the resolution phase" do
    scope = Annotator::Phases::ResolutionSession.new(
      importer: nil, source_dir: Dir.pwd, source_code: nil
    ).root_scope

    expect(scope.resolve_entry!("argv").type.resolved).to eq(:String)
    expect(scope.types.fetch(:Range).schema).to be_a(Schemas::StructSchema)
    expect(scope.types.fetch(:File).schema).to be_a(Schemas::ResourceSchema)
    expect(scope.types.fetch(:TCPServer).schema).to be_a(Schemas::ResourceSchema)
    expect(scope.types.fetch(:TCPClient).schema).to be_a(Schemas::ResourceSchema)
  end

  it "marks an empty program annotated through the boundary phase" do
    program = AST::Program.new(tok, [])

    SemanticAnnotator.new.annotate!(program)

    expect(program.full_type!.resolved).to eq(:Void)
    expect(MIRPassState.for!(program).send(:completed_stages)).to eq([:annotated])
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
    expect(MIRPassState.for!(program).send(:completed_stages)).to eq([:annotated])
  end

  it "publishes a frozen semantic index after annotation completes" do
    annotator = SemanticAnnotator.new
    program = parse(<<~CLEAR)
      FN main() RETURNS Int64 ->
        RETURN 1;
      END
    CLEAR

    annotator.annotate!(program)
    index = T.must(annotator.semantic_index)

    expect(index.program).to eq(program)
    expect(index.root_scope).to eq(annotator.semantic_root_scope)
    expect(index.function_node("main")).to eq(annotator.function_node_for("main"))
    expect(index.function_nodes.keys).to include("main")
    expect(index.id_index.definition_id_for("main")&.value).to be > 0
    expect(index.id_index.body_id_for("main")&.value).to be > 0
    expect(index.body_summaries.fetch("main").definition_id).to eq(index.id_index.definition_id_for("main"))
    expect(index.body_summaries.fetch("main").body_id).to eq(index.id_index.body_id_for("main"))
    expect(index).to be_frozen
    expect(index.annotation_products).to equal(annotator.annotation_products)
    expect(index.typed_program).to equal(annotator.annotation_products.typed_program)
    expect(index.capability_audit).to equal(annotator.annotation_products.capability_audit)
  end

  it "publishes typed local and call-site facts in function body summaries" do
    annotator = SemanticAnnotator.new
    program = parse(<<~CLEAR)
      FN callee() RETURNS Int64 ->
        RETURN 1;
      END

      FN main() RETURNS Int64 ->
        value = callee();
        RETURN value;
      END
    CLEAR

    annotator.annotate!(program)
    summary = T.must(annotator.function_body_summaries["main"])

    expect(summary.definition_id.value).to be > 0
    expect(summary.body_id.value).to be > 0
    expect(summary.local_facts.map(&:name)).to include("value")
    expect(summary.local_facts.map { |fact| fact.id.value }).to all(be > 0)
    expect(summary.local_facts.map { |fact| fact.place_id.value }).to all(be > 0)
    expect(summary.call_site_facts.map(&:callee_name)).to include("callee")
    expect(summary.call_site_facts.map(&:fn_var_call)).to eq([false])
    expect(summary.call_site_facts.map(&:propagates_failure)).to eq([true])
  end

  it "resets compilation state between reused annotator runs" do
    annotator = SemanticAnnotator.new
    first = parse(<<~CLEAR)
      FN stale() RETURNS Int64 ->
        RETURN 1;
      END
    CLEAR
    second = parse(<<~CLEAR)
      stale();
    CLEAR

    annotator.annotate!(first)

    expect {
      annotator.annotate!(second)
    }.to raise_error(CompilerError, /undefined|unknown/i)
    expect(annotator.semantic_function_nodes).not_to have_key("stale")
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
    type_session, typed_program = typed_phase
    annotator = audit_session_for(type_session, typed_program)
    fn = AST::FunctionDef.new(tok("helper"), "helper", [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
    fn.full_type = Type.new(:Void)
    annotator.send(:semantic_function_nodes)["helper"] = fn

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
    annotator.record_deferred_with_validation!(
      with_node,
      capability_transition(AST::Capability.new(capability: :EXCLUSIVE, var_node: var_node))
    )

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /pending deferred validations/)
  end

  it "flushes deferred ATOMIC validations instead of dropping them" do
    type_session, typed_program = typed_phase
    with_node = AST::WithBlock.new(tok("WITH"), [], [], [])
    var_node = AST::Identifier.new(tok("cell"), "cell")
    var_node.full_type = Type.new(:Int64)
    var_node.symbol = SymbolEntry.new(reg: nil, type: Type.new(:Int64), mutable: true, storage: :stack)
    var_node.symbol.is_param = true
    type_session.record_deferred_with_validation!(
      with_node,
      capability_transition(AST::Capability.new(capability: :ATOMIC, var_node: var_node))
    )
    annotator = audit_session_for(type_session, typed_program)

      expect {
        annotator.send(:run_deferred_validations!)
      }.to raise_error(CompilerError, /WITH ATOMIC requires/)
  end

  it "rejects annotation completion if the program remains unstamped" do
    program = AST::Program.new(tok, [])
    annotator = SemanticAnnotator.new

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /unresolved type info/)
  end

  it "rejects annotation completion if a child node remains unstamped" do
    child = AST::Identifier.new(tok("x"), "x")
    program = AST::Program.new(tok, [child])
    program.full_type = Type.new(:Void)
    annotator = SemanticAnnotator.new

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /unresolved AST type facts/)
  end

  it "rejects annotation completion if a child node remains Auto" do
    child = AST::Identifier.new(tok("x"), "x")
    child.full_type = Type.new(:Auto, auto: true)
    program = AST::Program.new(tok, [child])
    program.full_type = Type.new(:Void)
    annotator = SemanticAnnotator.new

    expect {
      annotator.mark_annotation_complete!(program)
    }.to raise_error(RuntimeError, /Identifier .* Auto/)
  end

  it "ignores lifetime metadata nodes at the annotation boundary" do
    lifetime = AST::Identifier.new(tok("n"), "n")
    fn = AST::FunctionDef.new(tok("identity"), "identity", [], [], Type.new(:Int64), [lifetime], [], [], nil, :pub, [], false)
    fn.full_type = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
    program = AST::Program.new(tok, [fn])
    program.full_type = Type.new(:Void)
    annotator = SemanticAnnotator.new
    annotator.semantic_function_nodes["identity"] = fn

    expect {
      annotator.mark_annotation_complete!(program)
    }.not_to raise_error
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
